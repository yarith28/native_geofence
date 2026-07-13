import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/model_mapper.dart';
import 'package:native_geofence/src/native_geofence_background_manager.dart';
import 'package:native_geofence/src/native_geofence_manager.dart';

void main() {
  setUp(resetNativeGeofenceBackgroundManagerForTesting);

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

  test('iOS runtime initialization is ordered and singleton-safe', () async {
    final events = <String>[];
    final api = _RecordingBackgroundApi(events);
    var apiCreations = 0;

    NativeGeofenceBackgroundApi ensureManager() {
      events.add('manager');
      return ensureNativeGeofenceBackgroundManagerInstance(
        createApi: () {
          apiCreations += 1;
          return api;
        },
      );
    }

    Future<void> initialize() => initializeNativeGeofenceRuntime(
          initializeDispatcher: () async => events.add('dispatcher'),
          initializeIosRuntime: true,
          initializeTriggerApi: () => events.add('trigger'),
          ensureBackgroundManager: ensureManager,
        );

    await initialize();
    await initialize();

    expect(
      events,
      <String>[
        'dispatcher',
        'trigger',
        'manager',
        'ready',
        'dispatcher',
        'trigger',
        'manager',
        'ready',
      ],
    );
    expect(apiCreations, 1);
    expect(
      ensureNativeGeofenceBackgroundManagerInstance(createApi: () =>
          throw StateError('the existing singleton must be reused')),
      same(api),
    );
    expect(NativeGeofenceBackgroundManager.instance, isNotNull);
  });

  test('dispatcher failure short-circuits iOS callback setup', () async {
    final events = <String>[];

    await expectLater(
      initializeNativeGeofenceRuntime(
        initializeDispatcher: () async {
          events.add('dispatcher');
          throw StateError('durable dispatcher write failed');
        },
        initializeIosRuntime: true,
        initializeTriggerApi: () => events.add('trigger'),
        ensureBackgroundManager: () {
          events.add('manager');
          return _RecordingBackgroundApi(events);
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(events, <String>['dispatcher']);
    expect(
      () => NativeGeofenceBackgroundManager.instance,
      throwsA(isA<NativeGeofenceException>()),
    );
  });

  test('main trigger readiness failure keeps typed error mapping', () async {
    final events = <String>[];
    final api = _RecordingBackgroundApi(
      events,
      triggerError: PlatformException(
        code: 'channel-error',
        message: 'main trigger channel unavailable',
      ),
    );

    await expectLater(
      initializeNativeGeofenceRuntime(
        initializeDispatcher: () async => events.add('dispatcher'),
        initializeIosRuntime: true,
        initializeTriggerApi: () => events.add('trigger'),
        ensureBackgroundManager: () {
          events.add('manager');
          return ensureNativeGeofenceBackgroundManagerInstance(
            createApi: () => api,
          );
        },
      ).catchError(NativeGeofenceExceptionMapper.catchError<void>),
      throwsA(
        isA<NativeGeofenceException>()
            .having(
              (error) => error.code,
              'code',
              NativeGeofenceErrorCode.channelError,
            )
            .having(
              (error) => error.message,
              'message',
              'main trigger channel unavailable',
            ),
      ),
    );
    expect(events, <String>['dispatcher', 'trigger', 'manager', 'ready']);
  });
}

class _RecordingBackgroundApi extends NativeGeofenceBackgroundApi {
  _RecordingBackgroundApi(this.events, {this.triggerError});

  final List<String> events;
  final Object? triggerError;

  @override
  Future<void> triggerApiInitialized() async {
    events.add('ready');
    final error = triggerError;
    if (error != null) throw error;
  }
}
