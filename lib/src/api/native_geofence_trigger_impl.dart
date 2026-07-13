import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model_mapper.dart';
import 'package:native_geofence/src/typedefs.dart';

class NativeGeofenceTriggerImpl implements NativeGeofenceTriggerApi {
  /// Cached instance of [NativeGeofenceTriggerImpl]
  static NativeGeofenceTriggerImpl? _instance;

  static void ensureInitialized() {
    _instance ??= NativeGeofenceTriggerImpl._();
  }

  NativeGeofenceTriggerImpl._() {
    NativeGeofenceTriggerApi.setUp(this);
  }

  @override
  Future<void> geofenceTriggered(GeofenceCallbackParamsWire params) async {
    final Function? callback = PluginUtilities.getCallbackFromHandle(
        CallbackHandle.fromRawHandle(params.callbackHandle));
    if (callback == null) {
      throw PlatformException(
        code: NativeGeofenceErrorCode.callbackNotFound.index.toString(),
        message: 'The stored geofence callback is no longer available. Call '
            'NativeGeofenceManager.instance.ensureSynchronized(...) with your '
            'app-owned registration list to refresh callback registrations.',
      );
    }
    if (callback is! GeofenceCallback) {
      throw PlatformException(
        code: NativeGeofenceErrorCode.callbackInvalid.index.toString(),
        message: 'The stored geofence callback is no longer valid. Call '
            'NativeGeofenceManager.instance.ensureSynchronized(...) with your '
            'app-owned registration list to refresh callback registrations.',
      );
    }
    await callback(params.fromWire());
    debugPrint('Geofence trigger callback completed.');
  }
}
