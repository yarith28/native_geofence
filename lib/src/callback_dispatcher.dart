import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:native_geofence/src/api/native_geofence_trigger_impl.dart';
import 'package:native_geofence/src/native_geofence_background_manager.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  debugPrint('Callback dispatcher called.');
  // Setup connection between platform and Flutter.
  WidgetsFlutterBinding.ensureInitialized();
  // Register callback-safe Flutter plugins in this headless isolate before any
  // background API can invoke them.
  DartPluginRegistrant.ensureInitialized();
  // Create the NativeGeofenceTriggerApi.
  NativeGeofenceTriggerImpl.ensureInitialized();
  // Create the NativeGeofenceBackgroundApi.
  createNativeGeofenceBackgroundManagerInstance();
}
