import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/native_geofence.dart';

@pragma('vm:entry-point')
Future<void> geofenceCallback(GeofenceCallbackParams params) async {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rejects non-finite and non-positive geofence radii', () async {
    for (final radius in <double>[
      double.nan,
      double.infinity,
      double.negativeInfinity,
      0,
      -1,
    ]) {
      final geofence = Geofence(
        id: 'invalid-radius',
        location: const Location(latitude: 11.56, longitude: 104.93),
        radiusMeters: radius,
        triggers: const {GeofenceEvent.enter},
        iosSettings: const IosGeofenceSettings(),
        androidSettings: const AndroidGeofenceSettings(
          initialTriggers: {GeofenceEvent.enter},
        ),
      );

      await expectLater(
        NativeGeofenceManager.instance.createGeofence(
          geofence,
          geofenceCallback,
        ),
        throwsA(
          isA<NativeGeofenceException>()
              .having(
                (exception) => exception.code,
                'code',
                NativeGeofenceErrorCode.invalidArguments,
              )
              .having(
                (exception) => exception.message,
                'message',
                contains('finite and strictly positive'),
              ),
        ),
      );
    }
  });
}
