import 'package:native_geofence/src/generated/platform_bindings.g.dart';

/// A simple representation of a geographic location.
///
/// The latitude and longitude are expressed in decimal degrees.
/// See: https://en.wikipedia.org/wiki/Decimal_degrees
class Location {
  final double latitude;
  final double longitude;

  /// Horizontal accuracy in meters, when known.
  final double? accuracyMeters;

  /// Whether this fix came from a mock location provider.
  ///
  /// This is informational metadata for app policy; it is not proof that a
  /// location is trustworthy and native_geofence does not reject mock fixes.
  /// It is effectively Android-only because iOS geofence callbacks do not
  /// include a location fix.
  final bool isMock;

  /// Wall-clock timestamp reported by the native location provider.
  final DateTime? fixTime;

  /// Monotonic provider timestamp. Primarily useful for diagnostics because it
  /// remains meaningful when the device wall clock changes.
  final int? elapsedRealtimeNanos;

  const Location({
    required this.latitude,
    required this.longitude,
    this.accuracyMeters,
    this.isMock = false,
    this.fixTime,
    this.elapsedRealtimeNanos,
  });

  /// Whether this location instance is valid.
  bool get isValid =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;

  Map<String, Object?> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracyMeters': accuracyMeters,
        'isMock': isMock,
        'fixTimeMillis': fixTime?.millisecondsSinceEpoch,
        'elapsedRealtimeNanos': elapsedRealtimeNanos,
      };

  @override
  String toString() {
    return 'Location(${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}'
        '${accuracyMeters != null ? ', ±${accuracyMeters!.toStringAsFixed(0)}m' : ''}'
        '${isMock ? ', mock' : ''})';
  }
}

/// iOS specific Geofence settings.
class IosGeofenceSettings {
  /// Whether a geofence event should trigger immediately when the geofence is
  /// added.
  /// For example, setting this to true will trigger an [GeofenceEvent.enter]
  /// event if the user is already inside the geofence.
  /// Don't worry: This initial trigger only happens when the geofence is
  /// created and NOT every time the plugin is initialized.
  ///
  /// iOS suppresses best-effort same-direction duplicate bursts within 10
  /// seconds. Removing and re-creating the geofence resets that baseline. If
  /// only one direction is enabled, a genuine rapid leave and re-entry can be
  /// indistinguishable from a duplicate, so business-level state still belongs
  /// in the app or backend.
  final bool initialTrigger;

  const IosGeofenceSettings({
    this.initialTrigger = false,
  });

  Map<String, Object?> toJson() => {'initialTrigger': initialTrigger};

  @override
  String toString() {
    return 'IosGeofenceSettings(initialTrigger: $initialTrigger)';
  }
}

/// Android specific Geofence settings.
class AndroidGeofenceSettings {
  /// Sets the geofence behavior at the moment when the geofences are added.
  /// For example, listing [GeofenceEvent.enter] here will trigger the Geofence
  /// immediately if the user is already inside the geofence.
  /// Don't worry: This initial trigger only happens when the geofence is
  /// created and NOT every time the plugin is initialized.
  final Set<GeofenceEvent> initialTriggers;

  /// The geofence will be removed automatically after this period of time.
  /// If you don't set this the geofence will never expire.
  /// When set, the duration must be at least one millisecond.
  final Duration? expiration;

  /// The delay between [GeofenceEvent.enter] and [GeofenceEvent.dwell].
  /// Only has impact if [GeofenceEvent.dwell] is one of the triggers.
  ///
  /// Android Play services accepts a non-negative 32-bit millisecond value, so
  /// keep this at or below `Duration(milliseconds: 2147483647)`.
  final Duration loiteringDelay;

