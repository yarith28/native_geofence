import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:native_geofence/src/api/native_geofence_trigger_impl.dart';
import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model_mapper.dart';

@pragma('vm:entry-point')
Future<void> missingDownstream(GeofenceCallbackParams params) async {
  throw const CallbackRegistrationUnavailable();
}
@pragma('vm:entry-point')
Future<void> applicationFailure(GeofenceCallbackParams params) async {
  throw StateError('ordinary application failure');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  NativeGeofenceTriggerImpl.ensureInitialized();
  Future<List<Object?>> deliver(GeofenceCallback callback) async {
    final handle = PluginUtilities.getCallbackHandle(callback);
    if (handle == null) throw StateError('Test callback must resolve');
    final wire = GeofenceCallbackParamsWire(geofences: [],
        event: GeofenceEvent.enter, location: null, callbackHandle: handle.toRawHandle());
    final result = Completer<ByteData?>();
    final codec = NativeGeofenceTriggerApi.pigeonChannelCodec;
    // Exercise the actual Dart bridge and Pigeon error envelope.
    // ignore: deprecated_member_use
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'dev.flutter.pigeon.native_geofence.NativeGeofenceTriggerApi.geofenceTriggered',
      codec.encodeMessage([wire]), result.complete);
    return (codec.decodeMessage(await result.future) as List<Object?>);
  }
  test('downstream lookup error carries the owned native recovery marker', () async {
    final response = await deliver(missingDownstream);
    expect(response[0], NativeGeofenceErrorCode.callbackNotFound.index.toString());
    expect(response[2], 'com.chunkytofustudios.native_geofence.callback_lookup_terminal.v1');
  });
  test('ordinary application error retains normal retry classification', () async {
    final response = await deliver(applicationFailure);
    expect(response[0], 'error');
    expect(response[2], isNot('com.chunkytofustudios.native_geofence.callback_lookup_terminal.v1'));
  });
  test('wire codec and mapper preserve opaque recovery ownership', () {
    final wire = GeofenceCallbackParamsWire(geofences: [],
        event: GeofenceEvent.exit, location: null, callbackHandle: 1,
        eventAtMillis: 1234, eventId: 'event-1', traceId: 'trace-1',
        iosRecoveryScopesByGeofenceId: {'office': 'owner-generation'});
    final codec = NativeGeofenceTriggerApi.pigeonChannelCodec;
    final restored = codec.decodeMessage(codec.encodeMessage(wire)) as GeofenceCallbackParamsWire;
    final params = restored.fromWire();
    expect(params.iosRecoveryScopesByGeofenceId, {'office': 'owner-generation'});
    expect(params.eventAt?.millisecondsSinceEpoch, 1234);
    expect(params.eventId, 'event-1');
    expect(() => params.iosRecoveryScopesByGeofenceId.clear(), throwsUnsupportedError);
  });
}
