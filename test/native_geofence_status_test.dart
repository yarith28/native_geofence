import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model_mapper.dart';

void main() {
  test('status mapper preserves nullable platform evidence and lifecycle facts',
      () {
    final wire = NativeGeofenceStatusWire(
      platform: NativeGeofencePlatform.android,
      osVersion: '35',
      persistedGeofenceCount: 1,
      locationPermissionGranted: true,
      backgroundLocationPermissionGranted: false,
      preciseLocationPermissionGranted: null,
      backgroundRefreshStatus: null,
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
      deliveryTrace: [
        NativeGeofenceDeliveryTraceWire(
          sequence: 7,
          occurredAtMillis: 456,
          traceId: 'trace-1',
          stage: 'bridge_decision',
          outcome: 'native_accepted',
          event: 'exit',
          geofenceCount: 1,
          owner: 'native',
          durationMillis: 12,
          locationAgeMillis: 34,
        ),
      ],
      deliveryTraceDroppedCount: 2,
      packageVersion: '1.3.1',
      buildRevision: 'abc123',
    );

    final status = wire.fromWire();

    expect(status.platform, NativeGeofencePlatform.android);
    expect(status.persistedGeofenceCount, 1);
    expect(status.locationPermissionGranted, isTrue);
    expect(status.preciseLocationPermissionGranted, isNull);
    expect(status.backgroundRefreshStatus, isNull);
    expect(status.notificationPermissionGranted, isNull);
    expect(status.canEnumerateLivePlatformRegistrations, isFalse);
    expect(status.lastRegistrationFact?.occurredAt.millisecondsSinceEpoch, 123);
    expect(status.lastRegistrationFact?.outcome, 'registered');
    expect(status.deliveryTrace.single.traceId, 'trace-1');
    expect(status.deliveryTrace.single.outcome, 'native_accepted');
    expect(status.deliveryTraceDroppedCount, 2);
    expect(status.packageVersion, '1.3.1');
    expect(status.buildRevision, 'abc123');
    expect(status.toJson()['locationPermissionGranted'], isTrue);
    expect(status.toJson()['preciseLocationPermissionGranted'], isNull);
    expect(status.toJson()['backgroundRefreshStatus'], isNull);
    expect(status.toJson(), isNot(contains('fineLocationPermissionGranted')));
    expect(status.toJson(), isNot(contains('persistedGeofenceIds')));
  });
}
