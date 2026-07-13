import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/native_geofence.dart';

void main() {
  test('background manager throws a typed exception before initialization', () {
    expect(
      () => NativeGeofenceBackgroundManager.instance,
      throwsA(
        isA<NativeGeofenceException>()
            .having(
              (exception) => exception.code,
              'code',
              NativeGeofenceErrorCode.pluginInternal,
            )
            .having(
              (exception) => exception.message,
              'message',
              contains(
                'NativeGeofenceBackgroundManager has not been initialized yet',
              ),
            ),
      ),
    );
  });
}
