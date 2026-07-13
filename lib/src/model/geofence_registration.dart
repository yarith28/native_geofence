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
