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

  const Location({
    required this.latitude,
    required this.longitude,
    this.accuracyMeters,
    this.isMock = false,
  });

  /// Whether this location instance is valid.
  bool get isValid =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;

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
  final Duration? expiration;

  /// The delay between [GeofenceEvent.enter] and [GeofenceEvent.dwell].
  /// Only has impact if [GeofenceEvent.dwell] is one of the triggers.
  final Duration loiteringDelay;

  /// The responsiveness of the geofence.
  ///
  /// Defaults to 0. Setting a big responsiveness value, for example 5 minutes,
  /// can save power significantly. However, setting a very small responsiveness
  /// value, for example 5 seconds, doesn't necessarily mean you will get
  /// notified right after the user enters or exits a geofence: internally, the
  /// OS might adjust the responsiveness value to save power when needed.
  final Duration? notificationResponsiveness;

  const AndroidGeofenceSettings({
    required this.initialTriggers,
    this.expiration,
    this.loiteringDelay = const Duration(minutes: 5),
    this.notificationResponsiveness,
  });

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
  /// The [initialTriggers] field will always be an empty list because Android
  /// does not provide this information when a Geofence triggers.
  final AndroidGeofenceSettings? androidSettings;

  ActiveGeofence({
    required this.id,
    required this.location,
    required this.radiusMeters,
    required this.triggers,
    required this.androidSettings,
  });

  @override
  String toString() {
    return 'ActiveGeofence('
        'id: $id, '
        'location: $location, '
        'radiusMeters: $radiusMeters, '
        'triggers: [${triggers.map((e) => e.name).join(',')}], '
        'androidSettings: $androidSettings)';
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
  /// This is diagnostic metadata, not a monotonic clock or unique event ID.
  final DateTime? eventAt;

  /// Unique ID for this native delivery attempt.
  ///
  /// A later delivery for the same physical transition can have a different
  /// ID, so this is not a durable business idempotency key. Apps and backends
  /// should still enforce their own state rules. Currently only set on iOS.
  final String? eventId;

  const GeofenceCallbackParams({
    required this.geofences,
    required this.event,
    required this.location,
    this.eventAt,
    this.eventId,
  });

  @override
  String toString() {
    return 'GeofenceCallbackParams('
        'geofences: [${geofences.map((e) => e.toString()).join(', ')}], '
        'event: ${event.name}, '
        'location: $location, '
        'eventAt: $eventAt, '
        'eventId: $eventId)';
  }
}
