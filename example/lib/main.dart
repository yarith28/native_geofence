import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:native_geofence/native_geofence.dart';
import 'package:native_geofence_example/create_geofence.dart';

import 'notifications_repository.dart';

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> {
  String geofenceState = 'N/A';
  final ReceivePort port = ReceivePort();
  bool initialized = false;
  String? initializationError;

  @override
  void initState() {
    super.initState();
    unawaited(NotificationsRepository().init());
    IsolateNameServer.removePortNameMapping('native_geofence_send_port');
    IsolateNameServer.registerPortWithName(
      port.sendPort,
      'native_geofence_send_port',
    );
    port.listen((dynamic data) {
      debugPrint('Event: $data');
      setState(() {
        geofenceState = data;
      });
    });
    unawaited(initPlatformState());
  }

  Future<void> initPlatformState() async {
    debugPrint('Initializing...');
    try {
      await NativeGeofenceManager.instance.initialize();
      if (!mounted) return;
      setState(() => initialized = true);
      debugPrint('Initialization done');
    } catch (error) {
      if (!mounted) return;
      setState(() => initializationError = error.toString());
      debugPrint('Initialization failed: $error');
    }
  }

  @override
  void dispose() {
    IsolateNameServer.removePortNameMapping('native_geofence_send_port');
    port.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Native Geofence'),
        ),
        body: Container(
          padding: const EdgeInsets.all(20.0),
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text('Current state: $geofenceState'),
                const SizedBox(height: 20),
                if (initializationError != null)
                  Text('Initialization failed: $initializationError')
                else if (!initialized)
                  const CircularProgressIndicator()
                else
                  const CreateGeofence(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
