import 'package:native_geofence/src/generated/platform_bindings.g.dart';

/// A simple representation of a geographic location.
///
/// The latitude and longitude are expressed in decimal degrees.
/// See: https://en.wikipedia.org/wiki/Decimal_degrees
class Location {
  final double latitude;
  final double longitude;

  const Location({required this.latitude, required this.longitude});

  /// Whether this location instance is valid.
  bool get isValid =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;

  @override
  String toString() {
    return 'Location(${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)})';
  }
}

/// iOS specific Geofence settings.
class IosGeofenceSettings {
  /// Whether a geofence event should trigger immediately when the geofence is
  /// added.
  /// For example, setting this to true will trigger an [GeofenceEvent.enter]
  /// event if the user is already inside the geofence.
  /// Don't worry: This initial trigger only happens when the geofence is
  /// created and NOT every time the plugin is initialized.
  final bool initialTrigger;

  const IosGeofenceSettings({
    this.initialTrigger = false,
  });

  @override
  String toString() {
    return 'IosGeofenceSettings(initialTrigger: $initialTrigger)';
  }
}

/// Android specific Geofence settings.
class AndroidGeofenceSettings {
  /// Sets the geofence behavior at the moment when the geofences are added.
  /// For example, listing [GeofenceEvent.enter] here will trigger the Geofence
  /// immediately if the user is already inside the geofence.
  /// Don't worry: This initial trigger only happens when the geofence is
  /// created and NOT every time the plugin is initialized.
  final Set<GeofenceEvent> initialTriggers;

  /// The geofence will be removed automatically after this period of time.
  /// If you don't set this the geofence will never expire.
  final Duration? expiration;

  /// The delay between [GeofenceEvent.enter] and [GeofenceEvent.dwell].
  /// Only has impact if [GeofenceEvent.dwell] is one of the triggers.
  final Duration loiteringDelay;

  /// The responsiveness of the geofence.
  ///
  /// Defaults to 0. Setting a big responsiveness value, for example 5 minutes,
  /// can save power significantly. However, setting a very small responsiveness
  /// value, for example 5 seconds, doesn't necessarily mean you will get
  /// notified right after the user enters or exits a geofence: internally, the
  /// OS might adjust the responsiveness value to save power when needed.
  final Duration? notificationResponsiveness;

  const AndroidGeofenceSettings({
    required this.initialTriggers,
    this.expiration,
    this.loiteringDelay = const Duration(minutes: 5),
    this.notificationResponsiveness,
  });

  @override
  String toString() {
    return 'AndroidGeofenceSettings('
        'initialTriggers: [${initialTriggers.map((e) => e.name).join(',')}], '
        'expiration: ${expiration?.inMinutes}min, '
        'loiteringDelay: ${loiteringDelay.inMilliseconds}ms, '
        'notificationResponsiveness: ${notificationResponsiveness?.inMilliseconds}ms)';
  }
}

/// A circular region which represents a geofence.
class Geofence {
  /// The ID associated with the geofence.
  ///
  /// This ID is used to identify the geofence and is required to delete a
  /// specific geofence.
  /// Creating two geofences with the same ID will result in the first geofence
  /// being overwritten.
  final String id;

  /// The location of the geofence.
  final Location location;

  /// The radius, in meters, around [location] that will be considered part of
  /// the geofence.
  final double radiusMeters;

  /// The types of geofence events to listen for.
  ///
  /// Note: [GeofenceEvent.dwell] is not supported on iOS.
  final Set<GeofenceEvent> triggers;

  /// iOS specific settings.
  final IosGeofenceSettings iosSettings;

  /// Android specific settings.
  final AndroidGeofenceSettings androidSettings;

  const Geofence({
    required this.id,
    required this.location,
    required this.radiusMeters,
    required this.triggers,
    required this.iosSettings,
    required this.androidSettings,
  });

  @override
  String toString() {
    return 'Geofence('
        'id: $id, '
        'location: $location, '
        'radiusMeters: $radiusMeters, '
        'triggers: [${triggers.map((e) => e.name).join(',')}], '
        'iosSettings: $iosSettings, '
        'androidSettings: $androidSettings)';
  }
}

