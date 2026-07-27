import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:native_geofence/src/generated/platform_bindings.g.dart';

@pragma('vm:entry-point')
Future<void> synchronizationCallback(GeofenceCallbackParams params) async {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const stateChannelName =
      'dev.flutter.pigeon.native_geofence.NativeGeofenceApi.getSynchronizationState';
  const synchronizeChannelName =
      'dev.flutter.pigeon.native_geofence.NativeGeofenceApi.synchronizeGeofences';
  final stateChannel = BasicMessageChannel<Object?>(
    stateChannelName,
    NativeGeofenceApi.pigeonChannelCodec,
  );
  final synchronizeChannel = BasicMessageChannel<Object?>(
    synchronizeChannelName,
    NativeGeofenceApi.pigeonChannelCodec,
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockDecodedMessageHandler<Object?>(stateChannel, null);
    messenger.setMockDecodedMessageHandler<Object?>(synchronizeChannel, null);
  });

  test('inspection is read-only and normalizes iOS-only comparison rules',
      () async {
    final callbackHandle =
        PluginUtilities.getCallbackHandle(synchronizationCallback)!
            .toRawHandle();
    String? committedFingerprint;
    var synchronizationCalls = 0;
    messenger.setMockDecodedMessageHandler<Object?>(stateChannel, (_) async {
      return <Object?>[
        _state(
          platform: NativeGeofencePlatform.ios,
          registrations: [
            _wire(
              radius: 100.005,
              latitude: 11.5000000001,
              callbackHandle: callbackHandle,
              androidExpirationMillis: 99,
            ),
          ],
          registrationFingerprint: committedFingerprint,
          desiredRegistrationFingerprint: 'ios-desired-v1',
          iosMaximumDistance: 100,
        ),
      ];
    });
    messenger.setMockDecodedMessageHandler<Object?>(synchronizeChannel,
        (_) async {
      synchronizationCalls += 1;
      return <Object?>[_result()];
    });
    final desired = [
      GeofenceRegistration(
        geofence: _geofence(
          radius: 1000,
          androidExpiration: const Duration(days: 2),
        ),
        callback: synchronizationCallback,
      ),
    ];

    final first = await NativeGeofenceManager.instance.inspectSynchronization(
      desired,
      removeUnlisted: true,
    );
    committedFingerprint = first.desiredRegistrationFingerprint;
    final current =
        await NativeGeofenceManager.instance.inspectSynchronization(
      desired,
      removeUnlisted: true,
    );

    expect(
        first.reasons, contains(NativeGeofenceSynchronizationReason.firstRun));
    expect(current.matchesDesired, isTrue);
    expect(
      current.scope,
      NativeGeofenceSynchronizationScope.authoritative,
    );
    expect(current.registrationFingerprintCurrent, isTrue);
    expect(current.driftedIds, isEmpty);
    expect(current.metadataChangedIds, isEmpty);
    expect(synchronizationCalls, 0);
  });

  test('inspection defaults to partial scope and preserves unlisted IDs',
      () async {
    final callbackHandle =
        PluginUtilities.getCallbackHandle(synchronizationCallback)!
            .toRawHandle();
    messenger.setMockDecodedMessageHandler<Object?>(stateChannel, (_) async {
      return <Object?>[
        _state(
          platform: NativeGeofencePlatform.ios,
          registrations: [
            _wire(radius: 100, callbackHandle: callbackHandle),
          ],
          pluginOwnedIds: const ['office', 'outside-scope'],
          registrationFingerprint: 'authoritative-other-state',
          desiredRegistrationFingerprint: 'partial-office-state',
        ),
      ];
    });
    final desired = [
      GeofenceRegistration(
        geofence: _geofence(),
        callback: synchronizationCallback,
      ),
    ];

    final inspection =
        await NativeGeofenceManager.instance.inspectSynchronization(desired);

    expect(inspection.scope, NativeGeofenceSynchronizationScope.partial);
    expect(inspection.matchesDesired, isTrue);
    expect(inspection.reasons, isEmpty);
    expect(inspection.unlistedIds, isEmpty);
    expect(inspection.registrationFingerprintCurrent, isNull);
    expect(
      inspection.currentRegistrationFingerprint,
      'authoritative-other-state',
    );
  });

  test('overlapping synchronization calls are FIFO serialized', () async {
    final events = <String>[];
    var synchronizationCall = 0;
    final firstSynchronization = Completer<void>();
    messenger.setMockDecodedMessageHandler<Object?>(synchronizeChannel,
        (_) async {
      synchronizationCall += 1;
      events.add('synchronize$synchronizationCall');
      if (synchronizationCall == 1) {
        await firstSynchronization.future;
      }
      return <Object?>[
        _result(registrationFingerprint: 'fingerprint$synchronizationCall'),
      ];
    });

    final first = NativeGeofenceManager.instance.ensureSynchronized([
      GeofenceRegistration(
        geofence: _geofence(id: 'first'),
        callback: synchronizationCallback,
      ),
    ]);
    final second = NativeGeofenceManager.instance.ensureSynchronized([
      GeofenceRegistration(
        geofence: _geofence(id: 'second'),
        callback: synchronizationCallback,
      ),
    ]);
    await _waitFor(() => events.length == 1);
    expect(events, ['synchronize1']);

    firstSynchronization.complete();
    await Future.wait([first, second]);
    expect(events, ['synchronize1', 'synchronize2']);
  });

  test('a failed synchronization does not poison the serialized tail',
      () async {
    var synchronizationCall = 0;
    messenger.setMockDecodedMessageHandler<Object?>(synchronizeChannel,
        (_) async {
      synchronizationCall += 1;
      if (synchronizationCall == 1) {
        return <Object?>['1', 'transaction failed', null];
      }
      return <Object?>[_result()];
    });
    final desired = [
      GeofenceRegistration(
        geofence: _geofence(),
        callback: synchronizationCallback,
      ),
    ];

    await expectLater(
      NativeGeofenceManager.instance.ensureSynchronized(desired),
      throwsA(isA<NativeGeofenceException>()),
    );
    final recovered =
        await NativeGeofenceManager.instance.ensureSynchronized(desired);

    expect(recovered.didSynchronize, isTrue);
    expect(synchronizationCall, 2);
  });

  test('ensure uses the native authoritative decision without pre-inspection',
      () async {
    var stateCalls = 0;
    messenger.setMockDecodedMessageHandler<Object?>(stateChannel, (_) async {
      stateCalls += 1;
      return <Object?>[
        _state(platform: NativeGeofencePlatform.android),
      ];
    });
    messenger.setMockDecodedMessageHandler<Object?>(synchronizeChannel,
        (_) async {
      return <Object?>[
        _result(
          reasons: const [
            NativeGeofenceSynchronizationReasonWire.callbackFingerprintChanged,
            NativeGeofenceSynchronizationReasonWire.registrationDrift,
          ],
          desiredCount: 2,
          previousCount: 3,
          registrationFingerprint: 'native-authoritative',
        ),
      ];
    });

    final report = await NativeGeofenceManager.instance.ensureSynchronized(
      [
        GeofenceRegistration(
          geofence: _geofence(),
          callback: synchronizationCallback,
        ),
      ],
      removeUnlisted: true,
    );

    expect(stateCalls, 0);
    expect(report.didSynchronize, isTrue);
    expect(report.reasons, {
      NativeGeofenceSynchronizationReason.callbackFingerprintChanged,
      NativeGeofenceSynchronizationReason.registrationDrift,
    });
    expect(report.desiredCount, 2);
    expect(report.previousCount, 3);
    expect(report.registrationFingerprint, 'native-authoritative');
  });

  test('ensure preserves the native authoritative no-op path', () async {
    var stateCalls = 0;
    messenger.setMockDecodedMessageHandler<Object?>(stateChannel, (_) async {
      stateCalls += 1;
      return <Object?>[
        _state(platform: NativeGeofencePlatform.android),
      ];
    });
    messenger.setMockDecodedMessageHandler<Object?>(synchronizeChannel,
        (_) async {
      return <Object?>[
        _result(
          didSynchronize: false,
          reasons: const [],
          desiredCount: 1,
          previousCount: 1,
          registrationFingerprint: 'already-current',
        ),
      ];
    });

    final report = await NativeGeofenceManager.instance.ensureSynchronized(
      [
        GeofenceRegistration(
          geofence: _geofence(),
          callback: synchronizationCallback,
        ),
      ],
      removeUnlisted: true,
    );

    expect(stateCalls, 0);
    expect(report.didSynchronize, isFalse);
    expect(report.reasons, isEmpty);
    expect(report.desiredCount, 1);
    expect(report.previousCount, 1);
    expect(report.registrationFingerprint, 'already-current');
  });

  test('ensure defaults to partial scope in the native request', () async {
    bool? receivedRemoveUnlisted;
    messenger.setMockDecodedMessageHandler<Object?>(synchronizeChannel,
        (message) async {
      receivedRemoveUnlisted = (message! as List<Object?>)[1]! as bool;
      return <Object?>[
        _result(
          didSynchronize: false,
          reasons: const [],
          registrationFingerprint: 'partial-office-state',
        ),
      ];
    });

    final report = await NativeGeofenceManager.instance.ensureSynchronized(
      [
        GeofenceRegistration(
          geofence: _geofence(),
          callback: synchronizationCallback,
        ),
      ],
    );

    expect(receivedRemoveUnlisted, isFalse);
    expect(report.scope, NativeGeofenceSynchronizationScope.partial);
    expect(report.registrationFingerprint, 'partial-office-state');
  });

  test('incomplete plugin-owned state remains drift after fingerprint match',
      () async {
    String? committedFingerprint;
    messenger.setMockDecodedMessageHandler<Object?>(stateChannel, (_) async {
      return <Object?>[
        _state(
          platform: NativeGeofencePlatform.android,
          pluginOwnedIds: const ['office'],
          inactiveRegistrationIds: const ['office'],
          registrationFingerprint: committedFingerprint,
        ),
      ];
    });
    final desired = [
      GeofenceRegistration(
        geofence: _geofence(),
        callback: synchronizationCallback,
      ),
    ];

    final first = await NativeGeofenceManager.instance.inspectSynchronization(
      desired,
      removeUnlisted: true,
    );
    committedFingerprint = first.desiredRegistrationFingerprint;
    final current =
        await NativeGeofenceManager.instance.inspectSynchronization(
      desired,
      removeUnlisted: true,
    );

    expect(current.missingIds, isEmpty);
    expect(current.inactiveIds, ['office']);
    expect(current.matchesDesired, isFalse);
    expect(
      current.reasons,
      contains(NativeGeofenceSynchronizationReason.registrationDrift),
    );
  });
}

