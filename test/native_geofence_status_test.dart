import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model_mapper.dart';

void main() {
  test('status mapper preserves nullable platform evidence and lifecycle facts',
      () {
    final wire = NativeGeofenceStatusWire(
      platform: NativeGeofencePlatform.android,
      osVersion: '35',
      persistedGeofenceIds: const <String>['a'],
      locationPermissionGranted: true,
      backgroundLocationPermissionGranted: false,
      notificationPermissionGranted: null,
      locationServicesEnabled: true,
      monitoringAvailable: null,
      playServicesAvailable: true,
      callbackPendingIntentAvailable: false,
      callbackReceiverAvailable: true,
      canEnumerateLivePlatformRegistrations: false,
      pluginOwnedMonitoringCount: null,
      callbackDispatcherRegistered: true,
      callbackRefreshState: NativeGeofenceCallbackRefreshState.refreshRequired,
      registrationHealth: NativeGeofenceRegistrationHealth.degraded,
      lastRegistrationFact: NativeGeofenceLifecycleFactWire(
        occurredAtMillis: 123,
        succeeded: true,
        outcome: 'registered',
        geofenceCount: 1,
      ),
      lastRemovalFact: null,
      lastBroadcastFact: null,
      lastEnqueueFact: null,
      lastWorkerFact: null,
      lastRecoveryFact: null,
      lastForegroundFact: null,
    );

    final status = wire.fromWire();

    expect(status.platform, NativeGeofencePlatform.android);
    expect(status.persistedGeofenceIds, const <String>['a']);
    expect(status.locationPermissionGranted, isTrue);
    expect(status.notificationPermissionGranted, isNull);
    expect(status.canEnumerateLivePlatformRegistrations, isFalse);
    expect(status.lastRegistrationFact?.occurredAt.millisecondsSinceEpoch, 123);
    expect(status.lastRegistrationFact?.outcome, 'registered');
    expect(status.toJson()['locationPermissionGranted'], isTrue);
    expect(status.toJson(), isNot(contains('fineLocationPermissionGranted')));
    expect(
      () => status.persistedGeofenceIds.add('mutate'),
      throwsUnsupportedError,
    );
  });
}
