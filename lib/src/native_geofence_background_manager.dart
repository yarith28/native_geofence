import 'dart:async';

import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model_mapper.dart';
import 'package:native_geofence/src/model/native_geofence_exception.dart';

class NativeGeofenceBackgroundManager {
  static NativeGeofenceBackgroundManager? _instance;

  /// The singleton instance of [NativeGeofenceBackgroundManager].
  ///
  /// This is initialized by the plugin's background callback dispatcher and by
  /// `NativeGeofenceManager.initialize()` on iOS, where foreground delivery uses
  /// the same process-wide callback runtime.
  /// Access before a geofence callback initializes it throws a
  /// [NativeGeofenceException].
  static NativeGeofenceBackgroundManager get instance {
    final instance = _instance;
    if (instance == null) {
      throw NativeGeofenceException.internal(
        message: 'NativeGeofenceBackgroundManager has not been initialized '
            'yet; initialize NativeGeofenceManager on iOS or access this only '
            'from a geofence callback.',
      );
    }
    return instance;
  }

  final NativeGeofenceBackgroundApi _api;

  NativeGeofenceBackgroundManager._(this._api);

  /// Promote the geofence callback to an Android foreground service.
  ///
  /// Android only, has no effect on iOS (but is safe to call).
  ///
  /// Throws [NativeGeofenceException].
  Future<void> promoteToForeground() async => _api
      .promoteToForeground()
      .catchError(NativeGeofenceExceptionMapper.catchError<void>);

  /// Demote the geofence service from an Android foreground service to a
  /// background service.
  ///
  /// Android only, has no effect on iOS (but is safe to call).
  ///
  /// Throws [NativeGeofenceException].
  Future<void> demoteToBackground() async => _api
      .demoteToBackground()
      .catchError(NativeGeofenceExceptionMapper.catchError<void>);
}

/// Private method internal to plugin, do not use.
Future<void> createNativeGeofenceBackgroundManagerInstance() async {
  final api = ensureNativeGeofenceBackgroundManagerInstance();
  await api.triggerApiInitialized();
}

/// Private method internal to the plugin. Creates the singleton at most once
/// and returns the exact background API owned by it.
NativeGeofenceBackgroundApi ensureNativeGeofenceBackgroundManagerInstance({
  NativeGeofenceBackgroundApi Function()? createApi,
}) {
  final existing = NativeGeofenceBackgroundManager._instance;
  if (existing != null) return existing._api;

  final api = (createApi ?? NativeGeofenceBackgroundApi.new)();
  NativeGeofenceBackgroundManager._instance =
      NativeGeofenceBackgroundManager._(api);
  return api;
}

/// Test-only reset for isolate-local singleton state.
void resetNativeGeofenceBackgroundManagerForTesting() {
  NativeGeofenceBackgroundManager._instance = null;
}