NativeGeofenceSynchronizationStateWire _state({
  required NativeGeofencePlatform platform,
  List<GeofenceWire> registrations = const [],
  List<String>? pluginOwnedIds,
  List<String> inactiveRegistrationIds = const [],
  String? registrationFingerprint,
  String desiredRegistrationFingerprint = 'desired-v1',
  double? iosMaximumDistance,
}) =>
    NativeGeofenceSynchronizationStateWire(
      platform: platform,
      pluginOwnedIds:
          pluginOwnedIds ?? registrations.map((value) => value.id).toList(),
      registrations: registrations,
      inactiveRegistrationIds: inactiveRegistrationIds,
      registrationFingerprint: registrationFingerprint,
      desiredRegistrationFingerprint: desiredRegistrationFingerprint,
      callbackFingerprintCurrent: true,
      iosMaximumRegionMonitoringDistance: iosMaximumDistance,
    );

NativeGeofenceSynchronizationResultWire _result({
  bool didSynchronize = true,
  List<NativeGeofenceSynchronizationReasonWire> reasons = const [
    NativeGeofenceSynchronizationReasonWire.firstRun,
    NativeGeofenceSynchronizationReasonWire.registrationDrift,
  ],
  int desiredCount = 1,
  int previousCount = 0,
  String registrationFingerprint = 'desired-v1',
}) =>
    NativeGeofenceSynchronizationResultWire(
      didSynchronize: didSynchronize,
      reasons: reasons,
      desiredCount: desiredCount,
      previousCount: previousCount,
      registrationFingerprint: registrationFingerprint,
    );

