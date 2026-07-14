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
  /// No successful authoritative synchronization fingerprint has been
  /// committed yet.
  firstRun,

  /// Stored callback metadata may not match the current application build or
  /// a desired callback/context changed.
  callbackFingerprintChanged,

  /// Plugin-owned IDs, geometry, trigger semantics, settings, active state, or
  /// authoritative registration fingerprint differ from the desired list.
  registrationDrift,
}

/// How a desired registration list relates to all plugin-owned registrations.
enum NativeGeofenceSynchronizationScope {
  /// The desired list is the complete source of truth; omitted IDs are removed.
  authoritative,

  /// The desired list manages only its own IDs; registrations outside it are
  /// preserved and cannot make this scope stale.
  partial,
}

/// Read-only comparison of desired registrations with plugin-owned state.
///
/// Lists are sorted for deterministic diagnostics. Registration fingerprints
/// are opaque comparison tokens and can contain registration and callback
/// metadata; do not log or persist them as privacy-safe diagnostics.
class NativeGeofenceSynchronizationInspection {
  /// Whether this comparison covers all plugin-owned IDs or only the supplied
  /// subset.
  final NativeGeofenceSynchronizationScope scope;

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

  /// Opaque platform-normalized fingerprint calculated natively from exactly
  /// the desired registrations in this [scope].
  final String desiredRegistrationFingerprint;

  /// Last successfully committed authoritative fingerprint, when one exists.
  ///
  /// It is comparable with [desiredRegistrationFingerprint] only when [scope]
  /// is [NativeGeofenceSynchronizationScope.authoritative].
  final String? currentRegistrationFingerprint;

  const NativeGeofenceSynchronizationInspection({
    this.scope = NativeGeofenceSynchronizationScope.authoritative,
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

  /// Whether the authoritative fingerprint is current, or `null` when a
  /// partial desired list makes the global fingerprint inapplicable.
  bool? get registrationFingerprintCurrent =>
      scope == NativeGeofenceSynchronizationScope.authoritative
          ? currentRegistrationFingerprint == desiredRegistrationFingerprint
          : null;

  Map<String, Object?> toJson() => {
        'scope': scope.name,
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
        'registrationFingerprintCurrent': registrationFingerprintCurrent,
      };
}

/// Result of a successful conditional synchronization pass.
class NativeGeofenceSynchronizationReport {
  /// Whether this pass treated the desired list as complete or as a subset.
  final NativeGeofenceSynchronizationScope scope;

  /// Whether the native transaction changed registration or synchronization
  /// metadata; false is a native-confirmed no-op.
  final bool didSynchronize;

  /// Reasons observed natively immediately before reconciliation, or an empty
  /// set for a no-op.
  final Set<NativeGeofenceSynchronizationReason> reasons;

  /// Number of desired registrations supplied by the application.
  final int desiredCount;

  /// Number of plugin-owned IDs observed before reconciliation.
  final int previousCount;

  /// Opaque fingerprint of exactly the desired list returned by the native
  /// pass. An authoritative mutating pass commits it as the global
  /// fingerprint; a partial pass must not replace that global fingerprint.
  final String registrationFingerprint;

  const NativeGeofenceSynchronizationReport({
    this.scope = NativeGeofenceSynchronizationScope.authoritative,
    required this.didSynchronize,
    required this.reasons,
    required this.desiredCount,
    required this.previousCount,
    required this.registrationFingerprint,
  });

  Map<String, Object?> toJson() => {
        'scope': scope.name,
        'didSynchronize': didSynchronize,
        'reasons': reasons.map((reason) => reason.name).toList()..sort(),
        'desiredCount': desiredCount,
        'previousCount': previousCount,
        'registrationFingerprint': registrationFingerprint,
      };
}
