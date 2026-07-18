import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/native_geofence.dart';

@pragma('vm:entry-point')
Future<void> publicApiCallback(GeofenceCallbackParams params) async {}

void main() {
  test('barrel exports callback typedef and deterministic geofence JSON', () {
    final GeofenceCallback callback = publicApiCallback;
    const location = Location(
      latitude: 11.5,
      longitude: 104.9,
      accuracyMeters: 12,
      isMock: true,
    );
    const androidSettings = AndroidGeofenceSettings(
      initialTriggers: {GeofenceEvent.exit, GeofenceEvent.enter},
      expiration: Duration(minutes: 3),
      loiteringDelay: Duration(seconds: 4),
      notificationResponsiveness: Duration(seconds: 5),
    );
    const geofence = Geofence(
      id: 'office',
      location: location,
      radiusMeters: 150,
      triggers: {GeofenceEvent.exit, GeofenceEvent.enter},
      iosSettings: IosGeofenceSettings(initialTrigger: true),
      androidSettings: androidSettings,
    );
    final registration = GeofenceRegistration(
      geofence: geofence,
      callback: callback,
      callbackContext: 7,
    );

    expect(location.toJson(), {
      'latitude': 11.5,
      'longitude': 104.9,
      'accuracyMeters': 12.0,
      'isMock': true,
      'fixTimeMillis': null,
      'elapsedRealtimeNanos': null,
    });
    expect(androidSettings.toJson(), {
      'initialTriggers': ['enter', 'exit'],
      'expirationMillis': 180000,
      'loiteringDelayMillis': 4000,
      'notificationResponsivenessMillis': 5000,
    });
    expect(geofence.toJson()['triggers'], ['enter', 'exit']);
    expect(registration.callback, same(publicApiCallback));
    expect(registration.callbackContext, 7);
  });

  test('synchronization models serialize all final decision evidence', () {
    const inspection = NativeGeofenceSynchronizationInspection(
      matchesDesired: false,
      reasons: {
        NativeGeofenceSynchronizationReason.registrationDrift,
        NativeGeofenceSynchronizationReason.firstRun,
      },
      desiredIds: ['work', 'home'],
      currentIds: ['legacy'],
      missingIds: ['work', 'home'],
      unlistedIds: ['legacy'],
      driftedIds: [],
      metadataChangedIds: ['work'],
      inactiveIds: ['home'],
      desiredRegistrationFingerprint: 'desired',
      currentRegistrationFingerprint: null,
    );
    const report = NativeGeofenceSynchronizationReport(
      didSynchronize: true,
      reasons: {NativeGeofenceSynchronizationReason.registrationDrift},
      desiredCount: 2,
      previousCount: 1,
      registrationFingerprint: 'desired',
    );

    expect(inspection.desiredCount, 2);
    expect(inspection.currentCount, 1);
    expect(inspection.registrationFingerprintCurrent, isFalse);
    expect(inspection.toJson(), {
      'scope': 'authoritative',
      'matchesDesired': false,
      'reasons': ['firstRun', 'registrationDrift'],
      'desiredCount': 2,
      'currentCount': 1,
      'desiredIds': ['home', 'work'],
      'currentIds': ['legacy'],
      'missingIds': ['home', 'work'],
      'unlistedIds': ['legacy'],
      'driftedIds': <String>[],
      'metadataChangedIds': ['work'],
      'inactiveIds': ['home'],
      'desiredRegistrationFingerprint': 'desired',
      'currentRegistrationFingerprint': null,
      'registrationFingerprintCurrent': false,
    });
    expect(report.toJson(), {
      'scope': 'authoritative',
      'didSynchronize': true,
      'reasons': ['registrationDrift'],
      'desiredCount': 2,
      'previousCount': 1,
      'registrationFingerprint': 'desired',
    });
  });

  test('privacy-safe status JSON preserves nullable evidence and facts', () {
    final fact = NativeGeofenceLifecycleFact(
      occurredAt: DateTime.fromMillisecondsSinceEpoch(123),
      succeeded: true,
      outcome: 'registered',
      geofenceCount: 1,
    );
    final status = NativeGeofenceStatus(
      platform: NativeGeofencePlatform.android,
      persistedGeofenceCount: 2,
      preciseLocationPermissionGranted: true,
      backgroundRefreshStatus:
          NativeGeofenceBackgroundRefreshStatus.restricted,
      canEnumerateLivePlatformRegistrations: false,
      callbackRefreshState: NativeGeofenceCallbackRefreshState.current,
      registrationHealth: NativeGeofenceRegistrationHealth.healthy,
      lastRegistrationFact: fact,
    );

    expect(fact.toJson(), {
      'occurredAtMillis': 123,
      'succeeded': true,
      'outcome': 'registered',
      'geofenceCount': 1,
    });
    expect(status.toJson(), containsPair('platform', 'android'));
    expect(status.toJson(), containsPair('persistedGeofenceCount', 2));
    expect(
      status.toJson(),
      containsPair('preciseLocationPermissionGranted', true),
    );
    expect(
      status.toJson(),
      containsPair('backgroundRefreshStatus', 'restricted'),
    );
    expect(status.toJson(), isNot(contains('persistedGeofenceIds')));
    expect(
      status.toJson(),
      containsPair('lastRegistrationFact', fact.toJson()),
    );
  });

  test('callback parameter summary omits sensitive delivery details', () {
    final deadline = DateTime.fromMillisecondsSinceEpoch(1720000000123);
    final params = GeofenceCallbackParams(
      geofences: [
        ActiveGeofence(
          id: 'private-office-id',
          location: Location(latitude: 11.5, longitude: 104.9),
          radiusMeters: 150,
          triggers: {GeofenceEvent.enter},
          androidSettings: AndroidGeofenceSettings(initialTriggers: {}),
          expirationDeadline: deadline,
        ),
      ],
      event: GeofenceEvent.enter,
      location: Location(latitude: 11.6, longitude: 104.8),
      eventAt: null,
      eventId: 'private-delivery-id',
      callbackContextsByGeofenceId: {'private-office-id': 1001},
    );

    final summary = params.toString();

    expect(summary, contains('geofenceCount: 1'));
    expect(summary, contains('event: enter'));
    expect(summary, contains('hasLocation: true'));
    expect(summary, isNot(contains('private-office-id')));
    expect(summary, isNot(contains('private-delivery-id')));
    expect(summary, isNot(contains('11.')));
    expect(summary, isNot(contains('1001')));
    expect(
      params.geofences.single.toJson()['expirationDeadlineMillis'],
      deadline.millisecondsSinceEpoch,
    );
  });
}
