import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model.dart';
import 'package:native_geofence/src/model/model_mapper.dart';

void main() {
  test('location metadata round-trips through the platform wire model', () {
    final location = Location(
      latitude: 11.5564,
      longitude: 104.9282,
      accuracyMeters: 18.75,
      isMock: true,
      fixTime: DateTime.fromMillisecondsSinceEpoch(1234),
      elapsedRealtimeNanos: 5678,
    );

    final wire = location.toWire();
    final decoded = wire.fromWire();

    expect(wire.accuracyMeters, 18.75);
    expect(wire.isMock, isTrue);
    expect(wire.fixTimeMillis, 1234);
    expect(wire.elapsedRealtimeNanos, 5678);
    expect(decoded.latitude, location.latitude);
    expect(decoded.longitude, location.longitude);
    expect(decoded.accuracyMeters, location.accuracyMeters);
    expect(decoded.isMock, isTrue);
    expect(decoded.fixTime, location.fixTime);
    expect(decoded.elapsedRealtimeNanos, 5678);
  });

  test('legacy location construction keeps neutral metadata defaults', () {
    const location = Location(latitude: 11.5564, longitude: 104.9282);
    final decoded = LocationWire(
      latitude: location.latitude,
      longitude: location.longitude,
      isMock: false,
    ).fromWire();

    expect(location.accuracyMeters, isNull);
    expect(location.isMock, isFalse);
    expect(decoded.accuracyMeters, isNull);
    expect(decoded.isMock, isFalse);
    expect(location.toString(), 'Location(11.5564, 104.9282)');
  });
}
