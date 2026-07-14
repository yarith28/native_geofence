import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:native_geofence/src/api/native_geofence_trigger_impl.dart';
import 'package:native_geofence/src/callback_dispatcher.dart';
import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence/src/model/geofence_registration.dart';
import 'package:native_geofence/src/model/log_file_config.dart';
import 'package:native_geofence/src/model/model.dart';
import 'package:native_geofence/src/model/model_mapper.dart';
import 'package:native_geofence/src/model/native_geofence_exception.dart';
import 'package:native_geofence/src/model/native_geofence_status.dart';
import 'package:native_geofence/src/native_geofence_background_manager.dart';
import 'package:native_geofence/src/platform/module.dart';
import 'package:native_geofence/src/typedefs.dart';

class _PreparedRegistration {
  final GeofenceWire wire;

  const _PreparedRegistration(this.wire);
}

class _SynchronizationDecision {
  final NativeGeofenceSynchronizationScope scope;
  final Set<NativeGeofenceSynchronizationReason> reasons;
  final List<String> desiredIds;
  final List<String> currentIds;
  final List<String> missingIds;
  final List<String> unlistedIds;
  final List<String> driftedIds;
  final List<String> metadataChangedIds;
  final List<String> inactiveIds;
  final String desiredFingerprint;
  final String? currentFingerprint;

  const _SynchronizationDecision({
    required this.scope,
    required this.reasons,
    required this.desiredIds,
    required this.currentIds,
    required this.missingIds,
    required this.unlistedIds,
    required this.driftedIds,
    required this.metadataChangedIds,
    required this.inactiveIds,
    required this.desiredFingerprint,
    required this.currentFingerprint,
  });

  bool get matchesDesired => reasons.isEmpty;

  NativeGeofenceSynchronizationInspection toInspection() =>
      NativeGeofenceSynchronizationInspection(
        scope: scope,
        matchesDesired: matchesDesired,
        reasons: Set.unmodifiable(reasons),
        desiredIds: List.unmodifiable(desiredIds),
        currentIds: List.unmodifiable(currentIds),
        missingIds: List.unmodifiable(missingIds),
        unlistedIds: List.unmodifiable(unlistedIds),
        driftedIds: List.unmodifiable(driftedIds),
        metadataChangedIds: List.unmodifiable(metadataChangedIds),
        inactiveIds: List.unmodifiable(inactiveIds),
        desiredRegistrationFingerprint: desiredFingerprint,
        currentRegistrationFingerprint: currentFingerprint,
      );
}