  /// The responsiveness of the geofence.
  ///
  /// When null, Android keeps the platform's fastest default (`0ms`). A larger
  /// value, for example 5 minutes, can save power at the cost of latency.
  /// However, a very small value does not guarantee immediate delivery: the OS
  /// may adjust timing to save power or protect system health.
  ///
  /// Android Play services accepts a non-negative 32-bit millisecond value, so
  /// keep this at or below `Duration(milliseconds: 2147483647)`.
  final Duration? notificationResponsiveness;

  const AndroidGeofenceSettings({
    required this.initialTriggers,
    this.expiration,
    this.loiteringDelay = const Duration(minutes: 5),
    this.notificationResponsiveness,
  });

  Map<String, Object?> toJson() => {
        'initialTriggers': initialTriggers.map((event) => event.name).toList()
          ..sort(),
        'expirationMillis': expiration?.inMilliseconds,
        'loiteringDelayMillis': loiteringDelay.inMilliseconds,
        'notificationResponsivenessMillis':
            notificationResponsiveness?.inMilliseconds,
      };

  @override
  String toString() {
    return 'AndroidGeofenceSettings('
        'initialTriggers: [${initialTriggers.map((e) => e.name).join(',')}], '
        'expiration: ${expiration?.inMinutes}min, '
        'loiteringDelay: ${loiteringDelay.inMilliseconds}ms, '
        'notificationResponsiveness: ${notificationResponsiveness?.inMilliseconds}ms)';
  }
}

/// A circular region which represents a geofence.
///
/// Platform limits apply: iOS permits at most 20 monitored regions per app,
/// including regions owned outside this plugin, and Android permits at most
/// 100 geofences per app. Apps with larger catalogs should rotate the most
/// relevant regions as the user moves.
class Geofence {
  /// The ID associated with the geofence.
  ///
  /// This ID is used to identify the geofence and is required to delete a
  /// specific geofence.
  /// Creating two geofences with the same ID will result in the first geofence
  /// being overwritten.
  final String id;

  /// The location of the geofence.
  final Location location;

  /// The radius, in meters, around [location] that will be considered part of
  /// the geofence.
  ///
  /// Must be finite and strictly positive. On iOS, values above the device's
  /// maximum region-monitoring distance are clamped to that maximum.
  final double radiusMeters;

  /// The types of geofence events to listen for.
  ///
  /// Note: [GeofenceEvent.dwell] is not supported on iOS.
  final Set<GeofenceEvent> triggers;

  /// iOS specific settings.
  final IosGeofenceSettings iosSettings;

  /// Android specific settings.
  final AndroidGeofenceSettings androidSettings;

  const Geofence({
    required this.id,
    required this.location,
    required this.radiusMeters,
    required this.triggers,
    required this.iosSettings,
    required this.androidSettings,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'location': location.toJson(),
        'radiusMeters': radiusMeters,
        'triggers': triggers.map((event) => event.name).toList()..sort(),
        'iosSettings': iosSettings.toJson(),
        'androidSettings': androidSettings.toJson(),
      };

  @override
  String toString() {
    return 'Geofence('
        'id: $id, '
        'location: $location, '
        'radiusMeters: $radiusMeters, '
        'triggers: [${triggers.map((e) => e.name).join(',')}], '
        'iosSettings: $iosSettings, '
        'androidSettings: $androidSettings)';
  }
}

/// A Geofence that is registered and is actively being tracked.
///
/// This type is a subset of [Geofence] that is returned by the plugin for GET
/// calls.
///
/// See the [Geofence] class for field details.
///
/// Note: [IosGeofenceSettings] is not provided due to platform constraints.
class ActiveGeofence {
  /// The ID associated with the geofence.
  final String id;

  /// The location of the geofence.
  final Location location;

  /// The radius, in meters, around [location] that will be considered part of
  /// the geofence.
  final double radiusMeters;

  /// The types of geofence events to listen for.
  final Set<GeofenceEvent> triggers;

  /// Only available on Android.
  ///
  /// Registered-state queries return the plugin's canonical configured
  /// settings. Callback payloads are reconstructed from durable registration
  /// metadata when available, but callers should treat one-shot
  /// [AndroidGeofenceSettings.initialTriggers] as configuration rather than
  /// proof that an initial event occurred.
  final AndroidGeofenceSettings? androidSettings;

