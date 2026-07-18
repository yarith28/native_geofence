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
      final geofence = _geofence(radiusMeters: radius);

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

  test('rejects Android settings outside platform duration bounds', () async {
    const maximumAndroidDurationMillis = 2147483647;
    const invalidSettings = <String, AndroidGeofenceSettings>{
      'expiration': AndroidGeofenceSettings(
        initialTriggers: {GeofenceEvent.enter},
        expiration: Duration.zero,
      ),
      'negative expiration': AndroidGeofenceSettings(
        initialTriggers: {GeofenceEvent.enter},
        expiration: Duration(milliseconds: -1),
      ),
      'sub-millisecond expiration': AndroidGeofenceSettings(
        initialTriggers: {GeofenceEvent.enter},
        expiration: Duration(microseconds: 1),
      ),
      'loitering delay': AndroidGeofenceSettings(
        initialTriggers: {GeofenceEvent.enter},
        loiteringDelay: Duration(milliseconds: -1),
      ),
      'oversized loitering delay': AndroidGeofenceSettings(
        initialTriggers: {GeofenceEvent.enter},
        loiteringDelay:
            Duration(milliseconds: maximumAndroidDurationMillis + 1),
      ),
      'notification responsiveness': AndroidGeofenceSettings(
        initialTriggers: {GeofenceEvent.enter},
        notificationResponsiveness: Duration(milliseconds: -1),
      ),
      'oversized notification responsiveness': AndroidGeofenceSettings(
        initialTriggers: {GeofenceEvent.enter},
        notificationResponsiveness:
            Duration(milliseconds: maximumAndroidDurationMillis + 1),
      ),
    };

    for (final entry in invalidSettings.entries) {
      await expectLater(
        NativeGeofenceManager.instance.createGeofence(
          _geofence(androidSettings: entry.value),
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
                contains(entry.key.contains('notification')
                    ? 'notification responsiveness'
                    : entry.key.contains('loitering')
                        ? 'loitering delay'
                        : 'expiration'),
              ),
        ),
        reason: entry.key,
      );
    }
  });

  test('rejects expiration whose Duration construction overflowed', () async {
    const maximumSignedInt64 = 9223372036854775807;

    await expectLater(
      NativeGeofenceManager.instance.createGeofence(
        _geofence(
          androidSettings: const AndroidGeofenceSettings(
            initialTriggers: {GeofenceEvent.enter},
            expiration: Duration(milliseconds: maximumSignedInt64),
          ),
        ),
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
              contains('expiration'),
            ),
      ),
    );
  });
}

Geofence _geofence({
  double radiusMeters = 100,
  AndroidGeofenceSettings androidSettings = const AndroidGeofenceSettings(
    initialTriggers: {GeofenceEvent.enter},
  ),
}) =>
    Geofence(
      id: 'validation-test',
      location: const Location(latitude: 11.56, longitude: 104.93),
      radiusMeters: radiusMeters,
      triggers: const {GeofenceEvent.enter},
      iosSettings: const IosGeofenceSettings(),
      androidSettings: androidSettings,
    );
