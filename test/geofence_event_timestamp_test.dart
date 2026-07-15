import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model_mapper.dart';

void main() {
  test('callback mapper preserves native event creation time', () {
    final wire = GeofenceCallbackParamsWire(
      geofences: [
        ActiveGeofenceWire(
          id: 'office',
          location: LocationWire(
            latitude: 11.5,
            longitude: 104.9,
            isMock: false,
          ),
          radiusMeters: 120,
          triggers: [GeofenceEvent.enter],
        ),
      ],
      event: GeofenceEvent.enter,
      eventAtMillis: 1720000000123,
      callbackHandle: 42,
      eventId: 'delivery-123',
    );

    final params = wire.fromWire();

    expect(params.eventAt?.millisecondsSinceEpoch, 1720000000123);
    expect(params.eventId, 'delivery-123');
    expect(params.toString(), contains('hasEventId: true'));
    expect(params.toString(), isNot(contains('delivery-123')));
  });

  test('callback mapper preserves an absent event creation time', () {
    final wire = GeofenceCallbackParamsWire(
      geofences: const [],
      event: GeofenceEvent.exit,
      callbackHandle: 42,
    );

    final params = wire.fromWire();

    expect(params.eventAt, isNull);
    expect(params.eventId, isNull);
  });

  test('public callback parameters remain source compatible', () {
    const params = GeofenceCallbackParams(
      geofences: [],
      event: GeofenceEvent.enter,
      location: null,
    );

    expect(params.eventAt, isNull);
    expect(params.eventId, isNull);
  });

  test('active geofence mapper preserves the absolute expiration deadline', () {
    const deadlineMillis = 1720000000123;
    final wire = ActiveGeofenceWire(
      id: 'office',
      location: LocationWire(
        latitude: 11.5,
        longitude: 104.9,
        isMock: false,
      ),
      radiusMeters: 120,
      triggers: [GeofenceEvent.enter],
      androidSettings: AndroidGeofenceSettingsWire(
        initialTriggers: [GeofenceEvent.enter],
        expirationDurationMillis: 300000,
        loiteringDelayMillis: 300000,
      ),
      expirationDeadlineMillis: deadlineMillis,
    );

    final active = wire.fromWire();

    expect(active.expirationDeadline?.millisecondsSinceEpoch, deadlineMillis);
    expect(active.androidSettings?.expiration, const Duration(minutes: 5));
    expect(active.toWire().expirationDeadlineMillis, deadlineMillis);
    expect(active.toJson()['expirationDeadlineMillis'], deadlineMillis);
  });
}