_SynchronizationDecision _decideSynchronization(
  List<_PreparedRegistration> desired,
  NativeGeofenceSynchronizationStateWire state, {
  required bool removeUnlisted,
}) {
  final desiredById = {for (final value in desired) value.wire.id: value.wire};
  final currentById = {
    for (final value in state.registrations) value.id: value,
  };
  final desiredIds = desiredById.keys.toList()..sort();
  final currentIds = state.pluginOwnedIds.toSet().toList()..sort();
  final missingIds = desiredIds
      .where((id) => !currentIds.contains(id))
      .toList(growable: false);
  final unlistedIds = removeUnlisted
      ? currentIds.where((id) => !desiredById.containsKey(id)).toList()
      : <String>[];
  final driftedIds = <String>[];
  final metadataChangedIds = <String>[];
  for (final id in desiredIds) {
    final current = currentById[id];
    final wanted = desiredById[id]!;
    if (current == null) continue;
    if (!_platformRegistrationMatches(current, wanted, state)) {
      driftedIds.add(id);
    }
    if (current.callbackHandle != wanted.callbackHandle ||
        current.callbackContext != wanted.callbackContext) {
      metadataChangedIds.add(id);
    }
  }
  final inactiveIds = state.inactiveRegistrationIds
      .where(desiredById.containsKey)
      .toSet()
      .toList()
    ..sort();
  final desiredFingerprint = state.desiredRegistrationFingerprint;
  final scope = removeUnlisted
      ? NativeGeofenceSynchronizationScope.authoritative
      : NativeGeofenceSynchronizationScope.partial;
  final reasons = <NativeGeofenceSynchronizationReason>{};
  if (removeUnlisted && state.registrationFingerprint == null) {
    reasons.add(NativeGeofenceSynchronizationReason.firstRun);
  }
  if (!state.callbackFingerprintCurrent || metadataChangedIds.isNotEmpty) {
    reasons.add(
      NativeGeofenceSynchronizationReason.callbackFingerprintChanged,
    );
  }
  if ((removeUnlisted && state.registrationFingerprint != desiredFingerprint) ||
      missingIds.isNotEmpty ||
      unlistedIds.isNotEmpty ||
      driftedIds.isNotEmpty ||
      inactiveIds.isNotEmpty) {
    reasons.add(NativeGeofenceSynchronizationReason.registrationDrift);
  }
  return _SynchronizationDecision(
    scope: scope,
    reasons: reasons,
    desiredIds: desiredIds,
    currentIds: currentIds,
    missingIds: missingIds,
    unlistedIds: unlistedIds..sort(),
    driftedIds: driftedIds..sort(),
    metadataChangedIds: metadataChangedIds..sort(),
    inactiveIds: inactiveIds,
    desiredFingerprint: desiredFingerprint,
    currentFingerprint: state.registrationFingerprint,
  );
}

bool _platformRegistrationMatches(
  GeofenceWire current,
  GeofenceWire desired,
  NativeGeofenceSynchronizationStateWire state,
) {
  final desiredRadius = state.platform == NativeGeofencePlatform.ios &&
          state.iosMaximumRegionMonitoringDistance != null &&
          state.iosMaximumRegionMonitoringDistance! > 0
      ? desired.radiusMeters
          .clamp(0, state.iosMaximumRegionMonitoringDistance!)
          .toDouble()
      : desired.radiusMeters;
  final coordinatesMatch = state.platform == NativeGeofencePlatform.ios
      ? (current.location.latitude - desired.location.latitude).abs() <=
              0.0000001 &&
          (current.location.longitude - desired.location.longitude).abs() <=
              0.0000001
      : current.location.latitude == desired.location.latitude &&
          current.location.longitude == desired.location.longitude;
  final radiusMatches = state.platform == NativeGeofencePlatform.ios
      ? (current.radiusMeters - desiredRadius).abs() <= 0.01
      : current.radiusMeters == desiredRadius;
  if (!coordinatesMatch ||
      !radiusMatches ||
      !_wireEventsMatch(
        _eventsForPlatform(current.triggers, state.platform),
        _eventsForPlatform(desired.triggers, state.platform),
      )) {
    return false;
  }
  if (state.platform == NativeGeofencePlatform.ios) return true;
  return current.androidSettings.expirationDurationMillis ==
          desired.androidSettings.expirationDurationMillis &&
      current.androidSettings.loiteringDelayMillis ==
          desired.androidSettings.loiteringDelayMillis &&
      current.androidSettings.notificationResponsivenessMillis ==
          desired.androidSettings.notificationResponsivenessMillis;
}

bool _wireEventsMatch(List<GeofenceEvent> left, List<GeofenceEvent> right) {
  final leftSet = left.toSet();
  final rightSet = right.toSet();
  return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
}

List<GeofenceEvent> _eventsForPlatform(
  List<GeofenceEvent> events,
  NativeGeofencePlatform platform,
) =>
    platform == NativeGeofencePlatform.ios
        ? events.where((event) => event != GeofenceEvent.dwell).toList()
        : events;

