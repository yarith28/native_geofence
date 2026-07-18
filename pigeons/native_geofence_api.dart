import 'package:pigeon/pigeon.dart';

// After modifying this file run:
// dart run pigeon --input pigeons/native_geofence_api.dart && dart format .

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/generated/platform_bindings.g.dart',
    dartPackageName: 'native_geofence',
    swiftOut:
        'ios/native_geofence/Sources/native_geofence/Generated/FlutterBindings.g.swift',
    kotlinOut:
        'android/src/main/kotlin/com/chunkytofustudios/native_geofence/generated/FlutterBindings.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.chunkytofustudios.native_geofence.generated',
    ),
  ),
)
/// Geofencing events.
///
/// See the helpful illustration at:
/// https://developer.android.com/develop/sensors-and-location/location/geofencing
enum GeofenceEvent {
  enter(),
  exit(),

  /// Not supported on iOS.
  dwell(),
}

class LocationWire {
  final double latitude;
  final double longitude;

  /// Horizontal accuracy in meters, when known.
  final double? accuracyMeters;

  /// Whether this fix came from a mock location provider.
  final bool isMock;

  /// Device wall-clock timestamp reported by the location provider.
  final int? fixTimeMillis;

  /// Monotonic provider timestamp used to calculate fix age on Android.
  final int? elapsedRealtimeNanos;

  const LocationWire({
    required this.latitude,
    required this.longitude,
    this.accuracyMeters,
    this.isMock = false,
    this.fixTimeMillis,
    this.elapsedRealtimeNanos,
  });
}

class IosGeofenceSettingsWire {
  final bool initialTrigger;

  const IosGeofenceSettingsWire({required this.initialTrigger});
}

class AndroidGeofenceSettingsWire {
  final List<GeofenceEvent> initialTriggers;
  final int? expirationDurationMillis;
  final int loiteringDelayMillis;
  final int? notificationResponsivenessMillis;

  const AndroidGeofenceSettingsWire({
    required this.initialTriggers,
    this.expirationDurationMillis,
    required this.loiteringDelayMillis,
    this.notificationResponsivenessMillis,
  });
}

class GeofenceWire {
  final String id;
  final LocationWire location;
  final double radiusMeters;
  final List<GeofenceEvent> triggers;
  final IosGeofenceSettingsWire iosSettings;
  final AndroidGeofenceSettingsWire androidSettings;
  final int callbackHandle;

  /// Opaque caller-owned value persisted with this registration and returned
  /// with callbacks. The plugin never interprets this value.
  ///
  /// This nullable trailing field preserves older wire construction sites.
  final int? callbackContext;

  const GeofenceWire({
    required this.id,
    required this.location,
    required this.radiusMeters,
    required this.triggers,
    required this.iosSettings,
    required this.androidSettings,
    required this.callbackHandle,
    this.callbackContext,
  });
}

class ActiveGeofenceWire {
  final String id;
  final LocationWire location;
  final double radiusMeters;
  final List<GeofenceEvent> triggers;

  final AndroidGeofenceSettingsWire? androidSettings;

  /// Absolute Android wall-clock expiration deadline for this active
  /// registration. Null means the registration does not expire or the platform
  /// does not expose an Android deadline.
  final int? expirationDeadlineMillis;

  const ActiveGeofenceWire({
    required this.id,
    required this.location,
    required this.radiusMeters,
    required this.triggers,
    required this.androidSettings,
    this.expirationDeadlineMillis,
  });
}

class GeofenceCallbackParamsWire {
  final List<ActiveGeofenceWire> geofences;
  final GeofenceEvent event;
  final LocationWire? location;
  final int? eventAtMillis;
  final int callbackHandle;

  /// Unique ID for this native delivery attempt. Set on Android and iOS.
  ///
  /// This is not a durable business or physical-transition idempotency key.
  /// This nullable field retains its established wire position for compatibility;
  /// newer nullable fields may follow it and fields must not be reordered.
  final String? eventId;

  /// Opaque callback contexts keyed by triggering geofence ID.
  /// Registrations without a context are absent from this map.
  final Map<String, int>? callbackContextsByGeofenceId;

  /// Correlates this delivery with the root native transition that caused it.
  ///
  /// Direct native deliveries use the same value as [eventId]. A higher-level
  /// processor may create a new delivery [eventId] while preserving this root
  /// identity across confirmation, retry, and application queueing.
  final String? traceId;

  const GeofenceCallbackParamsWire({
    required this.geofences,
    required this.event,
    required this.location,
    this.eventAtMillis,
    required this.callbackHandle,
    this.eventId,
    this.callbackContextsByGeofenceId,
    this.traceId,
  });
}

/// Errors that can occur when interacting with the native geofence API.
enum NativeGeofenceErrorCode {
  unknown,

  /// A plugin internal error. Please report these as bugs on GitHub.
  pluginInternal,

  /// The arguments passed to the method are invalid.
  invalidArguments,

  /// An error occurred while communicating with the native platform.
  channelError,

