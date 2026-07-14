# Native Geofence

Battery efficient Flutter geofencing plugin that uses native iOS and Android APIs.

<dl>
  <dt><b>What is geofencing?</b></dt>
  <dd>A way for your app to be alerted when the user enters or exits a geographical region. You might use geofences to perform location-related tasks. For example, to setup reminders when the user leaves their house.</dd>
  <dt><b>What are the plugin requirements?</b></dt>
  <dd>iOS 14+ and Android API 23+. You will also need to obtain background location permission from the user.</dd>
</dl>

## Features

* Uses [CLLocationManager](https://developer.apple.com/documentation/corelocation/cllocationmanager) on iOS and [GeofencingClient](https://developer.android.com/develop/sensors-and-location/location/geofencing) on Android
* Create geofences
* Be notified of enter/exit events and Android dwell events
* Works when the application is:
  * In the foreground
  * In the background
  * Terminated, subject to platform delivery, force-stop, permission, and OEM
    background restrictions
* [Android] Re-register geofences after device reboot
* Fetch currently registered geofences
* [Android] Promote bounded callback work to a foreground service

## Setup

<details>
<summary>Android</summary>

### Android

1. Kotlin setup

This plugin works with both Android Kotlin setups, so follow the one that matches your toolchain:

- **Flutter 3.44+ (AGP 9) — built-in Kotlin:** Kotlin is provided by the Android Gradle Plugin, so there is nothing to add. Do **not** apply the `kotlin-android` Gradle plugin yourself — AGP 9 rejects an explicitly applied Kotlin plugin. See Flutter's [built-in Kotlin migration guide](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin).
- **Older Flutter (AGP 8):** apply the Kotlin Gradle plugin as usual, and ensure your Kotlin version is at least `1.9.25` (see this [guide](https://docs.flutter.dev/release/breaking-changes/kotlin-version)). The latest Kotlin version can be found [here](https://mvnrepository.com/artifact/org.jetbrains.kotlin.android/org.jetbrains.kotlin.android.gradle.plugin).

The [example app](https://github.com/ChunkyTofuStudios/native_geofence/tree/main/example/android) demonstrates the AGP 8 setup, with comments in its Gradle files noting the AGP 9 difference.

NOTE: You may also need Gradle 8+ to use this plugin. See this [issue](https://github.com/ChunkyTofuStudios/native_geofence/issues/4).

2. Set your `minSdkVersion` to `23` or above.

*Explanation: If you need to support prior Android builds it might be possible to accommodate this. Please send a PR or file a bug.*

See the [example plugin](https://github.com/ChunkyTofuStudios/native_geofence/blob/main/example/android/app/src/main/AndroidManifest.xml) for a full demonstration.

3. Declare the host application's location capabilities before the
`<application ...` line:

```xml
<!-- Used by plugin: native_geofence -->
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
```

The coarse and fine location capabilities are required to create a geofence.
Background location is [also required](https://developer.android.com/develop/sensors-and-location/location/geofencing#RequestGeofences)
on Android 10+. Manifest declarations do not grant access: the application must
still explain and request the applicable runtime location permissions before
registration.

4. Review the plugin's manifest-merged defaults.

The plugin automatically merges its non-exported callback receiver,
non-exported location-mode recovery receiver, foreground service,
reboot/package-replacement receiver, and the permissions used for boot recovery,
wake locks, location-type foreground services, and notifications.
The application must still request `POST_NOTIFICATIONS` at runtime on Android
13+ before foreground promotion. Removing or disabling the callback receiver
causes registration to fail with a typed manifest-component error.

The plugin observes location services becoming available through a live
non-exported receiver while attached and through the manifest receiver where
Android delivers the location-mode broadcast. Background-broadcast restrictions
mean the manifest path is a fallback, not a guarantee on every Android release
or OEM.

Hosts that do not use automatic reboot recovery or foreground promotion may
remove the corresponding optional declarations in their app manifest. Only
remove a permission when no other part of the application needs it:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          xmlns:tools="http://schemas.android.com/tools">
    <!-- Opt out of automatic reboot/package-replacement recovery. -->
    <uses-permission
        android:name="android.permission.RECEIVE_BOOT_COMPLETED"
        tools:node="remove" />

    <!-- Opt out of callback foreground promotion. -->
    <uses-permission android:name="android.permission.WAKE_LOCK"
                     tools:node="remove" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"
                     tools:node="remove" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"
                     tools:node="remove" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"
                     tools:node="remove" />

    <application ...>
        <receiver
            android:name="com.chunkytofustudios.native_geofence.receivers.NativeGeofenceRebootBroadcastReceiver"
            tools:node="remove" />
        <service
            android:name="com.chunkytofustudios.native_geofence.NativeGeofenceForegroundService"
            tools:node="remove" />
    </application>
</manifest>
```

Removing the reboot receiver disables automatic reboot and package-replacement
recovery; explicit recovery remains available through `reCreateAfterReboot()`.
Removing the service or its permissions disables `promoteToForeground()`. The
foreground-notification strings can instead be customized without opting out;
see [Foreground work](#android-only-foreground-work).

Android recovery preserves each finite registration's original absolute
expiration deadline; reboot or repair never grants a new full lifetime.
Expired and corrupt registrations are cleaned from Play services before their
durable cleanup IDs are removed. Automatic recovery suppresses initial triggers
and reserves its first durable retry before immediate recovery work. Transient
failures retry after 4, 8, 16, and 32 minutes, followed by ten hourly attempts
(14 delayed attempts over 660 minutes, or about 11 hours). Missing location
permissions stop that retry generation. The explicit
`reCreateAfterReboot()` API is asynchronous and reports recovery failures.
Recovery reuses the callback handles and contexts already in native storage;
it cannot resolve live Dart functions from a newly installed app build. Call
`ensureSynchronized()` with your app-owned registration list to perform that
refresh.

5. Understand Android background-delivery limits

Geofence broadcasts are handed to expedited WorkManager work. Android may still
delay that work in Doze, restrictive App Standby buckets, under system load, or
after expedited-job quota is exhausted; native_geofence then allows ordinary
background work rather than dropping the callback. Aggressive OEM task killers,
force-stop, revoked permissions, disabled location services, and battery
restrictions can delay or prevent delivery.

Keep callbacks short and durable: persist the event first, enqueue app-owned
long-running work, then return. If timely background behavior is central to the
product, explain the tradeoff before directing users to the system's unrestricted
battery setting. Foreground promotion can extend work after a worker starts, but
it cannot make a delayed worker start promptly and Android may reject the start.

</details>

<details>
<summary>iOS</summary>
 
### iOS

1. Use a Swift AppDelegate

The plugin's background registrant callback is exposed through the Swift API.
Apps using an Objective-C AppDelegate must migrate it to Swift before completing
the setup below.

2. In your `Info.plist` add the following key-value pairs:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>USER_VISIBLE_STRING__DESCRIBE_HOW_YOUR_APP_USES_LOCATION.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>USER_VISIBLE_STRING__DESCRIBE_HOW_YOUR_APP_USES_BACKGROUND_LOCATION.</string>
```

*Explanation: iOS geofence monitoring in this plugin requires Always location authorization before calling `createGeofence()`. When-In-Use authorization is not enough because the plugin is designed for background and terminated-app geofence delivery.*

3. Update `AppDelegate.swift` to configure `NativeGeofencePlugin`.

In your `AppDelegate.swift` file import the plugin:

```swift
import native_geofence
```

and add the following near the top of the `application` function:

```swift
// Used by plugin: native_geofence
NativeGeofencePlugin.setPluginRegistrantCallback { registry in
    GeneratedPluginRegistrant.register(with: registry)
}
```

Set the callback before the normal
`GeneratedPluginRegistrant.register(with: self)` call. The plugin shares one
serialized callback runtime between foreground and headless delivery paths.
If this setup is missing, iOS terminates with an explicit registrant setup error
instead of silently dropping background callbacks.

4. Set your iOS version to `14.0` or above.

You can do so in your `Podfile` by adding the line `platform :ios, '14.0'`.

*Explanation: If you need to support prior iOS builds it might be possible to accommodate this. Please send a PR or file a bug.*

See the [example plugin](https://github.com/ChunkyTofuStudios/native_geofence/tree/main/example/ios/Runner) for a full demonstration.

</details>

## Usage

### Initialize the plugin

Before accessing any other API, initialize the plugin:

```dart
await NativeGeofenceManager.instance.initialize();
```

On iOS, initialization first persists the dispatcher handle, then prepares the
shared foreground/headless callback runtime and its background-manager singleton
before native delivery is marked ready.

### Obtain permissions

This plugin does not request permissions. Use an application-level permission
flow, such as [permission_handler](https://pub.dev/packages/permission_handler).

As noted in the setup section you will need to obtain the following permissions:

* `Permission.location`
* `Permission.locationAlways`: required for iOS background monitoring and on
  Android 10+ before registration
* `Permission.notification`: required on Android 13+ before calling
  `promoteToForeground()`

### Create geofence

First, define the region. IDs must be unique within the plugin-owned set:

```dart
final zone1 = Geofence(
  id: 'zone1',
  location: const Location(
    latitude: 40.75798,
    longitude: -73.98554,
  ), // Times Square
  radiusMeters: 500,
  triggers: {
    GeofenceEvent.enter,
    GeofenceEvent.exit,
    GeofenceEvent.dwell,
  },
  iosSettings: const IosGeofenceSettings(
    initialTrigger: true,
  ),
  androidSettings: AndroidGeofenceSettings(
    initialTriggers: {GeofenceEvent.enter},
    expiration: const Duration(days: 7),
    loiteringDelay: const Duration(minutes: 5),
  ),
);
```

The callback must be a top-level or static function annotated with
`@pragma('vm:entry-point')`. Flutter must retain and resolve it in release/AOT
builds and from a background isolate; closures and instance methods are
rejected. Different registrations may use different valid callbacks.

```dart
@pragma('vm:entry-point')
Future<void> geofenceTriggered(GeofenceCallbackParams params) async {
  for (final geofence in params.geofences) {
    final context = params.callbackContextsByGeofenceId[geofence.id];
    if (context == 1001) {
      // Route this registration to app-owned work.
    }
  }
  debugPrint('event=${params.event.name}, count=${params.geofences.length}');
}
```

Callback parameters can contain app-owned IDs and contexts, exact fence centers,
a device location, timestamps, and delivery IDs. Do not dump them into logs or
lock-screen notifications unless that disclosure is intentional. The default
`toString()` returns only a bounded presence/count summary.

Register directly when the application owns a one-off mutation. The optional
`callbackContext` is an opaque signed 64-bit routing value. The plugin stores it
with this registration and never interprets it:

```dart
await NativeGeofenceManager.instance.createGeofence(
  zone1,
  geofenceTriggered,
  callbackContext: 1001,
);
```

Contexts are returned in `callbackContextsByGeofenceId`. Registrations without
a context are absent from the map. The map is keyed by geofence ID because one
Android delivery can contain several triggering registrations.

On Android, a finite `expiration` is persisted as an absolute deadline. Reboot,
repair, and explicit recreation use only the remaining lifetime; they never
grant the geofence a fresh full duration. Lifecycle-critical registration state
is written synchronously, and a failed durable write is reported as an error.

Android `notificationResponsiveness` defaults to fastest delivery (`0ms`) when
unset. Larger values, such as two or five minutes, may reduce power use at the
cost of latency. `Duration.zero` is useful when overriding a previously slower
value. The OS may still adjust actual timing for battery and system health.

iOS allows at most 20 monitored regions per app, including regions registered
outside this plugin. Android allows at most 100 geofences per app. Background
location can be coarse, especially on idle devices; radii of at least 150 meters
are generally more reliable than very small regions.

### Synchronize an app-owned registration list

Use `GeofenceRegistration` when your database or configuration is the canonical
registration source:

```dart
final desired = <GeofenceRegistration>[
  GeofenceRegistration(
    geofence: zone1,
    callback: geofenceTriggered,
    callbackContext: 1001,
  ),
];

final inspection =
    await NativeGeofenceManager.instance.inspectSynchronization(desired);
debugPrint('matches=${inspection.matchesDesired}, reasons=${inspection.reasons}');

final report =
    await NativeGeofenceManager.instance.ensureSynchronized(desired);
debugPrint('changed=${report.didSynchronize}, reasons=${report.reasons}');
```

`inspectSynchronization()` validates callbacks and returns a read-only,
point-in-time comparison without modifying registrations, callback metadata, or
fingerprints. It is advisory, not a reservation: `ensureSynchronized()` always
re-inspects inside the shared native mutation boundary and can return a different
decision if native state changes first.

`ensureSynchronized()` resolves callback handles from the live functions in the
desired list. By default, `removeUnlisted: true` makes that list authoritative
and removes plugin-owned IDs it omits; pass `removeUnlisted: false` to manage a
subset. An authoritative pass compares and refreshes the global registration
fingerprint. A partial pass fingerprints exactly its supplied list, compares
those registrations directly, and does not treat a different or absent global
fingerprint as stale. Callback-refresh evidence is attributed by registration
ID, so a partial pass clears only its supplied scope and preserves evidence for
other registrations. Unchanged registrations stay armed, and
callback/context-only changes update metadata without an unnecessary platform
restart. Registration changes run as a native transaction; a partial failure
restores the prior registrations, finite deadlines, callback metadata, iOS
duplicate baseline, and fingerprint. Rollback failures are reported explicitly.

Every `ensureSynchronized()` call is one native-owned inspect-and-mutate
transaction, serialized with create, remove, and other
synchronization mutations across foreground and headless engine paths. Native
code owns the no-op decision, reasons, counts, fingerprint, and rollback
snapshot. On iOS, that mutation authority and its Core Location delegate remain
process-stable across Flutter engine detach and reattach; only event delivery is
reattached to the current engine.

Android bounds every Play Services geofence registration and removal task to 30
seconds so the native mutation queue cannot stall indefinitely. A timed-out
registration has an unknown platform outcome, so the transaction compensates by
removing the requested ID before restoring its prior snapshot. Late task
callbacks are ignored, and failed compensation remains visible in durable
recovery evidence.

Rollback and automatic recovery suppress initial triggers. Synchronization does
not re-arm unchanged regions. A new or platform-changed Android registration
still applies its configured `initialTriggers`; iOS synchronization does not
request an initial-state callback. The fingerprints exposed by inspection and
reports identify exactly the supplied desired list. The current authoritative
fingerprint is comparable to that desired fingerprint only for an authoritative
scope. These opaque tokens may contain registration and callback metadata—do
not treat them as privacy-safe log values.

Call `ensureSynchronized()` after initialization and permissions whenever the
app has its canonical desired list. This is distinct from recovery: reboot,
location-service, and explicit `reCreateAfterReboot()` paths reuse stored
callback handles and contexts. Only synchronization can resolve live Dart
functions after an app update, obfuscated rebuild, or callback move/rename.

### Callback delivery semantics

Android splits each broadcast by its persisted callback handle, stores callback
payloads in app-private files, and passes only a bounded reference through
WorkManager. Infrastructure and Dart-delivery failures are attempted up to four
times; missing or invalid callbacks are terminally dropped without blocking
later queued events. Worker startup, Dart API readiness, and callback execution
have 20-second, 15-second, and 60-second watchdogs respectively.

iOS serializes foreground and headless delivery through one shared callback
runtime and applies a 30-second execution bound. Best-effort same-direction
duplicate bursts are suppressed for 10 seconds, but business-level deduplication
still belongs in the app or backend.

Both native platforms attach an `eventId` for one delivery attempt. A retry or
later delivery for the same physical transition may have a different value, so
it is useful for tracing but is not a durable business idempotency key. Use an
app-owned key and state machine for check-in, attendance, billing, or other
irreversible actions. `eventAt` is the device wall-clock time captured when
native code creates the event; on Android it can be much earlier than callback
execution when WorkManager is delayed.

#### [Android only] Optional native event bridge

A host app may inspect an event before Dart by implementing
`NativeGeofenceEventProcessor` and installing it during application startup:

```kotlin
NativeGeofenceBridge.setProcessor { context, event, completion ->
    // Complete Accept only after native handling has finished.
    completion(Result.success(NativeGeofenceBridgeDecision.Decline))
}
```

For cold-process delivery, the processor may instead be a public class with a
public no-argument constructor named in application metadata:

```xml
<application ...>
    <meta-data
        android:name="com.chunkytofustudios.native_geofence.native_event_processor"
        android:value="com.example.MyNativeGeofenceProcessor" />
</application>
```

The plugin's consumer shrinker rules preserve implementations of
`NativeGeofenceEventProcessor`, including their class names and required entry
points, in minified release builds. `Accept` marks the event handled and
suppresses Dart delivery. `Transform` may select a
non-empty subset of the originally triggered IDs and alter the transition or
trigger location; invalid transformations fall back unchanged. `Decline`, a
processor exception/failure, or the three-second ownership timeout all continue
through normal Dart delivery. Late completions are ignored. The bridge runs
inside the same durable worker path, so it cannot bypass callback grouping,
payload cleanup, retries, or lifecycle telemetry.
Processors run on a bounded plugin bridge executor rather than the main thread;
their completion may be invoked from any thread.

#### [Android only] Foreground work

If you need to access certain APIs or run a long job in your geofence callback you can promote the runner to a foreground service. You have access to the following functions when running within a geofence callback:

```dart
await NativeGeofenceBackgroundManager.instance.promoteToForeground();
// Do bounded work that needs foreground-service privileges.
await NativeGeofenceBackgroundManager.instance.demoteToBackground();
```

*Note: Most tasks that complete in a few seconds, such as sending a notification,
don't require foreground promotion. Promotion waits up to 10 seconds for the
service to confirm `startForeground()`. The callback delivery itself has a
60-second watchdog, so foreground promotion does not make callback execution
unbounded or make a delayed WorkManager start timely. Android 12+ may reject a
background foreground-service start; Android 13+ requires runtime notification
permission; and Android 14+ location-type promotion requires the matching
foreground-service declaration plus background location access. The returned
`NativeGeofenceException` distinguishes a missing permission, invalid service
configuration, background-start restriction, and promotion timeout. The worker
always demotes and stops the service when delivery succeeds, retries, fails,
times out, or is cancelled.*

The host app can override the foreground notification copy by defining any of
these string resources in `android/app/src/main/res/values/strings.xml`:

```xml
<resources>
    <string name="native_geofence_notification_channel_name">Location updates</string>
    <string name="native_geofence_notification_title">Checking your location</string>
    <string name="native_geofence_notification_text">Your foreground disclosure</string>
</resources>
```

Omitted resources keep the plugin defaults.

### Get registered geofences

You can see which geofences are currently active using:

```dart
final List<ActiveGeofence> myGeofences =
    await NativeGeofenceManager.instance.getRegisteredGeofences();
print('There are ${myGeofences.length} active geofences.');
```

### Inspect diagnostic status

```dart
final NativeGeofenceStatus status =
    await NativeGeofenceManager.instance.getStatus();
print(status.registrationHealth);
```

Status is asynchronous, read-only, and privacy-safe. It includes persisted
plugin-owned registration counts, relevant permission and service prerequisites,
callback refresh evidence, computed registration health, and the most recent
structured registration/removal/broadcast/enqueue/worker/recovery/foreground
facts. Facts contain only a timestamp, fixed outcome label, success flag, and
optional count;
the snapshot does not contain registration IDs, coordinates, callback handles,
contexts, raw registration JSON, or synchronization fingerprints. The plugin
does not automatically dump the snapshot into logs.

On Android, registration health is derived from non-mutating lifecycle evidence:
active, recoverable, pending-cleanup, corrupt/raw-only, and unknown records remain
distinct, and cleanup IDs never count as healthy active monitoring. Delayed
recovery workers publish only fixed privacy-safe terminal outcomes while their
exact recovery generation and attempt still own the durable retry ticket.

Nullable fields mean the platform cannot provide the evidence. In particular,
Android reports `canEnumerateLivePlatformRegistrations == false`: Play Services
does not expose its live geofence set, so persisted state and PendingIntent state
are evidence rather than proof of live registration. iOS monitoring counts are
restricted to circular regions backed by plugin callback metadata and never
include unrelated app-wide monitored regions. Each lifecycle fact is only the
latest observation at that native boundary; the snapshot is not an audit trail,
proof that a registration is currently armed, or a guarantee of future delivery.
Public geofence, synchronization, lifecycle-fact, and status models provide
`toJson()` for structured app-owned diagnostics. Status JSON retains the same
privacy-safe field set described above.

### Remove geofence

You have multiple options to stop listening for geofence events:

```dart
// Remove a single geofence:
await NativeGeofenceManager.instance.removeGeofenceById('zone1');
// Remove all geofences:
await NativeGeofenceManager.instance.removeAllGeofences();
```

### Supported platforms

The native plugin is implemented for Android and iOS. The Dart package can be
imported elsewhere, but geofence operations require a native host and fail with
a channel error outside those platforms. Android log-file helpers are no-ops on
iOS and unsupported hosts.

## Error handling

All errors thrown by this plugin are wrapped in `NativeGeofenceException`.

Each exception contains an error code; see the API reference for its meaning.

Catch the exception and take the necessary action. For example:

```dart
try {
  await NativeGeofenceManager.instance.createGeofence(zone1, geofenceTriggered);
} on NativeGeofenceException catch (e) {
  if (e.code == NativeGeofenceErrorCode.missingLocationPermission) {
    print('Did the user grant us the location permission yet?');
    return;
  }
  if (e.code == NativeGeofenceErrorCode.missingBackgroundLocationPermission) {
    print('Background location permission is required for geofencing.');
    return;
  }
  if (e.code == NativeGeofenceErrorCode.pluginInternal) {
    print('Internal error: message=${e.message}, detail=${e.details}, '
        'stackTrace=${e.stacktrace}');
    return;
  }
  // Handle other cases.
}
```

## Example

The provided example app gates API access on initialization, requests
permissions, demonstrates direct registration plus synchronization inspection
and reconciliation, uses an opaque callback context for routing without
displaying it, and sends summary notifications without exact IDs or locations.

## Prior art

This plugin is based off of [bkonyi/FlutterGeofencing](https://github.com/bkonyi/FlutterGeofencing) and uses code snippets from [flutter_workmanager](https://github.com/fluttercommunity/flutter_workmanager). It was inspired by 525k.io's [geofence_foreground_service](https://pub.dev/packages/geofence_foreground_service) plugin.

## Contributing

Please file any issues, bugs, or feature requests at [GitHub](https://github.com/ChunkyTofuStudios/native_geofence/issues).

Pull requests are welcome.

### Future work

* **Android:** Allow customizing the wake lock duration when foreground service is launched.
* Other ideas?

## Known Issues

* **Android:** The emulator does not trigger geofence events if there are no apps accessing the device location. This is an [emulator issue](https://www.b4x.com/android/forum/threads/solved-sanity-check-does-the-android-emulator-work-with-geofences.139196/page-2#post-881415). As a workaround you can open Google Maps to get a location fix which will in turn trigger the geofence.

## Author

This plugin is developed by [Chunky Tofu Studios](https://chunkytofustudios.com).

You can support us by checking out our apps!

For commercial support please reach out to hello@chunkytofustudios.com.