/// A Geofence that is registered and is actively being tracked.
///
/// This type is a subset of [Geofence] that is returned by the plugin for GET
/// calls.
///
/// See the [Geofence] class for field details.
///
/// Note: [IosGeofenceSettings] is not provided due to platform constraints.
class ActiveGeofence {
  /// The ID associated with the geofence.
  final String id;

  /// The location of the geofence.
  final Location location;

  /// The radius, in meters, around [location] that will be considered part of
  /// the geofence.
  final double radiusMeters;

  /// The types of geofence events to listen for.
  final Set<GeofenceEvent> triggers;

  /// Only available on Android.
  ///
  /// The [initialTriggers] field will always be an empty list because Android
  /// does not provide this information when a Geofence triggers.
  final AndroidGeofenceSettings? androidSettings;

  ActiveGeofence({
    required this.id,
    required this.location,
    required this.radiusMeters,
    required this.triggers,
    required this.androidSettings,
  });

  @override
  String toString() {
    return 'ActiveGeofence('
        'id: $id, '
        'location: $location, '
        'radiusMeters: $radiusMeters, '
        'triggers: [${triggers.map((e) => e.name).join(',')}], '
        'androidSettings: $androidSettings)';
  }
}

/// The parameters passed to the geofence callback handler.
class GeofenceCallbackParams {
  /// The geofences that triggered the event.
  /// The list might contain multiple elements on Android.
  final List<ActiveGeofence> geofences;

  /// The type of geofence event.
  final GeofenceEvent event;

  /// The location of the device when the geofence event was triggered.
  ///
  /// Only set on Android and even then it might sometimes be null.
  ///
  /// Not set on iOS because the OS does not provide this information. See:
  /// https://developer.apple.com/documentation/corelocation/cllocationmanagerdelegate/locationmanager(_:diddeterminestate:for:)
  final Location? location;

  const GeofenceCallbackParams({
    required this.geofences,
    required this.event,
    required this.location,
  });

  @override
  String toString() {
    return 'GeofenceCallbackParams('
        'geofences: [${geofences.map((e) => e.toString()).join(', ')}], '
        'event: ${event.name}, '
        'location: $location)';
  }
}

/// Best-effort diagnostic snapshot for investigating geofence lifecycle issues.
///
/// This is not a proof that the Android OS currently has a geofence armed:
/// Android/Google Play services do not expose a live geofence listing API. It
/// is the plugin's persisted view plus native lifecycle facts collected around
/// registration, removal, broadcast delivery, and callback enqueueing.
class NativeGeofenceStatus {
  final String platform;
  final int? androidSdkInt;
  final String? deviceManufacturer;
  final String? deviceModel;
  final List<String> persistedGeofenceIds;
  final bool locationPermissionGranted;
  final bool? backgroundLocationPermissionGranted;
  final bool? notificationPermissionGranted;
  final String? locationAuthorizationStatus;
  final bool? locationServicesEnabled;
  final bool? batteryOptimizationsIgnored;
  final bool? powerSaveMode;
  final bool? backgroundRestricted;
  final String? appStandbyBucket;
  final bool? googlePlayServicesAvailable;
  final int? googlePlayServicesAvailabilityCode;
  final bool? geofencePendingIntentExists;
  final int? lastRegisterAttemptAtMillis;
  final int? lastRegisterSuccessAtMillis;
  final int? lastRegisterFailureAtMillis;
  final String? lastRegisterGeofenceId;
  final String? lastRegisterFailureCode;
  final String? lastRegisterFailureMessage;
  final int? lastRemoveAttemptAtMillis;
  final int? lastRemoveSuccessAtMillis;
  final int? lastRemoveFailureAtMillis;
  final List<String> lastRemoveGeofenceIds;
  final String? lastRemoveFailureMessage;
  final int? lastBroadcastReceivedAtMillis;
  final String? lastBroadcastEvent;
  final List<String> lastBroadcastGeofenceIds;
  final double? lastBroadcastLocationLatitude;
  final double? lastBroadcastLocationLongitude;
  final String? lastBroadcastNearestGeofenceId;
  final double? lastBroadcastDistanceFromNearestGeofenceMeters;
  final double? lastBroadcastNearestGeofenceRadiusMeters;
  final String? lastBroadcastErrorCode;
  final String? lastBroadcastErrorMessage;
  final int? lastCallbackEnqueueAtMillis;
  final int? lastCallbackEnqueueFailureAtMillis;
  final String? lastCallbackEnqueueFailureMessage;
  final int? lastCallbackWorkerStartAtMillis;
  final int? lastCallbackWorkerApiReadyAtMillis;
  final int? lastCallbackWorkerFinishAtMillis;
  final int? lastCallbackWorkerFailureAtMillis;
  final String? lastCallbackWorkerResult;
  final String? lastCallbackWorkerFailureCode;
  final String? lastCallbackWorkerFailureMessage;
  final int? lastCallbackWorkerRunAttempt;
  final String? lastCallbackWorkerEvent;
  final List<String> lastCallbackWorkerGeofenceIds;
  final int? lastRecreateAttemptAtMillis;
  final int? lastRecreateSuccessAtMillis;
  final int? lastRecreateFailureAtMillis;
  final int? lastRecreateGeofenceCount;
  final String? lastRecreateReason;
  final String? lastRecreateFailureMessage;

