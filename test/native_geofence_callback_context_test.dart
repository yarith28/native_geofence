import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model_mapper.dart';

@pragma('vm:entry-point')
Future<void> callbackWithContext(GeofenceCallbackParams params) async {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('manager forwards an optional callback context', () async {
    GeofenceWire? captured;
    final channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.native_geofence.NativeGeofenceApi.createGeofence',
      NativeGeofenceApi.pigeonChannelCodec,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(channel, (message) async {
      captured = (message! as List<Object?>).single as GeofenceWire;
      return <Object?>[null];
    });

    await NativeGeofenceManager.instance.createGeofence(
      _geofence('office'),
      callbackWithContext,
      callbackContext: 771,
    );

    expect(captured?.callbackContext, 771);
    expect(captured?.callbackHandle, isNot(0));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(channel, null);
  });

  test('callback mapper exposes immutable contexts keyed by geofence ID', () {
    final wire = GeofenceCallbackParamsWire(
      geofences: [_active('office'), _active('home')],
      event: GeofenceEvent.enter,
      location: null,
      callbackHandle: 1,
      callbackContextsByGeofenceId: {'office': 7, 'home': 8},
    );

    final params = wire.fromWire();

    expect(params.callbackContextsByGeofenceId, {'office': 7, 'home': 8});
    expect(
      () => params.callbackContextsByGeofenceId['office'] = 9,
      throwsUnsupportedError,
    );
  });

  test('registration pairs callback and optional opaque context', () {
    final registration = GeofenceRegistration(
      geofence: _geofence('office'),
      callback: callbackWithContext,
      callbackContext: 91,
    );

    expect(registration.geofence.id, 'office');
    expect(registration.callback, same(callbackWithContext));
    expect(registration.callbackContext, 91);
  });
}

Geofence _geofence(String id) => Geofence(
      id: id,
      location: const Location(latitude: 11.5, longitude: 104.9),
      radiusMeters: 100,
      triggers: const {GeofenceEvent.enter},
      iosSettings: const IosGeofenceSettings(),
      androidSettings: const AndroidGeofenceSettings(initialTriggers: {}),
    );

ActiveGeofenceWire _active(String id) => ActiveGeofenceWire(
      id: id,
      location: LocationWire(
        latitude: 11.5,
        longitude: 104.9,
        isMock: false,
      ),
      radiusMeters: 100,
      triggers: [GeofenceEvent.enter],
    );
