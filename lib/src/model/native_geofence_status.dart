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
}

/// Read-only evidence about native_geofence prerequisites and lifecycle state.
///
/// Nullable fields mean the platform cannot provide that evidence or the
/// evidence has not yet been observed. On Android,
/// [canEnumerateLivePlatformRegistrations] is false because Play Services does
/// not expose its live geofence set to the plugin.
class NativeGeofenceStatus {
  final NativeGeofencePlatform platform;
  final String? osVersion;
  final List<String> persistedGeofenceIds;
  final bool? fineLocationPermissionGranted;
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
    this.fineLocationPermissionGranted,
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
}