  const NativeGeofenceStatus({
    required this.platform,
    required this.androidSdkInt,
    required this.deviceManufacturer,
    required this.deviceModel,
    required this.persistedGeofenceIds,
    required this.locationPermissionGranted,
    required this.backgroundLocationPermissionGranted,
    required this.notificationPermissionGranted,
    required this.locationAuthorizationStatus,
    required this.locationServicesEnabled,
    required this.batteryOptimizationsIgnored,
    required this.powerSaveMode,
    required this.backgroundRestricted,
    required this.appStandbyBucket,
    required this.googlePlayServicesAvailable,
    required this.googlePlayServicesAvailabilityCode,
    required this.geofencePendingIntentExists,
    required this.lastRegisterAttemptAtMillis,
    required this.lastRegisterSuccessAtMillis,
    required this.lastRegisterFailureAtMillis,
    required this.lastRegisterGeofenceId,
    required this.lastRegisterFailureCode,
    required this.lastRegisterFailureMessage,
    required this.lastRemoveAttemptAtMillis,
    required this.lastRemoveSuccessAtMillis,
    required this.lastRemoveFailureAtMillis,
    required this.lastRemoveGeofenceIds,
    required this.lastRemoveFailureMessage,
    required this.lastBroadcastReceivedAtMillis,
    required this.lastBroadcastEvent,
    required this.lastBroadcastGeofenceIds,
    required this.lastBroadcastLocationLatitude,
    required this.lastBroadcastLocationLongitude,
    required this.lastBroadcastNearestGeofenceId,
    required this.lastBroadcastDistanceFromNearestGeofenceMeters,
    required this.lastBroadcastNearestGeofenceRadiusMeters,
    required this.lastBroadcastErrorCode,
    required this.lastBroadcastErrorMessage,
    required this.lastCallbackEnqueueAtMillis,
    required this.lastCallbackEnqueueFailureAtMillis,
    required this.lastCallbackEnqueueFailureMessage,
    required this.lastCallbackWorkerStartAtMillis,
    required this.lastCallbackWorkerApiReadyAtMillis,
    required this.lastCallbackWorkerFinishAtMillis,
    required this.lastCallbackWorkerFailureAtMillis,
    required this.lastCallbackWorkerResult,
    required this.lastCallbackWorkerFailureCode,
    required this.lastCallbackWorkerFailureMessage,
    required this.lastCallbackWorkerRunAttempt,
    required this.lastCallbackWorkerEvent,
    required this.lastCallbackWorkerGeofenceIds,
    required this.lastRecreateAttemptAtMillis,
    required this.lastRecreateSuccessAtMillis,
    required this.lastRecreateFailureAtMillis,
    required this.lastRecreateGeofenceCount,
    required this.lastRecreateReason,
    required this.lastRecreateFailureMessage,
  });

