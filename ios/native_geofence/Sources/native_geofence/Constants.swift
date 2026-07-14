class Constants {
    static let PACKAGE_NAME = "com.chunkytofustudios.native_geofence"
    
    static let HEADLESS_FLUTTER_ENGINE_NAME = "NativeGeofenceIsolate"
    
    static let CALLBACK_DISPATCHER_KEY = "callback_dispatcher_handler"
    static let GEOFENCE_CALLBACK_DICT_KEY = "geofence_callback_dict"
    static let GEOFENCE_CALLBACK_CONTEXT_DICT_KEY = "geofence_callback_context_dict"
    static let GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_DICT_KEY =
        "geofence_callback_package_fingerprint_dict"
    static let GEOFENCE_LAST_EVENT_DICT_KEY = "geofence_last_event_dict"
    static let SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY =
        "geofence_synchronization_registration_fingerprint"
    static let SYNCHRONIZED_PACKAGE_FINGERPRINT_KEY =
        "geofence_synchronized_package_fingerprint"
    static let DIAGNOSTIC_FACT_KEY_PREFIX = "native_geofence_diagnostic_fact/"

    // Suppress only the immediate same-direction burst. Longer-term business
    // deduplication belongs in the app or backend.
    static let LAST_EVENT_SUPPRESSION_TTL_MILLIS: Int64 = 10 * 1000
}
