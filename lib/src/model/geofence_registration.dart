import 'package:native_geofence/src/model/model.dart';
import 'package:native_geofence/src/typedefs.dart';

/// A [Geofence] paired with the callback that should run when it triggers.
///
/// This is an app-owned canonical registration definition. Pass a list of
/// these to `NativeGeofenceManager.inspectSynchronization` or
/// `NativeGeofenceManager.ensureSynchronized` after initialization and after
/// obtaining the required permissions.
class GeofenceRegistration {
  /// The geofence region to register with the platform.
  final Geofence geofence;

  /// The callback associated with [geofence].
  ///
  /// This must be a top-level or static function annotated with
  /// `@pragma('vm:entry-point')`. Closures and instance methods cannot be
  /// resolved from a background isolate and are rejected.
  final GeofenceCallback callback;

  /// Optional opaque signed 64-bit routing value stored with [geofence].
  ///
  /// The plugin never interprets this value. When this registration triggers,
  /// it is returned under the geofence ID in
  /// [GeofenceCallbackParams.callbackContextsByGeofenceId]. Registrations
  /// without a context remain valid and are absent from that map.
  final int? callbackContext;

  const GeofenceRegistration({
    required this.geofence,
    required this.callback,
    this.callbackContext,
  });

  @override
  String toString() => 'GeofenceRegistration(geofence: $geofence)';
}

/// Why native state differs from the app-owned desired registrations.
enum NativeGeofenceSynchronizationReason {
  /// No successful synchronization fingerprint has been committed yet.
  firstRun,

  /// Stored callback metadata may not match the current application build or
  /// a desired callback/context changed.
  callbackFingerprintChanged,

  /// Plugin-owned IDs, geometry, trigger semantics, settings, active state, or
  /// registration fingerprint differ from the desired list.
  registrationDrift,
}

/// Read-only comparison of desired registrations with plugin-owned state.
///
/// Lists are sorted for deterministic diagnostics. Registration fingerprints
/// are opaque comparison tokens and can contain registration and callback
/// metadata; do not log or persist them as privacy-safe diagnostics.
class NativeGeofenceSynchronizationInspection {
  /// Whether the point-in-time native snapshot matched the desired state.
  ///
  /// A later `NativeGeofenceManager.ensureSynchronized` call revalidates and
  /// may differ.
  final bool matchesDesired;

  /// Reasons observed in this inspection snapshot, or an empty set when matched.
  final Set<NativeGeofenceSynchronizationReason> reasons;

  /// Sorted IDs supplied by the application.
  final List<String> desiredIds;

  /// Sorted IDs owned by the plugin's durable state.
  final List<String> currentIds;

  /// Desired IDs absent from plugin-owned durable state.
  final List<String> missingIds;

  /// Plugin-owned IDs omitted from the desired list when removal is enabled.
  final List<String> unlistedIds;

  /// IDs whose platform geometry, triggers, or settings differ.
  final List<String> driftedIds;

  /// IDs whose callback handle or opaque callback context differs.
  final List<String> metadataChangedIds;

  /// Desired IDs whose durable/platform-active state is incomplete.
  final List<String> inactiveIds;

  /// Opaque platform-normalized fingerprint calculated natively from the
  /// desired registrations.
  final String desiredRegistrationFingerprint;

  /// Last successfully committed fingerprint, when one exists.
  final String? currentRegistrationFingerprint;

  const NativeGeofenceSynchronizationInspection({
    required this.matchesDesired,
    required this.reasons,
    required this.desiredIds,
    required this.currentIds,
    required this.missingIds,
    required this.unlistedIds,
    required this.driftedIds,
    required this.metadataChangedIds,
    required this.inactiveIds,
    required this.desiredRegistrationFingerprint,
    required this.currentRegistrationFingerprint,
  });

  int get desiredCount => desiredIds.length;

  int get currentCount => currentIds.length;

  Map<String, Object?> toJson() => {
        'matchesDesired': matchesDesired,
        'reasons': reasons.map((reason) => reason.name).toList()..sort(),
        'desiredCount': desiredCount,
        'currentCount': currentCount,
        'desiredIds': [...desiredIds]..sort(),
        'currentIds': [...currentIds]..sort(),
        'missingIds': [...missingIds]..sort(),
        'unlistedIds': [...unlistedIds]..sort(),
        'driftedIds': [...driftedIds]..sort(),
        'metadataChangedIds': [...metadataChangedIds]..sort(),
        'inactiveIds': [...inactiveIds]..sort(),
        'desiredRegistrationFingerprint': desiredRegistrationFingerprint,
        'currentRegistrationFingerprint': currentRegistrationFingerprint,
      };
}

/// Result of a successful conditional synchronization pass.
class NativeGeofenceSynchronizationReport {
  /// Whether the authoritative native pass changed registration or
  /// synchronization metadata; false is a native-confirmed no-op.
  final bool didSynchronize;

  /// Reasons observed natively immediately before reconciliation, or an empty
  /// set for a no-op.
  final Set<NativeGeofenceSynchronizationReason> reasons;

  /// Number of desired registrations supplied by the application.
  final int desiredCount;

  /// Number of plugin-owned IDs observed before reconciliation.
  final int previousCount;

  /// Opaque desired fingerprint returned by the native pass; committed for a
  /// mutating pass and already matching for a no-op.
  final String registrationFingerprint;

  const NativeGeofenceSynchronizationReport({
    required this.didSynchronize,
    required this.reasons,
    required this.desiredCount,
    required this.previousCount,
    required this.registrationFingerprint,
  });

  Map<String, Object?> toJson() => {
        'didSynchronize': didSynchronize,
        'reasons': reasons.map((reason) => reason.name).toList()..sort(),
        'desiredCount': desiredCount,
        'previousCount': previousCount,
        'registrationFingerprint': registrationFingerprint,
      };
}
