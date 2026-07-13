import 'package:native_geofence/src/model/model.dart';

/// Called when a registered geofence emits an event.
///
/// Functions passed to `NativeGeofenceManager.createGeofence` or a
/// `GeofenceRegistration` must be top-level or static functions annotated with
/// `@pragma('vm:entry-point')`. Closures and instance methods do not have a
/// stable background-isolate handle and are rejected.
///
/// Keep callbacks short. Persist important state first, enqueue long-running
/// work in an app-owned durable system, then return.
typedef GeofenceCallback = Future<void> Function(GeofenceCallbackParams params);