  /// The required location permission was not granted.
  ///
  /// On Android we need: `ACCESS_FINE_LOCATION`
  /// On iOS we need: `NSLocationWhenInUseUsageDescription`
  ///
  /// Please use an external permission manager such as "permission_handler" to
  /// request the permission from the user.
  missingLocationPermission,

  /// The required background location permission was not granted.
  ///
  /// On Android we need: `ACCESS_BACKGROUND_LOCATION` (for API level 29+)
  /// On iOS we need: `NSLocationAlwaysAndWhenInUseUsageDescription`
  ///
  /// Please use an external permission manager such as "permission_handler" to
  /// request the permission from the user.
  missingBackgroundLocationPermission,

  /// iOS Precise Location access is disabled, so Core Location cannot monitor
  /// circular regions.
  missingPreciseLocationPermission,

  /// The geofence deletion failed because the geofence was not found.
  /// This is safe to ignore.
  geofenceNotFound,

  /// The specified geofence callback was not found.
  /// This can happen for old geofence callback functions that were
  /// moved/renamed. Please re-create those geofences.
  callbackNotFound,

  /// The specified geofence callback function signature is invalid.
  /// This can happen if the callback function signature has changed or due to
  /// plugin contract changes.
  callbackInvalid,

  /// iOS Core Location rejected or did not confirm region monitoring.
  iosRegionMonitoringFailed,

  /// An Android component required by the plugin was removed or disabled in
  /// the merged application manifest.
  androidManifestComponentMissing,

  /// Android rejected starting a foreground service from the current app state.
  androidForegroundServiceStartNotAllowed,

  /// Android foreground-service manifest or runtime prerequisites are missing.
  androidForegroundServiceConfigurationMissing,

  /// Notification permission or notification delivery is unavailable.
  missingNotificationPermission,

  /// Android did not confirm foreground promotion before the watchdog expired.
  androidForegroundServicePromotionTimeout,
}

enum NativeGeofencePlatform { android, ios }

enum NativeGeofenceRegistrationHealth {
  noRegistrations,
  healthy,
  degraded,
  unavailable,
  unknown,
}

enum NativeGeofenceCallbackRefreshState {
  current,
  refreshRequired,
  unknown,
  notApplicable,
}

enum NativeGeofenceBackgroundRefreshStatus {
  available,
  denied,
  restricted,
  unknown,
}

class NativeGeofenceLifecycleFactWire {
  final int occurredAtMillis;
  final bool succeeded;
  final String outcome;
  final int? geofenceCount;

  const NativeGeofenceLifecycleFactWire({
    required this.occurredAtMillis,
    required this.succeeded,
    required this.outcome,
    this.geofenceCount,
  });
}

/// Privacy-safe evidence for one native callback-delivery stage.
class NativeGeofenceDeliveryTraceWire {
  final int sequence;
  final int occurredAtMillis;
  final int? elapsedRealtimeMillis;
  final String? traceId;
  final String stage;
  final String outcome;
  final String? event;
  final int? geofenceCount;
  final int? attempt;
  final String? owner;
  final String? reasonCode;
  final int? durationMillis;
  final int? queueAgeMillis;
  final bool? hasLocation;
  final int? locationAgeMillis;
  final double? accuracyMeters;
  final String? processorSource;
  final String? processorClass;
  final String? errorType;

  const NativeGeofenceDeliveryTraceWire({
    required this.sequence,
    required this.occurredAtMillis,
    this.elapsedRealtimeMillis,
    this.traceId,
    required this.stage,
    required this.outcome,
    this.event,
    this.geofenceCount,
    this.attempt,
    this.owner,
    this.reasonCode,
    this.durationMillis,
    this.queueAgeMillis,
    this.hasLocation,
    this.locationAgeMillis,
    this.accuracyMeters,
    this.processorSource,
    this.processorClass,
    this.errorType,
  });
}

class NativeGeofenceStatusWire {
  final NativeGeofencePlatform platform;
  final String? osVersion;
  final int persistedGeofenceCount;

  /// Whether the platform's required foreground location authorization is
  /// granted. This means fine location on Android and When In Use or Always
  /// authorization on iOS.
  final bool? locationPermissionGranted;

  final bool? backgroundLocationPermissionGranted;

  /// Whether iOS granted full/precise location accuracy. Null on Android.
  final bool? preciseLocationPermissionGranted;

  /// Whether iOS can wake the app to deliver region events in the background.
  /// Null on Android.
  final NativeGeofenceBackgroundRefreshStatus? backgroundRefreshStatus;

