import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:native_geofence/src/callback_dispatcher.dart';
import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/log_file_config.dart';
import 'package:native_geofence/src/model/model.dart';
import 'package:native_geofence/src/model/model_mapper.dart';
import 'package:native_geofence/src/model/native_geofence_exception.dart';
import 'package:native_geofence/src/platform/module.dart';
import 'package:native_geofence/src/typedefs.dart';

class NativeGeofenceManager {
  /// Cached instance of [NativeGeofenceManager]
  static NativeGeofenceManager? _instance;

  /// The singleton instance of [NativeGeofenceManager].
  ///
  /// Throws [NativeGeofenceException].
  static NativeGeofenceManager get instance {
    try {
      _instance ??= NativeGeofenceManager._();
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
    return _instance!;
  }

  final NativeGeofenceApi _api;

  static const MethodChannel _logFileChannel =
      MethodChannel('native_geofence/log_file');

  NativeGeofenceManager._() : _api = NativeGeofenceApi();

  /// Initialize the plugin.
  ///
  /// Must be called before any other method.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> initialize() async {
    final CallbackHandle? callback;
    try {
      callback = PluginUtilities.getCallbackHandle(callbackDispatcher);
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
    if (callback == null) {
      throw NativeGeofenceException.internal(
          message: 'Callback dispatcher is invalid.');
    }
    return _api
        .initialize(callbackDispatcherHandle: callback.toRawHandle())
        .catchError(NativeGeofenceExceptionMapper.catchError<void>);
  }

  /// Register for geofence events for a [Geofence].
  ///
  /// [region] is the geofence region to register with the system.
  /// [callback] is the method to be called when a geofence event associated
  /// with [region] occurs.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> createGeofence(
      Geofence geofence, GeofenceCallback callback) async {
    if (geofence.id.isEmpty) {
      throw NativeGeofenceException.invalidArgument(
          message: 'Geofence ID cannot be empty.');
    }
    if (geofence.triggers.isEmpty) {
      throw NativeGeofenceException.invalidArgument(
          message: 'Geofence triggers cannot be empty.');
    }
    if (!geofence.location.isValid) {
      throw NativeGeofenceException.invalidArgument(
          message: 'Geofence location is invalid.');
    }
    if (!geofence.radiusMeters.isFinite || geofence.radiusMeters <= 0) {
      throw NativeGeofenceException.invalidArgument(
          message: 'Geofence radius must be finite and strictly positive.');
    }
    if (isIos &&
        geofence.triggers.length == 1 &&
        geofence.triggers.first == GeofenceEvent.dwell) {
      throw NativeGeofenceException.invalidArgument(
          message: 'iOS does not support "GeofenceEvent.dwell".');
    }
    final CallbackHandle? callbackHandle;
    try {
      callbackHandle = PluginUtilities.getCallbackHandle(callback);
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
    if (callbackHandle == null) {
      throw NativeGeofenceException.invalidArgument(
          message: 'Callback is invalid.');
    }
    return _api
        .createGeofence(geofence: geofence.toWire(callbackHandle.toRawHandle()))
        .catchError(NativeGeofenceExceptionMapper.catchError<void>);
  }

  /// Re-register geofences after reboot.
  ///
  /// Optiona: This function can be called when the autostart feature is not
  /// working as it should (e.g. for some Android OEMs). This way you can ensure
  /// all Geofences are re-created at app launch.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> reCreateAfterReboot() async => _api
      .reCreateAfterReboot()
      .catchError(NativeGeofenceExceptionMapper.catchError<void>);

  /// Get all registered [Geofence] IDs.
  ///
  /// If there are no geofences registered it returns an empty list.
  ///
  /// Throws [NativeGeofenceException].
  Future<List<String>> getRegisteredGeofenceIds() async => _api
      .getGeofenceIds()
      .catchError(NativeGeofenceExceptionMapper.catchError<List<String>>);

  /// Get all [Geofence] regions and their properties.
  ///
  /// If there are no geofences registered it returns an empty list.
  ///
  /// Throws [NativeGeofenceException].
  Future<List<ActiveGeofence>> getRegisteredGeofences() async => _api
      .getGeofences()
      .then((value) => value.map((e) => e.fromWire()).toList())
      .catchError(
          NativeGeofenceExceptionMapper.catchError<List<ActiveGeofence>>);

  /// Configure the app-private Android log file.
  ///
  /// File logging is disabled by default. When enabled, native_geofence writes
  /// a bounded text log that can be fetched with [readLogFile]. This is a no-op
  /// on iOS and web.
  Future<void> configureLogFile({
    NativeGeofenceLogFileConfig config = const NativeGeofenceLogFileConfig(),
  }) async {
    if (!isAndroid) return;
    try {
      await _logFileChannel.invokeMethod<void>(
        'configureLogFile',
        config.toMap(),
      );
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
  }

  /// Read the current app-private Android log file.
  ///
  /// Returns an empty string when no file exists or outside Android.
  Future<String> readLogFile() async {
    if (!isAndroid) return '';
    try {
      return await _logFileChannel.invokeMethod<String>('readLogFile') ?? '';
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
  }

  /// Clear the app-private Android log file. No-op outside Android.
  Future<void> clearLogFile() async {
    if (!isAndroid) return;
    try {
      await _logFileChannel.invokeMethod<void>('clearLogFile');
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
  }

  /// Stop receiving geofence events for a given [Geofence].
  ///
  /// If the [Geofence] is not registered, this method does nothing.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> removeGeofence(Geofence region) async =>
      removeGeofenceById(region.id);

  /// Stop receiving geofence events for an identifier associated with a
  /// geofence region.
  ///
  /// If a [Geofence] with the given ID is not registered, this method does
  /// nothing.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> removeGeofenceById(String id) async => _api
      .removeGeofenceById(id: id)
      .catchError(NativeGeofenceExceptionMapper.catchError<void>);

  /// Stop receiving geofence events for all registered geofences.
  ///
  /// If there are no geofences registered, this method does nothing.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> removeAllGeofences() async => _api
      .removeAllGeofences()
      .catchError(NativeGeofenceExceptionMapper.catchError<void>);
}
