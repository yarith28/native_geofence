import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/native_geofence.dart';

void main() {
  test('native log file configuration has bounded-file defaults', () {
    const config = NativeGeofenceLogFileConfig();

    expect(config.enabled, isFalse);
    expect(config.maxBytes, 256 * 1024);
    expect(config.toMap()['enabled'], isFalse);
    expect(config.toMap()['maxBytes'], 256 * 1024);
  });

  test('native log file configuration transports caller values', () {
    const config = NativeGeofenceLogFileConfig(
      enabled: true,
      maxBytes: 512 * 1024,
    );

    expect(config.toMap()['enabled'], isTrue);
    expect(config.toMap()['maxBytes'], 512 * 1024);
  });
}
