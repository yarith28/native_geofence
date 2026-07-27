import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model_mapper.dart';
import 'package:native_geofence/src/typedefs.dart';

const String _callbackLookupTerminalErrorMarker =
    'com.chunkytofustudios.native_geofence.callback_lookup_terminal.v1';

class NativeGeofenceTriggerImpl implements NativeGeofenceTriggerApi {
  /// Cached instance of [NativeGeofenceTriggerImpl]
  static NativeGeofenceTriggerImpl? _instance;

  static void ensureInitialized() {
    _instance ??= NativeGeofenceTriggerImpl._();
  }

  NativeGeofenceTriggerImpl._() {
    NativeGeofenceTriggerApi.setUp(this);
  }

  @visibleForTesting
  static PlatformException callbackLookupFailure({
    required NativeGeofenceErrorCode code,
    required String message,
  }) {
    return PlatformException(
      code: code.index.toString(),
      message: message,
      details: _callbackLookupTerminalErrorMarker,
    );
  }

  @override
  Future<void> geofenceTriggered(GeofenceCallbackParamsWire params) async {
    final Function? callback = PluginUtilities.getCallbackFromHandle(
      CallbackHandle.fromRawHandle(params.callbackHandle),
    );
    if (callback == null) {
      throw callbackLookupFailure(
        code: NativeGeofenceErrorCode.callbackNotFound,
        message:
            'The stored geofence callback is no longer available. Call '
            'NativeGeofenceManager.instance.ensureSynchronized(...) with your '
            'app-owned registration list to refresh callback registrations.',
      );
    }
    if (callback is! GeofenceCallback) {
      throw callbackLookupFailure(
        code: NativeGeofenceErrorCode.callbackInvalid,
        message:
            'The stored geofence callback is no longer valid. Call '
            'NativeGeofenceManager.instance.ensureSynchronized(...) with your '
            'app-owned registration list to refresh callback registrations.',
      );
    }
    await callback(params.fromWire());
    debugPrint('Geofence trigger callback completed.');
  }
}
