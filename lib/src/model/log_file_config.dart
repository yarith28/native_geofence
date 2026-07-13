/// Configuration for native_geofence's app-private Android log file.
///
/// File logging is disabled by default. When enabled, native_geofence writes a
/// bounded text log under the app's private no-backup files directory. Apps can
/// fetch it with `NativeGeofenceManager.readLogFile()` and decide how to display,
/// export, upload, redact, or clear it.
class NativeGeofenceLogFileConfig {
  /// Whether native_geofence should write native diagnostics to disk.
  final bool enabled;

  /// Maximum size of the log file in bytes. Android clamps this to a safe range.
  final int maxBytes;

  const NativeGeofenceLogFileConfig({
    this.enabled = false,
    this.maxBytes = 256 * 1024,
  });

  Map<String, Object?> toMap() => {
        'enabled': enabled,
        'maxBytes': maxBytes,
      };

  @override
  String toString() =>
      'NativeGeofenceLogFileConfig(enabled: $enabled, maxBytes: $maxBytes)';
}