GeofenceWire _wire({
  String id = 'office',
  required double radius,
  required int callbackHandle,
  int? androidExpirationMillis,
  double latitude = 11.5,
}) =>
    GeofenceWire(
      id: id,
      location: LocationWire(
        latitude: latitude,
        longitude: 104.9,
        isMock: false,
      ),
      radiusMeters: radius,
      triggers: [GeofenceEvent.enter],
      iosSettings: IosGeofenceSettingsWire(initialTrigger: false),
      androidSettings: AndroidGeofenceSettingsWire(
        initialTriggers: const [],
        expirationDurationMillis: androidExpirationMillis,
        loiteringDelayMillis: 777,
        notificationResponsivenessMillis: 888,
      ),
      callbackHandle: callbackHandle,
    );

Geofence _geofence({
  String id = 'office',
  double radius = 100,
  Duration? androidExpiration,
}) =>
    Geofence(
      id: id,
      location: const Location(latitude: 11.5, longitude: 104.9),
      radiusMeters: radius,
      triggers: const {GeofenceEvent.enter},
      iosSettings: const IosGeofenceSettings(initialTrigger: true),
      androidSettings: AndroidGeofenceSettings(
        initialTriggers: const {GeofenceEvent.enter},
        expiration: androidExpiration,
        loiteringDelay: const Duration(seconds: 12),
        notificationResponsiveness: const Duration(seconds: 34),
      ),
    );

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100 && !predicate(); attempt += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(predicate(), isTrue);
}