NativeGeofenceSynchronizationReason _synchronizationReasonFromWire(
  NativeGeofenceSynchronizationReasonWire reason,
) =>
    switch (reason) {
      NativeGeofenceSynchronizationReasonWire.firstRun =>
        NativeGeofenceSynchronizationReason.firstRun,
      NativeGeofenceSynchronizationReasonWire.callbackFingerprintChanged =>
        NativeGeofenceSynchronizationReason.callbackFingerprintChanged,
      NativeGeofenceSynchronizationReasonWire.registrationDrift =>
        NativeGeofenceSynchronizationReason.registrationDrift,
    };

class NativeGeofenceManager {
  /// Cached instance of [NativeGeofenceManager]
  static NativeGeofenceManager? _instance;

  /// The singleton instance of [NativeGeofenceManager].
  ///
  /// Throws [NativeGeofenceException].
  static NativeGeofenceManager get instance {
    try {
      _instance ??= NativeGeofenceManager._();
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
    return _instance!;
  }

  final NativeGeofenceApi _api;
  Future<void> _synchronizationTail = Future<void>.value();

  static const MethodChannel _logFileChannel =
      MethodChannel('native_geofence/log_file');

  NativeGeofenceManager._() : _api = NativeGeofenceApi();

  /// Initialize the plugin.
  ///
  /// Must be called before any other method.
  ///
  /// Android initialization may repair plugin-owned registrations from durable
  /// native storage. Recovery preserves stored callback handles and contexts;
  /// it cannot resolve live Dart functions from the current application build.
  /// Use [ensureSynchronized] with app-owned [GeofenceRegistration] values to
  /// refresh callback metadata after an update, obfuscated rebuild, or callback
  /// move/rename.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> initialize() async {
    final CallbackHandle? callback;
    try {
      callback = PluginUtilities.getCallbackHandle(callbackDispatcher);
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
    if (callback == null) {
      throw NativeGeofenceException.internal(
          message: 'Callback dispatcher is invalid.');
    }
    final callbackDispatcherHandle = callback.toRawHandle();
    await initializeNativeGeofenceRuntime(
      initializeDispatcher: () => _api.initialize(
        callbackDispatcherHandle: callbackDispatcherHandle,
      ),
      initializeIosRuntime: isIos,
      initializeTriggerApi: NativeGeofenceTriggerImpl.ensureInitialized,
      ensureBackgroundManager: ensureNativeGeofenceBackgroundManagerInstance,
    ).catchError(NativeGeofenceExceptionMapper.catchError<void>);
  }

  /// Register for geofence events for a [Geofence].
  ///
  /// [geofence] is the geofence region to register with the system.
  /// [callback] is the method to be called when a geofence event associated
  /// with [geofence] occurs. It must be a top-level or static function annotated
  /// with `@pragma('vm:entry-point')`; closures and instance methods cannot be
  /// resolved from a background isolate and are rejected.
  ///
  /// Platform limits apply. iOS permits at most 20 monitored regions per app,
  /// including regions not owned by this plugin, and Android permits at most
  /// 100 geofences per app.
  ///
  /// Android schedules expedited WorkManager delivery but Doze, App Standby,
  /// system load, OEM restrictions, exhausted expedited quota, and retries can
  /// still delay callback startup. The worker uses 20-second startup,
  /// 15-second API-readiness, and 60-second callback watchdogs. iOS callback
  /// startup/execution is bounded to 30 seconds. Persist important state first
  /// and move long-running work to an app-owned durable system.
  ///
  /// [callbackContext] is an optional opaque signed 64-bit value persisted with
  /// this registration and returned by geofence ID in
  /// [GeofenceCallbackParams.callbackContextsByGeofenceId]. The plugin never
  /// interprets it. Registrations without a context remain valid and are absent
  /// from that map.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> createGeofence(
    Geofence geofence,
    GeofenceCallback callback, {
    int? callbackContext,
  }) async {
    final prepared = _prepareRegistration(
      GeofenceRegistration(
        geofence: geofence,
        callback: callback,
        callbackContext: callbackContext,
      ),
    );
    return _api
        .createGeofence(geofence: prepared.wire)
        .catchError(NativeGeofenceExceptionMapper.catchError<void>);
  }

