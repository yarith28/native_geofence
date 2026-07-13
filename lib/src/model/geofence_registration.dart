import 'package:native_geofence/src/model/model.dart';
import 'package:native_geofence/src/typedefs.dart';

/// An app-owned desired geofence registration.
///
/// This groups native geometry with the Dart callback and optional opaque
/// routing context needed to register or synchronize it.
class GeofenceRegistration {
  final Geofence geofence;
  final GeofenceCallback callback;
  final int? callbackContext;

  const GeofenceRegistration({
    required this.geofence,
    required this.callback,
    this.callbackContext,
  });
}

/// Why native state differs from the app-owned desired registrations.
enum NativeGeofenceSynchronizationReason {
  firstRun,
  callbackFingerprintChanged,
  registrationDrift,
}

/// Read-only comparison of desired registrations with plugin-owned state.
class NativeGeofenceSynchronizationInspection {
  final bool matchesDesired;
  final Set<NativeGeofenceSynchronizationReason> reasons;
  final List<String> desiredIds;
  final List<String> currentIds;
  final List<String> missingIds;
  final List<String> unlistedIds;
  final List<String> driftedIds;
  final List<String> metadataChangedIds;
  final List<String> inactiveIds;
  final String desiredRegistrationFingerprint;
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
}

/// Result of a successful conditional synchronization pass.
class NativeGeofenceSynchronizationReport {
  final bool didSynchronize;
  final Set<NativeGeofenceSynchronizationReason> reasons;
  final int desiredCount;
  final int previousCount;
  final String registrationFingerprint;

  const NativeGeofenceSynchronizationReport({
    required this.didSynchronize,
    required this.reasons,
    required this.desiredCount,
    required this.previousCount,
    required this.registrationFingerprint,
  });
}
