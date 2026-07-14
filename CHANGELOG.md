## Unreleased

* Owns the required non-exported Android callback receiver and foreground service, and reports a typed error if the receiver is removed or disabled in the merged manifest
* Stores canonical Android registrations, absolute expiration deadlines, recovery eligibility, plugin-active state, and raw cleanup IDs with checked synchronous writes and exact rollback snapshots
* Routes Android shared-`PendingIntent` broadcasts by persisted geofence ID, splits mixed callbacks by handle, and restores exact prior storage when native registration fails
* Serializes Android create, remove, remove-all, explicit recreation, and orphan cleanup through an exact-once FIFO boundary while retaining durable evidence until platform removal succeeds
* Owns Android reboot, package-replacement, location-restoration, and `GEOFENCE_NOT_AVAILABLE` recovery; preserves finite lifetime, suppresses recovery initial triggers, and retries 14 times over a 660-minute horizon
* Records privacy-safe Android package fingerprints with callback registrations so handles created by an older app package can be detected before delivery
* Moves Android callback payloads out of WorkManager `Data`, continues already-enqueued legacy file payloads across plugin upgrades, confirms enqueue acceptance before releasing one callback-and-orphan broadcast lease, adds non-null delivery IDs, bounded retries, proven-stale callback evidence, and exact-once startup/API/callback watchdog cleanup
* Makes Android foreground promotion token-confirmed and time-bounded, owns the wake lock, stops on every worker outcome, maps start restrictions to typed errors, and supports host string-resource overrides for its notification
* Adds an optional Android native event processor with accept/validated-transform/decline decisions, a hard ownership timeout, exact-once completion, safe Dart fallback, and shared durable payload cleanup
* Adds an asynchronous, read-only `NativeGeofenceStatus` API with privacy-safe prerequisite evidence, plugin-owned IDs, computed health, callback refresh state, platform-specific monitoring evidence, and structured authoritative lifecycle facts
* Fails Android initialization when the callback dispatcher handle cannot be durably persisted
* Serializes iOS background callback delivery and protects callback execution with bounded cleanup
* Adds iOS delivery IDs and suppresses same-direction duplicate bursts within 10 seconds
* Exposes the native event-creation time on geofence callback parameters
* Adds opt-in, bounded Android native log-file controls for collecting background diagnostics
* Includes Android callback-location accuracy and mock-provider metadata for app policy and diagnostics
* Waits for iOS Core Location to confirm geofence registration, reports region-scoped failures, ignores unscoped nil-region failures that cannot be attributed safely, and clamps oversized regions to the device maximum
* Rejects non-finite geofence radii and new iOS registrations beyond the app-wide region limit
* Limits iOS geofence queries and removals to circular regions backed by plugin callback metadata
* Requires Always location authorization for iOS geofences, checks whether Location Services are enabled off the main thread, and keeps those checks cancellable by removal
* Isolates explicit iOS initial-state checks so unsolicited state callbacks cannot emit enter or exit events
* Registers Flutter plugins in the background callback isolate and throws a typed `NativeGeofenceException` when its manager is accessed before callback initialization, including in release builds
* Reports Android geofence registration and removal failures with actionable Play Services status evidence instead of inferring `geofenceNotFound` from the local cache
* Supports foreground callbacks on Android 6.0–7.1 by guarding newer service and notification APIs, providing a valid fallback notification icon, and declaring the AndroidX Core APIs used by the plugin directly
* Centralizes Android package-manager compatibility calls and uses AndroidX helpers for package versions, mock locations, and foreground teardown without changing API-23 or location-only foreground behavior

## 1.3.1

* Improves AGP 9 support (by [doug-shontz](https://github.com/doug-shontz))

## 1.3.0

* Adds Swift Package Manager support (by [doug-shontz](https://github.com/doug-shontz))
* Adds AGP 9 support for Flutter 3.44+ (by [doug-shontz](https://github.com/doug-shontz))

## 1.2.2

* Upgrade dependencies
* Update README to clarify Android minSDKVersion

## 1.2.1

* Upgrade dependencies
* Add new optional step to Android setup instructions

## 1.2.0

* iOS: Fixes regression: geofences callbacks not being executed after their first trigger
  * Reverts 1.1.0 change which had enabled calling GeofenceManager methods in geofence callbacks
* iOS: Do not call Dart callback for unrequested geofence triggers: [#37](https://github.com/ChunkyTofuStudios/native_geofence/pull/37) by [slaci](https://github.com/slaci)
* Upgrade dependencies

## 1.1.0

* Upgrade pub.dev dependencies
* Upgrade Android Gradle dependencies
* Downgrade Android minSdkVersion to 23 (thanks [AzarouAmine](https://github.com/AzarouAmine)!)
* Allow calling GeofenceManager methods in geofence callbacks (thanks [Mako-L](https://github.com/Mako-L)!)
* Example App: refactor notification logic into a NotificationsRepository (thanks [fadelfffar](https://github.com/fadelfffar)!)

## 1.0.9

* Minor visibility fix: Make `NativeGeofenceException` visible to library users.

## 1.0.8

* Make plugin compatible with Flutter apps using Kotlin 2+.

## 1.0.7

* Fixes a bug with Android 30 and older. [#9](https://github.com/ChunkyTofuStudios/native_geofence/issues/9)
* Improve documentation.

## 1.0.6

* iOS: Improved background isolate spawning & cleanup routine.
* iOS: Fixes rare bug that may cause the goefence to triggering twice.

## 1.0.5

* Android: Specify Kotlin package when using Pigeon.

## 1.0.4

* Android: Use custom error class name to avoid naming conflicts ("Type FlutterError is defined multiple times") at build time.

## 1.0.3

* iOS: Removes `UIBackgroundModes.location` which was not required. Thanks @cbrauchli.

## 1.0.2

* iOS and Android: Process geofence callbacks sequentially; as opposed to in parallel.
* README changes.

## 1.0.1

* WASM support.
* Better documentation.
* Formatting fixes.

## 1.0.0

* Initial release.
