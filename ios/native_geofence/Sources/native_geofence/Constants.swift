class Constants {
    static let PACKAGE_NAME = "com.chunkytofustudios.native_geofence"
    
    static let HEADLESS_FLUTTER_ENGINE_NAME = "NativeGeofenceIsolate"
    
    static let CALLBACK_DISPATCHER_KEY = "callback_dispatcher_handler"
    static let GEOFENCE_CALLBACK_DICT_KEY = "geofence_callback_dict"
    static let GEOFENCE_LAST_EVENT_DICT_KEY = "geofence_last_event_dict"

    // Suppress only the immediate same-direction burst. Longer-term business
    // deduplication belongs in the app or backend.
    static let LAST_EVENT_SUPPRESSION_TTL_MILLIS: Int64 = 10 * 1000
}
