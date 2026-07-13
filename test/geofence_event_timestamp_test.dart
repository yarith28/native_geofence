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
    );

    final params = wire.fromWire();

    expect(params.eventAt?.millisecondsSinceEpoch, 1720000000123);
  });

  test('callback mapper preserves an absent event creation time', () {
    final wire = GeofenceCallbackParamsWire(
      geofences: const [],
      event: GeofenceEvent.exit,
      callbackHandle: 42,
    );

    expect(wire.fromWire().eventAt, isNull);
  });

  test('public callback parameters remain source compatible', () {
    const params = GeofenceCallbackParams(
      geofences: [],
      event: GeofenceEvent.enter,
      location: null,
    );

    expect(params.eventAt, isNull);
  });
}
