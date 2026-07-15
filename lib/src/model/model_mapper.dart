import 'package:flutter/services.dart';

import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model.dart';
import 'package:native_geofence/src/model/native_geofence_exception.dart';
import 'package:native_geofence/src/model/native_geofence_status.dart';

extension LocationMapper on Location {
  LocationWire toWire() {
    return LocationWire(
      latitude: latitude,
      longitude: longitude,
      accuracyMeters: accuracyMeters,
      isMock: isMock,
    );
  }
}

extension LocationWireMapper on LocationWire {
  Location fromWire() {
    return Location(
      latitude: latitude,
      longitude: longitude,
      accuracyMeters: accuracyMeters,
      isMock: isMock,
    );
  }
}

extension IosGeofenceSettingsMapper on IosGeofenceSettings {
  IosGeofenceSettingsWire toWire() {
    return IosGeofenceSettingsWire(initialTrigger: initialTrigger);
  }
}

extension IosGeofenceSettingsWireMapper on IosGeofenceSettingsWire {
  IosGeofenceSettings fromWire() {
    return IosGeofenceSettings(initialTrigger: initialTrigger);
  }
}

extension AndroidGeofenceSettingsMapper on AndroidGeofenceSettings {
  AndroidGeofenceSettingsWire toWire() {
    return AndroidGeofenceSettingsWire(
      initialTriggers: initialTriggers.toList(),
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
      initialTriggers: initialTriggers.toSet(),
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
  GeofenceWire toWire(int callbackHandle, {int? callbackContext}) {
    return GeofenceWire(
      id: id,
      location: location.toWire(),
      radiusMeters: radiusMeters,
      triggers: triggers.toList(),
      iosSettings: iosSettings.toWire(),
      androidSettings: androidSettings.toWire(),
      callbackHandle: callbackHandle,
      callbackContext: callbackContext,
    );
  }
}

extension GeofenceWireMapper on GeofenceWire {
  Geofence fromWire() {
    return Geofence(
      id: id,
      location: location.fromWire(),
      radiusMeters: radiusMeters,
      triggers: triggers.toSet(),
      iosSettings: iosSettings.fromWire(),
      androidSettings: androidSettings.fromWire(),
    );
  }
}

extension ActiveGeofenceMapper on ActiveGeofence {
  ActiveGeofenceWire toWire() {
    return ActiveGeofenceWire(
      id: id,
      location: location.toWire(),
      radiusMeters: radiusMeters,
      triggers: triggers.toList(),
      androidSettings: androidSettings?.toWire(),
      expirationDeadlineMillis: expirationDeadline?.millisecondsSinceEpoch,
    );
  }
}

extension ActiveGeofenceWireMapper on ActiveGeofenceWire {
  ActiveGeofence fromWire() {
    return ActiveGeofence(
      id: id,
      location: location.fromWire(),
      radiusMeters: radiusMeters,
      triggers: triggers.toSet(),
      androidSettings: androidSettings?.fromWire(),
      expirationDeadline: expirationDeadlineMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expirationDeadlineMillis!),
    );
  }
}

extension GeofenceCallbackParamsWireMapper on GeofenceCallbackParamsWire {
  GeofenceCallbackParams fromWire() {
    return GeofenceCallbackParams(
      geofences: geofences.map((e) => e.fromWire()).toList(),
      event: event,
      location: location?.fromWire(),
      eventAt: eventAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(eventAtMillis!),
      eventId: eventId,
      callbackContextsByGeofenceId: Map.unmodifiable(
        callbackContextsByGeofenceId ?? const <String, int>{},
      ),
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

extension NativeGeofenceLifecycleFactWireMapper
    on NativeGeofenceLifecycleFactWire {
  NativeGeofenceLifecycleFact fromWire() => NativeGeofenceLifecycleFact(
        occurredAt: DateTime.fromMillisecondsSinceEpoch(occurredAtMillis),
        succeeded: succeeded,
        outcome: outcome,
        geofenceCount: geofenceCount,
      );
}

extension NativeGeofenceStatusWireMapper on NativeGeofenceStatusWire {
  NativeGeofenceStatus fromWire() => NativeGeofenceStatus(
        platform: platform,
        osVersion: osVersion,
        persistedGeofenceCount: persistedGeofenceCount,
        locationPermissionGranted: locationPermissionGranted,
        backgroundLocationPermissionGranted:
            backgroundLocationPermissionGranted,
        notificationPermissionGranted: notificationPermissionGranted,
        locationServicesEnabled: locationServicesEnabled,
        monitoringAvailable: monitoringAvailable,
        playServicesAvailable: playServicesAvailable,
        callbackPendingIntentAvailable: callbackPendingIntentAvailable,
        callbackReceiverAvailable: callbackReceiverAvailable,
        canEnumerateLivePlatformRegistrations:
            canEnumerateLivePlatformRegistrations,
        pluginOwnedMonitoringCount: pluginOwnedMonitoringCount,
        callbackDispatcherRegistered: callbackDispatcherRegistered,
        callbackRefreshState: callbackRefreshState,
        registrationHealth: registrationHealth,
        lastRegistrationFact: lastRegistrationFact?.fromWire(),
        lastRemovalFact: lastRemovalFact?.fromWire(),
        lastBroadcastFact: lastBroadcastFact?.fromWire(),
        lastEnqueueFact: lastEnqueueFact?.fromWire(),
        lastWorkerFact: lastWorkerFact?.fromWire(),
        lastRecoveryFact: lastRecoveryFact?.fromWire(),
        lastForegroundFact: lastForegroundFact?.fromWire(),
      );
}
