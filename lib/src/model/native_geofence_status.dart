import 'package:native_geofence/src/generated/platform_bindings.g.dart';

/// A privacy-safe fact recorded at an authoritative native lifecycle boundary.
class NativeGeofenceLifecycleFact {
  final DateTime occurredAt;
  final bool succeeded;
  final String outcome;
  final int? geofenceCount;

  const NativeGeofenceLifecycleFact({
    required this.occurredAt,
    required this.succeeded,
    required this.outcome,
    this.geofenceCount,
  });

  Map<String, Object?> toJson() => {
        'occurredAtMillis': occurredAt.millisecondsSinceEpoch,
        'succeeded': succeeded,
        'outcome': outcome,
        'geofenceCount': geofenceCount,
      };
}

/// Read-only evidence about native_geofence prerequisites and lifecycle state.
///
/// Nullable fields mean the platform cannot provide that evidence or the
/// evidence has not yet been observed. On Android,
/// [canEnumerateLivePlatformRegistrations] is false because Play Services does
/// not expose its live geofence set to the plugin.
///
/// Lifecycle facts are the latest observed native boundary for each stage.
/// They are not a complete audit trail, proof that a registration is currently
/// armed, or a guarantee of future delivery.
class NativeGeofenceStatus {
  final NativeGeofencePlatform platform;
  final String? osVersion;
  final List<String> persistedGeofenceIds;

  /// Whether the platform's required foreground location authorization is
  /// granted.
  ///
  /// On Android this means `ACCESS_FINE_LOCATION`. On iOS this means either
  /// When In Use or Always authorization; consult
  /// [backgroundLocationPermissionGranted] to distinguish background access.
  final bool? locationPermissionGranted;

  final bool? backgroundLocationPermissionGranted;
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
  final NativeGeofenceLifecycleFact? lastRegistrationFact;
  final NativeGeofenceLifecycleFact? lastRemovalFact;
  final NativeGeofenceLifecycleFact? lastBroadcastFact;
  final NativeGeofenceLifecycleFact? lastEnqueueFact;
  final NativeGeofenceLifecycleFact? lastWorkerFact;
  final NativeGeofenceLifecycleFact? lastRecoveryFact;
  final NativeGeofenceLifecycleFact? lastForegroundFact;

  const NativeGeofenceStatus({
    required this.platform,
    this.osVersion,
    required this.persistedGeofenceIds,
    this.locationPermissionGranted,
    this.backgroundLocationPermissionGranted,
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
  });

  Map<String, Object?> toJson() => {
        'platform': platform.name,
        'osVersion': osVersion,
        'persistedGeofenceIds': [...persistedGeofenceIds]..sort(),
        'locationPermissionGranted': locationPermissionGranted,
        'backgroundLocationPermissionGranted':
            backgroundLocationPermissionGranted,
        'notificationPermissionGranted': notificationPermissionGranted,
        'locationServicesEnabled': locationServicesEnabled,
        'monitoringAvailable': monitoringAvailable,
        'playServicesAvailable': playServicesAvailable,
        'callbackPendingIntentAvailable': callbackPendingIntentAvailable,
        'callbackReceiverAvailable': callbackReceiverAvailable,
        'canEnumerateLivePlatformRegistrations':
            canEnumerateLivePlatformRegistrations,
        'pluginOwnedMonitoringCount': pluginOwnedMonitoringCount,
        'callbackDispatcherRegistered': callbackDispatcherRegistered,
        'callbackRefreshState': callbackRefreshState.name,
        'registrationHealth': registrationHealth.name,
        'lastRegistrationFact': lastRegistrationFact?.toJson(),
        'lastRemovalFact': lastRemovalFact?.toJson(),
        'lastBroadcastFact': lastBroadcastFact?.toJson(),
        'lastEnqueueFact': lastEnqueueFact?.toJson(),
        'lastWorkerFact': lastWorkerFact?.toJson(),
        'lastRecoveryFact': lastRecoveryFact?.toJson(),
        'lastForegroundFact': lastForegroundFact?.toJson(),
      };
}
