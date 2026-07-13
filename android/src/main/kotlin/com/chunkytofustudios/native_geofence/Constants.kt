package com.chunkytofustudios.native_geofence

class Constants {
    companion object {
        private const val PACKAGE_NAME = "com.chunkytofustudios.native_geofence"

        const val SHARED_PREFERENCES_KEY = "native_geofence_plugin_cache"
        // Kept as the raw plugin-owned ID index for backward compatibility.
        const val PERSISTENT_GEOFENCES_IDS_KEY = "persistent_geofences_ids"
        const val PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY = "persistent_configured_geofences_ids"
        const val PERSISTENT_GEOFENCE_KEY_PREFIX = "persistent_geofence/"
        const val PERSISTENT_GEOFENCE_EXPIRATION_KEY_PREFIX = "persistent_geofence_expiration/"
        const val PERSISTENT_GEOFENCE_RECOVERY_ELIGIBLE_KEY_PREFIX =
            "persistent_geofence_recovery_eligible/"
        const val PERSISTENT_GEOFENCE_ACTIVE_KEY_PREFIX = "persistent_geofence_active/"

        const val CALLBACK_HANDLE_KEY = "$PACKAGE_NAME.callback_handle"
        const val CALLBACK_DISPATCHER_HANDLE_KEY = "callback_dispatch_handler"

        const val ACTION_SHUTDOWN = "SHUTDOWN"

        const val WORKER_PAYLOAD_KEY = "$PACKAGE_NAME.worker_payload"
        const val GEOFENCE_CALLBACK_WORK_GROUP = "geofence_callback_work_group"

        const val RECOVERY_GENERATION_KEY = "$PACKAGE_NAME.recovery_generation"
        const val RECOVERY_SCHEDULED_GENERATION_KEY =
            "$PACKAGE_NAME.recovery_scheduled_generation"
        const val RECOVERY_SCHEDULED_ATTEMPT_KEY = "$PACKAGE_NAME.recovery_scheduled_attempt"
        const val RECOVERY_RETRY_WORK_NAME = "$PACKAGE_NAME.recovery_retry"
        const val RECOVERY_RETRY_GENERATION_INPUT_KEY = "$PACKAGE_NAME.recovery_retry_generation"
        const val RECOVERY_RETRY_ATTEMPT_INPUT_KEY = "$PACKAGE_NAME.recovery_retry_attempt"
        const val RECOVERY_RETRY_REASON_INPUT_KEY = "$PACKAGE_NAME.recovery_retry_reason"

        const val LOG_FILE_CHANNEL_NAME = "native_geofence/log_file"
        const val LOG_FILE_NAME = "native_geofence.log"
        const val LOG_FILE_ENABLED_KEY = "$PACKAGE_NAME.log_file_enabled"
        const val LOG_FILE_MAX_BYTES_KEY = "$PACKAGE_NAME.log_file_max_bytes"
        const val DEFAULT_LOG_FILE_MAX_BYTES = 256 * 1024
        const val MIN_LOG_FILE_MAX_BYTES = 16 * 1024
        const val MAX_LOG_FILE_MAX_BYTES = 50 * 1024 * 1024

        const val ISOLATE_HOLDER_WAKE_LOCK_TAG = "$PACKAGE_NAME:wake_lock"
    }
}