  _PreparedRegistration _prepareRegistration(
    GeofenceRegistration registration,
  ) {
    final geofence = registration.geofence;
    if (geofence.id.isEmpty) {
      throw NativeGeofenceException.invalidArgument(
          message: 'Geofence ID cannot be empty.');
    }
    if (geofence.triggers.isEmpty) {
      throw NativeGeofenceException.invalidArgument(
          message: 'Geofence triggers cannot be empty.');
    }
    if (!geofence.location.isValid) {
      throw NativeGeofenceException.invalidArgument(
          message: 'Geofence location is invalid.');
    }
    if (!geofence.radiusMeters.isFinite || geofence.radiusMeters <= 0) {
      throw NativeGeofenceException.invalidArgument(
          message: 'Geofence radius must be finite and strictly positive.');
    }
    if (isIos &&
        geofence.triggers.length == 1 &&
        geofence.triggers.first == GeofenceEvent.dwell) {
      throw NativeGeofenceException.invalidArgument(
          message: 'iOS does not support "GeofenceEvent.dwell".');
    }
    final CallbackHandle? callbackHandle;
    try {
      callbackHandle = PluginUtilities.getCallbackHandle(registration.callback);
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
    if (callbackHandle == null) {
      throw NativeGeofenceException.invalidArgument(
          message: 'Callback for geofence "${geofence.id}" is invalid.');
    }
    return _PreparedRegistration(
      geofence.toWire(
        callbackHandle.toRawHandle(),
        callbackContext: registration.callbackContext,
      ),
    );
  }

  List<_PreparedRegistration> _prepareRegistrations(
    List<GeofenceRegistration> registrations,
  ) {
    final ids = registrations.map((value) => value.geofence.id).toSet();
    if (ids.length != registrations.length) {
      throw NativeGeofenceException.invalidArgument(
        message: 'Registrations contain duplicate geofence IDs.',
      );
    }
    return registrations.map(_prepareRegistration).toList(growable: false);
  }

  /// Compares app-owned desired registrations with complete plugin-owned
  /// native state without mutating registrations or fingerprints.
  ///
  /// This performs the same validation, callback resolution, platform
  /// normalization, and reason definitions as [ensureSynchronized], but is a
  /// point-in-time observation and does not reserve state.
  /// [NativeGeofenceSynchronizationInspection.matchesDesired] predicts a native
  /// no-op only while state remains unchanged; [ensureSynchronized] revalidates
  /// under the shared native mutation authority.
  ///
  /// With the default [removeUnlisted] value, IDs omitted from [registrations]
  /// are reported as drift. Set it to false when the desired list intentionally
  /// manages only a subset of plugin-owned registrations. Partial inspection
  /// compares the supplied IDs directly and does not compare its subset
  /// fingerprint with the last authoritative fingerprint.
  ///
  /// Throws [NativeGeofenceException].
  Future<NativeGeofenceSynchronizationInspection> inspectSynchronization(
    List<GeofenceRegistration> registrations, {
    bool removeUnlisted = true,
  }) {
    final desired = _prepareRegistrations(registrations);
    return _serializeSynchronization(() async {
      final decision = await _inspectPreparedSynchronization(
        desired,
        removeUnlisted: removeUnlisted,
      );
      return decision.toInspection();
    });
  }

  /// Conditionally reconciles plugin-owned native registrations with
  /// [registrations].
  ///
  /// The application list supplies live callback functions and optional
  /// contexts. With the default [removeUnlisted] value it is authoritative:
  /// plugin-owned IDs omitted from the list are removed. Set it to false to
  /// preserve registrations outside the supplied subset.
  ///
  /// Unchanged registrations stay armed. Callback/context-only changes refresh
  /// durable metadata without an unnecessary platform stop/start.
  ///
  /// Each invocation is one native-owned inspect-and-mutate transaction,
  /// serialized with create, remove, and other synchronization work across
  /// foreground and headless paths. Native code re-reads state at that boundary
  /// and owns the no-op decision and report, so two isolates cannot act on the
  /// same stale inspection.
  ///
  /// Native code owns the transaction snapshot. A partial failure restores the
  /// previous registrations, expiration deadlines, callback metadata, iOS
  /// duplicate-suppression baselines, and synchronization fingerprint. Any
  /// rollback failure is reported explicitly in [NativeGeofenceException].
  /// Rollback and automatic recovery suppress initial triggers. Synchronization
  /// never re-arms unchanged registrations; metadata-only refreshes also avoid
  /// initial triggers. A new or platform-changed Android registration still
  /// applies its configured [AndroidGeofenceSettings.initialTriggers], while
  /// iOS synchronization does not request an initial-state callback.
  ///
  /// This is the live callback-handle refresh path after app updates,
  /// obfuscated builds, or callback moves/renames. [reCreateAfterReboot] and
  /// automatic recovery use the previously stored handles and contexts.
  ///
  /// Throws [NativeGeofenceException].
  Future<NativeGeofenceSynchronizationReport> ensureSynchronized(
    List<GeofenceRegistration> registrations, {
    bool removeUnlisted = true,
  }) {
    final desired = _prepareRegistrations(registrations);
    return _serializeSynchronization(() async {
      final result = await _api
          .synchronizeGeofences(
            desiredRegistrations:
                desired.map((value) => value.wire).toList(growable: false),
            removeUnlisted: removeUnlisted,
          )
          .catchError(
            NativeGeofenceExceptionMapper
                .catchError<NativeGeofenceSynchronizationResultWire>,
          );
      return NativeGeofenceSynchronizationReport(
        scope: removeUnlisted
            ? NativeGeofenceSynchronizationScope.authoritative
            : NativeGeofenceSynchronizationScope.partial,
        didSynchronize: result.didSynchronize,
        reasons: Set<NativeGeofenceSynchronizationReason>.unmodifiable(
          result.reasons.map(_synchronizationReasonFromWire),
        ),
        desiredCount: result.desiredCount,
        previousCount: result.previousCount,
        registrationFingerprint: result.registrationFingerprint,
      );
    });
  }

  Future<_SynchronizationDecision> _inspectPreparedSynchronization(
    List<_PreparedRegistration> desired, {
    required bool removeUnlisted,
  }) async {
    final state = await _api
        .getSynchronizationState(
          desiredRegistrations:
              desired.map((value) => value.wire).toList(growable: false),
        )
        .catchError(
          NativeGeofenceExceptionMapper
              .catchError<NativeGeofenceSynchronizationStateWire>,
        );
    return _decideSynchronization(
      desired,
      state,
      removeUnlisted: removeUnlisted,
    );
  }

  Future<T> _serializeSynchronization<T>(Future<T> Function() operation) {
    final previous = _synchronizationTail;
    final gate = Completer<void>();
    _synchronizationTail = gate.future;
    return () async {
      try {
        try {
          await previous;
        } catch (_) {
          // A failed earlier caller must not poison later queued inspections.
        }
        return await operation();
      } finally {
        gate.complete();
      }
    }();
  }

  /// Re-register geofences from durable native storage.
  ///
  /// This is an explicit Android recovery pass for environments where automatic
  /// reboot/location recovery may be delayed by OEM restrictions. It preserves
  /// finite expiration deadlines and suppresses recovery initial triggers.
  /// Because it uses stored callback handles and contexts, it does not refresh
  /// metadata for the current Dart build; use [ensureSynchronized] for that.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> reCreateAfterReboot() async => _api
      .reCreateAfterReboot()
      .catchError(NativeGeofenceExceptionMapper.catchError<void>);

  /// Returns a read-only, privacy-safe snapshot of native plugin evidence.
  ///
  /// This does not mutate registrations and does not imply Android can
  /// enumerate the live Play Services geofence set. Lifecycle facts are the
  /// latest observation for each stage, not an audit trail, proof that a
  /// geofence is armed, or a guarantee of future delivery.
  Future<NativeGeofenceStatus> getStatus() async =>
      _api.getStatus().then((value) => value.fromWire()).catchError(
          NativeGeofenceExceptionMapper.catchError<NativeGeofenceStatus>);

  /// Get all registered [Geofence] IDs.
  ///
  /// If there are no geofences registered it returns an empty list.
  ///
  /// Throws [NativeGeofenceException].
  Future<List<String>> getRegisteredGeofenceIds() async => _api
      .getGeofenceIds()
      .catchError(NativeGeofenceExceptionMapper.catchError<List<String>>);

  /// Get all [Geofence] regions and their properties.
  ///
  /// If there are no geofences registered it returns an empty list.
  ///
  /// Throws [NativeGeofenceException].
  Future<List<ActiveGeofence>> getRegisteredGeofences() async => _api
      .getGeofences()
      .then((value) => value.map((e) => e.fromWire()).toList())
      .catchError(
          NativeGeofenceExceptionMapper.catchError<List<ActiveGeofence>>);

  /// Configure the app-private Android log file.
  ///
  /// File logging is disabled by default. When enabled, native_geofence writes
  /// a bounded text log that can be fetched with [readLogFile]. This is a no-op
  /// on iOS and web.
  Future<void> configureLogFile({
    NativeGeofenceLogFileConfig config = const NativeGeofenceLogFileConfig(),
  }) async {
    if (!isAndroid) return;
    try {
      await _logFileChannel.invokeMethod<void>(
        'configureLogFile',
        config.toMap(),
      );
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
  }

  /// Read the current app-private Android log file.
  ///
  /// Returns an empty string when no file exists or outside Android.
  Future<String> readLogFile() async {
    if (!isAndroid) return '';
    try {
      return await _logFileChannel.invokeMethod<String>('readLogFile') ?? '';
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
  }

  /// Clear the app-private Android log file. No-op outside Android.
  Future<void> clearLogFile() async {
    if (!isAndroid) return;
    try {
      await _logFileChannel.invokeMethod<void>('clearLogFile');
    } catch (e, stackTrace) {
      throw NativeGeofenceExceptionMapper.fromError(e, stackTrace);
    }
  }

  /// Stop receiving geofence events for a given [Geofence].
  ///
  /// If the [Geofence] is not registered, this method does nothing.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> removeGeofence(Geofence region) async =>
      removeGeofenceById(region.id);

  /// Stop receiving geofence events for an identifier associated with a
  /// geofence region.
  ///
  /// If a [Geofence] with the given ID is not registered, this method does
  /// nothing.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> removeGeofenceById(String id) async => _api
      .removeGeofenceById(id: id)
      .catchError(NativeGeofenceExceptionMapper.catchError<void>);

  /// Stop receiving geofence events for all registered geofences.
  ///
  /// If there are no geofences registered, this method does nothing.
  ///
  /// Throws [NativeGeofenceException].
  Future<void> removeAllGeofences() async => _api
      .removeAllGeofences()
      .catchError(NativeGeofenceExceptionMapper.catchError<void>);
}

/// Internal sequencing seam kept outside the singleton so initialization order
/// and failure short-circuiting remain directly testable.
Future<void> initializeNativeGeofenceRuntime({
  required Future<void> Function() initializeDispatcher,
  required bool initializeIosRuntime,
  required void Function() initializeTriggerApi,
  required NativeGeofenceBackgroundApi Function() ensureBackgroundManager,
}) async {
  await initializeDispatcher();
  if (!initializeIosRuntime) return;

  initializeTriggerApi();
  final backgroundApi = ensureBackgroundManager();
  await backgroundApi.triggerApiInitialized();
}
