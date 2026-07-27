class Constants {
    static let PACKAGE_NAME = "com.chunkytofustudios.native_geofence"
    private static let STORAGE_KEY_PREFIX = "\(PACKAGE_NAME)."
    static let CALLBACK_LOOKUP_TERMINAL_ERROR_MARKER =
        "\(PACKAGE_NAME).callback_lookup_terminal.v1"
    
    static let HEADLESS_FLUTTER_ENGINE_NAME = "NativeGeofenceIsolate"
    
    static let CALLBACK_DISPATCHER_KEY = "\(STORAGE_KEY_PREFIX)callback_dispatcher_handler"
    static let GEOFENCE_CALLBACK_DICT_KEY = "\(STORAGE_KEY_PREFIX)geofence_callback_dict"
    static let GEOFENCE_CALLBACK_CONTEXT_DICT_KEY =
        "\(STORAGE_KEY_PREFIX)geofence_callback_context_dict"
    static let GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_DICT_KEY =
        "\(STORAGE_KEY_PREFIX)geofence_callback_package_fingerprint_dict"
    static let GEOFENCE_LAST_EVENT_DICT_KEY =
        "\(STORAGE_KEY_PREFIX)geofence_last_event_dict"
    static let GEOFENCE_CALLBACK_JOURNAL_KEY =
        "\(STORAGE_KEY_PREFIX)geofence_callback_journal_v1"
    static let GEOFENCE_PENDING_BOUNDARY_EVENTS_KEY =
        "\(STORAGE_KEY_PREFIX)geofence_pending_boundary_events_v1"
    static let SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY =
        "\(STORAGE_KEY_PREFIX)geofence_synchronization_registration_fingerprint"
    static let SYNCHRONIZED_PACKAGE_FINGERPRINT_KEY =
        "\(STORAGE_KEY_PREFIX)geofence_synchronized_package_fingerprint"
    static let DIAGNOSTIC_FACT_KEY_PREFIX = "\(STORAGE_KEY_PREFIX)diagnostic_fact/"
    static let DIAGNOSTIC_DELIVERY_TRACE_KEY =
        "\(STORAGE_KEY_PREFIX)diagnostic_delivery_trace_v1"
    static let DIAGNOSTIC_DELIVERY_TRACE_SEQUENCE_KEY =
        "\(STORAGE_KEY_PREFIX)diagnostic_delivery_trace_sequence_v1"
    static let DIAGNOSTIC_DELIVERY_TRACE_DROPPED_KEY =
        "\(STORAGE_KEY_PREFIX)diagnostic_delivery_trace_dropped_v1"
    static let USER_DEFAULTS_MIGRATION_KEY =
        "\(STORAGE_KEY_PREFIX)user_defaults_keys_migrated_v1"

    static let LEGACY_USER_DEFAULTS_KEY_MIGRATIONS: [(legacy: String, current: String)] = [
        ("callback_dispatcher_handler", CALLBACK_DISPATCHER_KEY),
        ("geofence_callback_dict", GEOFENCE_CALLBACK_DICT_KEY),
        ("geofence_callback_context_dict", GEOFENCE_CALLBACK_CONTEXT_DICT_KEY),
        (
            "geofence_callback_package_fingerprint_dict",
            GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_DICT_KEY
        ),
        ("geofence_last_event_dict", GEOFENCE_LAST_EVENT_DICT_KEY),
        ("geofence_callback_journal_v1", GEOFENCE_CALLBACK_JOURNAL_KEY),
        (
            "geofence_synchronization_registration_fingerprint",
            SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY
        ),
        (
            "geofence_synchronized_package_fingerprint",
            SYNCHRONIZED_PACKAGE_FINGERPRINT_KEY
        ),
    ]
    static let LEGACY_DIAGNOSTIC_FACT_KEY_PREFIX = "native_geofence_diagnostic_fact/"

    // Suppress only the immediate same-direction burst. Longer-term business
    // deduplication belongs in the app or backend.
    static let LAST_EVENT_SUPPRESSION_TTL_MILLIS: Int64 = 10 * 1000
}