  /// The absolute Android expiration deadline represented by this active
  /// snapshot. Null means the registration does not expire, the platform is
  /// not Android, or a legacy queued callback did not contain deadline data.
  ///
  /// Unlike [AndroidGeofenceSettings.expiration], this value does not restart
  /// when a higher-level coordinator restores a failed multi-layer mutation.
  final DateTime? expirationDeadline;

  ActiveGeofence({
    required this.id,
    required this.location,
    required this.radiusMeters,
    required this.triggers,
    required this.androidSettings,
    this.expirationDeadline,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'location': location.toJson(),
        'radiusMeters': radiusMeters,
        'triggers': triggers.map((event) => event.name).toList()..sort(),
        'androidSettings': androidSettings?.toJson(),
        'expirationDeadlineMillis': expirationDeadline?.millisecondsSinceEpoch,
      };

  @override
  String toString() {
    return 'ActiveGeofence('
        'id: $id, '
        'location: $location, '
        'radiusMeters: $radiusMeters, '
        'triggers: [${triggers.map((e) => e.name).join(',')}], '
        'androidSettings: $androidSettings, '
        'expirationDeadline: $expirationDeadline)';
  }
}

/// The parameters passed to the geofence callback handler.
class GeofenceCallbackParams {
  /// The geofences that triggered the event.
  /// The list might contain multiple elements on Android.
  final List<ActiveGeofence> geofences;

  /// The type of geofence event.
  final GeofenceEvent event;

  /// The location of the device when the geofence event was triggered.
  ///
  /// Only set on Android and even then it might sometimes be null.
  ///
  /// Not set on iOS because the OS does not provide this information. See:
  /// https://developer.apple.com/documentation/corelocation/cllocationmanagerdelegate/locationmanager(_:diddeterminestate:for:)
  final Location? location;

  /// Device wall-clock time captured when native code created this event.
  ///
  /// Android delivery may happen minutes later if the device is idle or work is
  /// deferred. Prefer this value, usually converted with `toUtc()`, over
  /// `DateTime.now()` inside the callback when the distinction matters. This is
  /// diagnostic metadata, not a monotonic clock or unique event ID.
  final DateTime? eventAt;

  /// Unique ID for this native delivery attempt.
  ///
  /// A later delivery for the same physical transition can have a different
  /// ID, so this is not a durable business idempotency key. Apps and backends
  /// should still enforce their own state rules. Set on Android and iOS.
  final String? eventId;

  /// Root delivery identity shared by native, confirmation, and application
  /// processing stages.
  ///
  /// For a direct native callback this normally equals [eventId]. A smart
  /// confirmation may create a new [eventId] while retaining this value.
  final String? traceId;

  /// Opaque callback contexts keyed by triggering geofence ID.
  ///
  /// Registrations without a context are absent. The plugin never interprets
  /// these values; they are useful when one callback dispatches app-owned work.
  final Map<String, int> callbackContextsByGeofenceId;

  const GeofenceCallbackParams({
    required this.geofences,
    required this.event,
    required this.location,
    this.eventAt,
    this.eventId,
    this.traceId,
    this.callbackContextsByGeofenceId = const {},
  });

  /// Returns a bounded summary that intentionally omits registration IDs,
  /// coordinates, callback contexts, timestamps, and delivery IDs.
  @override
  String toString() {
    return 'GeofenceCallbackParams('
        'geofenceCount: ${geofences.length}, '
        'event: ${event.name}, '
        'hasLocation: ${location != null}, '
        'hasEventAt: ${eventAt != null}, '
        'hasEventId: ${eventId != null}, '
        'hasTraceId: ${traceId != null}, '
        'callbackContextCount: ${callbackContextsByGeofenceId.length})';
  }
}
