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

/// One privacy-safe, correlated stage in native callback delivery.
class NativeGeofenceDeliveryTrace {
  final int sequence;
  final DateTime occurredAt;
  final Duration? elapsedRealtime;
  final String? traceId;
  final String stage;
  final String outcome;
  final String? event;
  final int? geofenceCount;
  final int? attempt;
  final String? owner;
  final String? reasonCode;
  final Duration? duration;
  final Duration? queueAge;
  final bool? hasLocation;
  final Duration? locationAge;
  final double? accuracyMeters;
  final String? processorSource;
  final String? processorClass;
  final String? errorType;

  const NativeGeofenceDeliveryTrace({
    required this.sequence,
    required this.occurredAt,
    this.elapsedRealtime,
    this.traceId,
    required this.stage,
    required this.outcome,
    this.event,
    this.geofenceCount,
    this.attempt,
    this.owner,
    this.reasonCode,
    this.duration,
    this.queueAge,
    this.hasLocation,
    this.locationAge,
    this.accuracyMeters,
    this.processorSource,
    this.processorClass,
    this.errorType,
  });

  Map<String, Object?> toJson() => {
        'sequence': sequence,
        'occurredAtMillis': occurredAt.millisecondsSinceEpoch,
        'elapsedRealtimeMillis': elapsedRealtime?.inMilliseconds,
        'traceId': traceId,
        'stage': stage,
        'outcome': outcome,
        'event': event,
        'geofenceCount': geofenceCount,
        'attempt': attempt,
        'owner': owner,
        'reasonCode': reasonCode,
        'durationMillis': duration?.inMilliseconds,
        'queueAgeMillis': queueAge?.inMilliseconds,
        'hasLocation': hasLocation,
        'locationAgeMillis': locationAge?.inMilliseconds,
        'accuracyMeters': accuracyMeters,
        'processorSource': processorSource,
        'processorClass': processorClass,
        'errorType': errorType,
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

  /// Number of plugin-owned registrations represented by durable native state.
  ///
  /// Registration IDs are intentionally excluded from this diagnostic
  /// snapshot because they are app-owned values and may contain sensitive
  /// information.
  final int persistedGeofenceCount;

  /// Whether the platform's required foreground location authorization is
  /// granted.
  ///
  /// On Android this means `ACCESS_FINE_LOCATION`. On iOS this means either
  /// When In Use or Always authorization; consult
  /// [backgroundLocationPermissionGranted] to distinguish background access.
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
  final NativeGeofenceLifecycleFact? lastRegistrationFact;
  final NativeGeofenceLifecycleFact? lastRemovalFact;
  final NativeGeofenceLifecycleFact? lastBroadcastFact;
  final NativeGeofenceLifecycleFact? lastEnqueueFact;
  final NativeGeofenceLifecycleFact? lastWorkerFact;
  final NativeGeofenceLifecycleFact? lastRecoveryFact;
  final NativeGeofenceLifecycleFact? lastForegroundFact;
  final List<NativeGeofenceDeliveryTrace> deliveryTrace;
  final int deliveryTraceDroppedCount;
  final String? packageVersion;
  final String? buildRevision;

  const NativeGeofenceStatus({
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
    this.deliveryTrace = const [],
    this.deliveryTraceDroppedCount = 0,
    this.packageVersion,
    this.buildRevision,
  });

  Map<String, Object?> toJson() => {
        'platform': platform.name,
        'osVersion': osVersion,
        'persistedGeofenceCount': persistedGeofenceCount,
        'locationPermissionGranted': locationPermissionGranted,
        'backgroundLocationPermissionGranted':
            backgroundLocationPermissionGranted,
        'preciseLocationPermissionGranted': preciseLocationPermissionGranted,
        'backgroundRefreshStatus': backgroundRefreshStatus?.name,
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
        'deliveryTrace': deliveryTrace.map((entry) => entry.toJson()).toList(),
        'deliveryTraceDroppedCount': deliveryTraceDroppedCount,
        'packageVersion': packageVersion,
        'buildRevision': buildRevision,
      };
}
