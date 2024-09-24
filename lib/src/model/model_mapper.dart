import 'package:flutter/services.dart';

import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model.dart';
import 'package:native_geofence/src/model/native_geofence_exception.dart';

extension LocationMapper on Location {
  LocationWire toWire() {
    return LocationWire(latitude: latitude, longitude: longitude);
  }
}

extension LocationWireMapper on LocationWire {
  Location fromWire() {
    return Location(latitude: latitude, longitude: longitude);
  }
}

extension AndroidGeofenceSettingsMapper on AndroidGeofenceSettings {
  AndroidGeofenceSettingsWire toWire() {
    return AndroidGeofenceSettingsWire(
      initialTriggers: initialTriggers,
      expirationDurationMillis: expiration?.inMilliseconds,
      loiteringDelayMillis: loiteringDelay.inMilliseconds,
      notificationResponsivenessMillis:
          notificationResponsiveness?.inMilliseconds,
    );
  }
}

extension AndroidGeofenceSettingsWireMapper on AndroidGeofenceSettingsWire {
  AndroidGeofenceSettings fromWire() {
    return AndroidGeofenceSettings(
      initialTriggers: initialTriggers,
      expiration: expirationDurationMillis != null
          ? Duration(milliseconds: expirationDurationMillis!)
          : null,
      loiteringDelay: Duration(milliseconds: loiteringDelayMillis),
      notificationResponsiveness: notificationResponsivenessMillis != null
          ? Duration(milliseconds: notificationResponsivenessMillis!)
          : null,
    );
  }
}

extension GeofenceMapper on Geofence {
  GeofenceWire toWire(int callbackHandle) {
    return GeofenceWire(
      id: id,
      location: location.toWire(),
      radiusMeters: radiusMeters,
      triggers: triggers,
      androidSettings: androidSettings.toWire(),
      callbackHandle: callbackHandle,
    );
  }
}

extension GeofenceWireMapper on GeofenceWire {
  Geofence fromWire() {
    return Geofence(
      id: id,
      location: location.fromWire(),
      radiusMeters: radiusMeters,
      triggers: triggers,
      androidSettings: androidSettings.fromWire(),
    );
  }
}

extension GeofenceInfoMapper on GeofenceInfo {
  GeofenceInfoWire toWire() {
    return GeofenceInfoWire(
      id: id,
      location: location.toWire(),
      radiusMeters: radiusMeters,
      triggers: triggers,
      androidSettings: androidSettings.toWire(),
    );
  }
}

extension GeofenceInfoWireMapper on GeofenceInfoWire {
  GeofenceInfo fromWire() {
    return GeofenceInfo(
      id: id,
      location: location.fromWire(),
      radiusMeters: radiusMeters,
      triggers: triggers,
      androidSettings: androidSettings.fromWire(),
    );
  }
}

extension NativeGeofenceExceptionMapper on NativeGeofenceException {
  static NativeGeofenceException fromPlatformException(PlatformException ex) {
    return NativeGeofenceException(
      code: ex.code == 'channel-error'
          ? NativeGeofenceErrorCode.channelError
          : NativeGeofenceErrorCode.values.firstWhere(
              (e) => e.index == (int.tryParse(ex.code) ?? 0),
              orElse: () => NativeGeofenceErrorCode.unknown,
            ),
      message: ex.message,
      details: ex.details,
      stacktrace: ex.stacktrace,
    );
  }

  static NativeGeofenceException fromException(Exception ex,
      [StackTrace? stacktrace]) {
    return NativeGeofenceException(
      code: NativeGeofenceErrorCode.unknown,
      message: ex.toString(),
      stacktrace: stacktrace?.toString() ?? StackTrace.current.toString(),
    );
  }

  static NativeGeofenceException fromError(dynamic error,
      [StackTrace? stacktrace]) {
    if (error is NativeGeofenceException) {
      return error;
    }
    if (error is PlatformException) {
      return fromPlatformException(error);
    }
    if (error is Exception) {
      return fromException(error, stacktrace);
    }
    return NativeGeofenceException(
      code: NativeGeofenceErrorCode.unknown,
      message: error.toString(),
      stacktrace: stacktrace?.toString() ?? StackTrace.current.toString(),
    );
  }

  static T catchError<T>(dynamic error, StackTrace stacktrace) {
    throw fromError(error, stacktrace);
  }
}