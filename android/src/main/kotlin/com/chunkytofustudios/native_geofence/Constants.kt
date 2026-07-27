package com.chunkytofustudios.native_geofence

class Constants {
    companion object {
        private const val PACKAGE_NAME = "com.chunkytofustudios.native_geofence"

        const val SHARED_PREFERENCES_KEY = "native_geofence_plugin_cache"
        const val NO_BACKUP_STATE_DIRECTORY = "native_geofence"
        const val NO_BACKUP_PREFERENCES_FILE = "preferences_v1.json"
        // Kept as the raw plugin-owned ID index for backward compatibility.
        const val PERSISTENT_GEOFENCES_IDS_KEY = "persistent_geofences_ids"
        const val PERSISTENT_CONFIGURED_GEOFENCES_IDS_KEY = "persistent_configured_geofences_ids"
        const val PERSISTENT_GEOFENCE_KEY_PREFIX = "persistent_geofence/"
        const val PERSISTENT_GEOFENCE_EXPIRATION_KEY_PREFIX = "persistent_geofence_expiration/"
        const val PERSISTENT_GEOFENCE_RECOVERY_ELIGIBLE_KEY_PREFIX =
            "persistent_geofence_recovery_eligible/"
        const val PERSISTENT_GEOFENCE_ACTIVE_KEY_PREFIX = "persistent_geofence_active/"
        const val PERSISTENT_GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_KEY_PREFIX =
            "persistent_geofence_callback_package_fingerprint/"

        const val CALLBACK_HANDLE_KEY = "$PACKAGE_NAME.callback_handle"
        const val CALLBACK_DISPATCHER_HANDLE_KEY = "callback_dispatch_handler"
        const val SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY =
            "synchronization_registration_fingerprint"
        const val CALLBACK_DISPATCHER_PACKAGE_FINGERPRINT_KEY =
            "$PACKAGE_NAME.callback_dispatcher_package_fingerprint"
        const val CALLBACK_REFRESH_REQUIRED_KEY = "$PACKAGE_NAME.callback_refresh_required"
        const val CALLBACK_REFRESH_REQUIRED_IDS_KEY =
            "$PACKAGE_NAME.callback_refresh_required_ids"
        const val DEFERRED_CALLBACK_QUEUE_KEY =
            "$PACKAGE_NAME.deferred_callback_queue"

        const val ACTION_PROMOTE_FOREGROUND = "$PACKAGE_NAME.action.PROMOTE_FOREGROUND"
        const val FOREGROUND_PROMOTION_TOKEN_KEY = "$PACKAGE_NAME.foreground_promotion_token"

        const val WORKER_PAYLOAD_KEY = "$PACKAGE_NAME.worker_payload"
        const val WORKER_PAYLOAD_REFERENCE_KEY = "$PACKAGE_NAME.worker_payload_reference"
        const val WORKER_DELIVERY_ROUTE_KEY = "$PACKAGE_NAME.worker_delivery_route"
        const val WORKER_DELIVERY_SOURCE_KEY = "$PACKAGE_NAME.worker_delivery_source"
        const val WORKER_CALLBACK_REFRESH_TRANSFER_KEY =
            "$PACKAGE_NAME.worker_callback_refresh_transfer"
        const val LEGACY_WORKER_PAYLOAD_FILE_KEY = "$PACKAGE_NAME.worker_payload_file"
        const val CALLBACK_PAYLOAD_DIRECTORY = "native_geofence_callback_payloads"
        const val LEGACY_CALLBACK_PAYLOAD_DIRECTORY = "geofence_callback_payloads"
        const val GEOFENCE_CALLBACK_WORK_GROUP = "geofence_callback_work_group"
        const val CALLBACK_REFRESH_TRANSFER_WORK_PREFIX =
            "$PACKAGE_NAME.callback_refresh_transfer/"
        const val NATIVE_EVENT_PROCESSOR_METADATA_KEY =
            "$PACKAGE_NAME.native_event_processor"
        const val LEGACY_NATIVE_EVENT_PROCESSOR_METADATA_KEY =
            "$PACKAGE_NAME.BRIDGE_PROCESSOR"
        const val DIAGNOSTIC_FACT_KEY_PREFIX = "$PACKAGE_NAME.diagnostic_fact/"

        const val RECOVERY_GENERATION_KEY = "$PACKAGE_NAME.recovery_generation"
        const val RECOVERY_SCHEDULED_GENERATION_KEY =
            "$PACKAGE_NAME.recovery_scheduled_generation"
        const val RECOVERY_SCHEDULED_ATTEMPT_KEY = "$PACKAGE_NAME.recovery_scheduled_attempt"
        const val RECOVERY_PROGRESS_GENERATION_KEY =
            "$PACKAGE_NAME.recovery_progress_generation"
        const val RECOVERY_COMPLETED_IDS_KEY = "$PACKAGE_NAME.recovery_completed_ids"
        const val RECOVERY_REQUIRED_KEY = "$PACKAGE_NAME.recovery_required"
        const val RECOVERY_RETRY_WORK_NAME = "$PACKAGE_NAME.recovery_retry"
        const val RECOVERY_RETRY_GENERATION_INPUT_KEY = "$PACKAGE_NAME.recovery_retry_generation"
        const val RECOVERY_RETRY_ATTEMPT_INPUT_KEY = "$PACKAGE_NAME.recovery_retry_attempt"
        const val RECOVERY_RETRY_REASON_INPUT_KEY = "$PACKAGE_NAME.recovery_retry_reason"

        const val LOG_FILE_CHANNEL_NAME = "native_geofence/log_file"
        const val LOG_FILE_NAME = "native_geofence.log"
        const val LOG_FILE_ENABLED_KEY = "$PACKAGE_NAME.log_file_enabled"
        const val LOG_FILE_VERBOSE_KEY = "$PACKAGE_NAME.log_file_verbose"
        const val LOG_FILE_MAX_BYTES_KEY = "$PACKAGE_NAME.log_file_max_bytes"
        const val DEFAULT_LOG_FILE_VERBOSE = true
        const val DEFAULT_LOG_FILE_MAX_BYTES = 256 * 1024
        const val MIN_LOG_FILE_MAX_BYTES = 16 * 1024
        const val MAX_LOG_FILE_MAX_BYTES = 50 * 1024 * 1024

        const val ISOLATE_HOLDER_WAKE_LOCK_TAG = "$PACKAGE_NAME:wake_lock"
    }
}