  @override
  String toString() {
    return 'NativeGeofenceStatus('
        'platform: $platform, '
        'androidSdkInt: $androidSdkInt, '
        'device: ${deviceManufacturer ?? 'unknown'} ${deviceModel ?? ''}, '
        'persistedGeofenceIds: [${persistedGeofenceIds.join(',')}], '
        'locationPermissionGranted: $locationPermissionGranted, '
        'backgroundLocationPermissionGranted: $backgroundLocationPermissionGranted, '
        'notificationPermissionGranted: $notificationPermissionGranted, '
        'locationAuthorizationStatus: $locationAuthorizationStatus, '
        'locationServicesEnabled: $locationServicesEnabled, '
        'batteryOptimizationsIgnored: $batteryOptimizationsIgnored, '
        'powerSaveMode: $powerSaveMode, '
        'backgroundRestricted: $backgroundRestricted, '
        'appStandbyBucket: $appStandbyBucket, '
        'googlePlayServicesAvailable: $googlePlayServicesAvailable, '
        'googlePlayServicesAvailabilityCode: $googlePlayServicesAvailabilityCode, '
        'geofencePendingIntentExists: $geofencePendingIntentExists, '
        'lastRegisterAttemptAtMillis: $lastRegisterAttemptAtMillis, '
        'lastRegisterSuccessAtMillis: $lastRegisterSuccessAtMillis, '
        'lastRegisterFailureAtMillis: $lastRegisterFailureAtMillis, '
        'lastRegisterGeofenceId: $lastRegisterGeofenceId, '
        'lastRegisterFailureCode: $lastRegisterFailureCode, '
        'lastRegisterFailureMessage: $lastRegisterFailureMessage, '
        'lastRemoveAttemptAtMillis: $lastRemoveAttemptAtMillis, '
        'lastRemoveSuccessAtMillis: $lastRemoveSuccessAtMillis, '
        'lastRemoveFailureAtMillis: $lastRemoveFailureAtMillis, '
        'lastRemoveGeofenceIds: [${lastRemoveGeofenceIds.join(',')}], '
        'lastRemoveFailureMessage: $lastRemoveFailureMessage, '
        'lastBroadcastReceivedAtMillis: $lastBroadcastReceivedAtMillis, '
        'lastBroadcastEvent: $lastBroadcastEvent, '
        'lastBroadcastGeofenceIds: [${lastBroadcastGeofenceIds.join(',')}], '
        'lastBroadcastLocationLatitude: $lastBroadcastLocationLatitude, '
        'lastBroadcastLocationLongitude: $lastBroadcastLocationLongitude, '
        'lastBroadcastNearestGeofenceId: $lastBroadcastNearestGeofenceId, '
        'lastBroadcastDistanceFromNearestGeofenceMeters: $lastBroadcastDistanceFromNearestGeofenceMeters, '
        'lastBroadcastNearestGeofenceRadiusMeters: $lastBroadcastNearestGeofenceRadiusMeters, '
        'lastBroadcastErrorCode: $lastBroadcastErrorCode, '
        'lastBroadcastErrorMessage: $lastBroadcastErrorMessage, '
        'lastCallbackEnqueueAtMillis: $lastCallbackEnqueueAtMillis, '
        'lastCallbackEnqueueFailureAtMillis: $lastCallbackEnqueueFailureAtMillis, '
        'lastCallbackEnqueueFailureMessage: $lastCallbackEnqueueFailureMessage, '
        'lastCallbackWorkerStartAtMillis: $lastCallbackWorkerStartAtMillis, '
        'lastCallbackWorkerApiReadyAtMillis: $lastCallbackWorkerApiReadyAtMillis, '
        'lastCallbackWorkerFinishAtMillis: $lastCallbackWorkerFinishAtMillis, '
        'lastCallbackWorkerFailureAtMillis: $lastCallbackWorkerFailureAtMillis, '
        'lastCallbackWorkerResult: $lastCallbackWorkerResult, '
        'lastCallbackWorkerFailureCode: $lastCallbackWorkerFailureCode, '
        'lastCallbackWorkerFailureMessage: $lastCallbackWorkerFailureMessage, '
        'lastCallbackWorkerRunAttempt: $lastCallbackWorkerRunAttempt, '
        'lastCallbackWorkerEvent: $lastCallbackWorkerEvent, '
        'lastCallbackWorkerGeofenceIds: [${lastCallbackWorkerGeofenceIds.join(',')}], '
        'lastRecreateAttemptAtMillis: $lastRecreateAttemptAtMillis, '
        'lastRecreateSuccessAtMillis: $lastRecreateSuccessAtMillis, '
        'lastRecreateFailureAtMillis: $lastRecreateFailureAtMillis, '
        'lastRecreateGeofenceCount: $lastRecreateGeofenceCount, '
        'lastRecreateReason: $lastRecreateReason, '
        'lastRecreateFailureMessage: $lastRecreateFailureMessage'
        ')';
  }
}