  final bool? notificationPermissionGranted;
  final bool? locationServicesEnabled;
  final bool? monitoringAvailable;
  final bool? playServicesAvailable;
  final bool? callbackPendingIntentAvailable;
  final bool? callbackReceiverAvailable;
  final bool? canEnumerateLivePlatformRegistrations;
  final int? pluginOwnedMonitoringCount;
  final bool? callbackDispatcherRegistered;
  final NativeGeofenceCallbackRefreshState callbackRefreshState;
  final NativeGeofenceRegistrationHealth registrationHealth;
  final NativeGeofenceLifecycleFactWire? lastRegistrationFact;
  final NativeGeofenceLifecycleFactWire? lastRemovalFact;
  final NativeGeofenceLifecycleFactWire? lastBroadcastFact;
  final NativeGeofenceLifecycleFactWire? lastEnqueueFact;
  final NativeGeofenceLifecycleFactWire? lastWorkerFact;
  final NativeGeofenceLifecycleFactWire? lastRecoveryFact;
  final NativeGeofenceLifecycleFactWire? lastForegroundFact;
  final List<NativeGeofenceDeliveryTraceWire>? deliveryTrace;
  final int? deliveryTraceDroppedCount;
  final String? packageVersion;
  final String? buildRevision;

  const NativeGeofenceStatusWire({
    required this.platform,
    this.osVersion,
    required this.persistedGeofenceCount,
    this.locationPermissionGranted,
    this.backgroundLocationPermissionGranted,
    this.preciseLocationPermissionGranted,
    this.backgroundRefreshStatus,
    this.notificationPermissionGranted,
    this.locationServicesEnabled,
    this.monitoringAvailable,
    this.playServicesAvailable,
    this.callbackPendingIntentAvailable,
    this.callbackReceiverAvailable,
    this.canEnumerateLivePlatformRegistrations,
    this.pluginOwnedMonitoringCount,
    this.callbackDispatcherRegistered,
    required this.callbackRefreshState,
    required this.registrationHealth,
    this.lastRegistrationFact,
    this.lastRemovalFact,
    this.lastBroadcastFact,
    this.lastEnqueueFact,
    this.lastWorkerFact,
    this.lastRecoveryFact,
    this.lastForegroundFact,
    this.deliveryTrace,
    this.deliveryTraceDroppedCount,
    this.packageVersion,
    this.buildRevision,
  });
}

/// Read-only point-in-time plugin-owned state used by synchronization
/// inspection.
class NativeGeofenceSynchronizationStateWire {
  final NativeGeofencePlatform platform;
  final List<String> pluginOwnedIds;
  final List<GeofenceWire> registrations;
  final List<String> inactiveRegistrationIds;
  final String? registrationFingerprint;

  /// Platform-normalized fingerprint computed natively for the desired state.
  final String desiredRegistrationFingerprint;
  final bool callbackFingerprintCurrent;
  final double? iosMaximumRegionMonitoringDistance;

  const NativeGeofenceSynchronizationStateWire({
    required this.platform,
    required this.pluginOwnedIds,
    required this.registrations,
    required this.inactiveRegistrationIds,
    this.registrationFingerprint,
    required this.desiredRegistrationFingerprint,
    required this.callbackFingerprintCurrent,
    this.iosMaximumRegionMonitoringDistance,
  });
}

enum NativeGeofenceSynchronizationReasonWire {
  firstRun,
  callbackFingerprintChanged,
  registrationDrift,
}

/// Authoritative result of one serialized native inspect-and-mutate pass.
class NativeGeofenceSynchronizationResultWire {
  final bool didSynchronize;
  final List<NativeGeofenceSynchronizationReasonWire> reasons;
  final int desiredCount;
  final int previousCount;
  final String registrationFingerprint;

  const NativeGeofenceSynchronizationResultWire({
    required this.didSynchronize,
    required this.reasons,
    required this.desiredCount,
    required this.previousCount,
    required this.registrationFingerprint,
  });
}

@HostApi()
abstract class NativeGeofenceApi {
  void initialize({required int callbackDispatcherHandle});

  @async
  void createGeofence({required GeofenceWire geofence});

  /// Restores a canonical registration while preserving its existing Android
  /// absolute expiration deadline. Intended for higher-level transactional
  /// coordinators that already own an exact before-image.
  @async
  void restoreGeofence({
    required GeofenceWire geofence,
    int? expirationDeadlineMillis,
  });

  @async
  void reCreateAfterReboot();

  @async
  NativeGeofenceStatusWire getStatus();

  @async
  NativeGeofenceSynchronizationStateWire getSynchronizationState({
    required List<GeofenceWire> desiredRegistrations,
  });

  @async
  NativeGeofenceSynchronizationResultWire synchronizeGeofences({
    required List<GeofenceWire> desiredRegistrations,
    required bool removeUnlisted,
  });

  List<String> getGeofenceIds();

  List<ActiveGeofenceWire> getGeofences();

  @async
  void removeGeofenceById({required String id});

  @async
  void removeAllGeofences();
}

@HostApi()
abstract class NativeGeofenceBackgroundApi {
  void triggerApiInitialized();

  @async
  void promoteToForeground();

  void demoteToBackground();
}

@FlutterApi()
abstract class NativeGeofenceTriggerApi {
  @async
  void geofenceTriggered(GeofenceCallbackParamsWire params);
}
