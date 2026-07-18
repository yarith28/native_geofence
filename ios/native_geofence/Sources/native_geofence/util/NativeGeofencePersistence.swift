import Foundation

struct IosSynchronizationPersistenceSnapshot {
    let callbackMapping: Any?
    let callbackContextMapping: Any?
    let callbackPackageFingerprintMapping: Any?
    let dedupMapping: Any?
    let registrationFingerprint: Any?
    let packageFingerprint: Any?
}

enum NativeGeofenceUserDefaults {
    private static let lock = NSLock()

    static func standard() -> UserDefaults {
        let defaults = UserDefaults.standard
        migrate(defaults)
        return defaults
    }

    static func migrate(_ defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        guard !defaults.bool(forKey: Constants.USER_DEFAULTS_MIGRATION_KEY) else { return }

        var legacyKeys = Set<String>()
        for migration in Constants.LEGACY_USER_DEFAULTS_KEY_MIGRATIONS {
            legacyKeys.insert(migration.legacy)
            guard defaults.object(forKey: migration.current) == nil,
                  let legacyValue = defaults.object(forKey: migration.legacy)
            else { continue }
            defaults.set(legacyValue, forKey: migration.current)
        }

        for legacyKey in defaults.dictionaryRepresentation().keys where
            legacyKey.hasPrefix(Constants.LEGACY_DIAGNOSTIC_FACT_KEY_PREFIX)
        {
            legacyKeys.insert(legacyKey)
            let suffix = legacyKey.dropFirst(Constants.LEGACY_DIAGNOSTIC_FACT_KEY_PREFIX.count)
            let currentKey = Constants.DIAGNOSTIC_FACT_KEY_PREFIX + suffix
            guard defaults.object(forKey: currentKey) == nil,
                  let legacyValue = defaults.object(forKey: legacyKey)
            else { continue }
            defaults.set(legacyValue, forKey: currentKey)
        }

        legacyKeys.forEach(defaults.removeObject(forKey:))
        defaults.set(true, forKey: Constants.USER_DEFAULTS_MIGRATION_KEY)
    }
}

class NativeGeofencePersistence {
    private static var persistentState = NativeGeofenceUserDefaults.standard()

    @discardableResult
    static func replacePersistentStateForTesting(
        _ replacement: UserDefaults
    ) -> UserDefaults {
        let previous = persistentState
        persistentState = replacement
        return previous
    }
    
    static func setCallbackDispatcherHandle(_ handle: Int64) {
        persistentState.set(
            NSNumber(value: handle),
            forKey: Constants.CALLBACK_DISPATCHER_KEY
        )
    }
    
    static func getCallbackDispatcherHandle() -> Int64? {
        guard let handle = persistentState.value(forKey: Constants.CALLBACK_DISPATCHER_KEY) else { return nil }
        return (handle as? NSNumber)?.int64Value
    }
    
    static func setRegionCallbackHandle(id: String, handle: Int64) {
        var mapping = getRegionCallbackMapping()
        mapping[id] = NSNumber(value: handle)
        setRegionCallbackMapping(mapping)
        setRegionCallbackPackageFingerprint(
            id: id,
            fingerprint: currentPackageFingerprint()
        )
    }
    
    static func getRegionCallbackHandle(id: String) -> Int64? {
        guard let handle = getRegionCallbackMapping()[id] else { return nil }
        return (handle as? NSNumber)?.int64Value
    }

    static func hasRegionCallbackHandle(id: String) -> Bool {
        getRegionCallbackHandle(id: id) != nil
    }

    static func getRegionCallbackIds() -> Set<String> {
        Set(
            getRegionCallbackMapping().compactMap { id, handle in
                handle is NSNumber ? id : nil
            }
        )
    }
    
    static func removeRegionCallbackHandle(id: String) {
        var mapping = getRegionCallbackMapping()
        mapping.removeValue(forKey: id)
        setRegionCallbackMapping(mapping)
        var fingerprintMapping = getRegionCallbackPackageFingerprintMapping()
        fingerprintMapping.removeValue(forKey: id)
        setRegionCallbackPackageFingerprintMapping(fingerprintMapping)
    }

    static func removeAllRegionCallbackHandles() {
        setRegionCallbackMapping([:])
        setRegionCallbackPackageFingerprintMapping([:])
    }

    static func setRegionCallbackContext(id: String, context: Int64?) {
        var mapping = getRegionCallbackContextMapping()
        if let context {
            mapping[id] = NSNumber(value: context)
        } else {
            mapping.removeValue(forKey: id)
        }
        persistentState.set(
            mapping,
            forKey: Constants.GEOFENCE_CALLBACK_CONTEXT_DICT_KEY
        )
    }

    static func getRegionCallbackContext(id: String) -> Int64? {
        guard let context = getRegionCallbackContextMapping()[id] else { return nil }
        return (context as? NSNumber)?.int64Value
    }

    static func removeAllRegionCallbackContexts() {
        persistentState.set(
            [:],
            forKey: Constants.GEOFENCE_CALLBACK_CONTEXT_DICT_KEY
        )
    }

    static func getSynchronizationFingerprint() -> String? {
        persistentState.string(
            forKey: Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY
        )
    }

    @discardableResult
    static func setSynchronizationFingerprint(_ fingerprint: String) -> Bool {
        persistentState.set(
            fingerprint,
            forKey: Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY
        )
        return persistentState.synchronize()
    }

    static func getSynchronizedPackageFingerprint() -> String? {
        persistentState.string(
            forKey: Constants.SYNCHRONIZED_PACKAGE_FINGERPRINT_KEY
        )
    }

    @discardableResult
    static func setSynchronizedPackageFingerprint(_ fingerprint: String) -> Bool {
        persistentState.set(
            fingerprint,
            forKey: Constants.SYNCHRONIZED_PACKAGE_FINGERPRINT_KEY
        )
        return persistentState.synchronize()
    }

    static func setRegionCallbackPackageFingerprint(
        id: String,
        fingerprint: String
    ) {
        var mapping = getRegionCallbackPackageFingerprintMapping()
        mapping[id] = fingerprint
        setRegionCallbackPackageFingerprintMapping(mapping)
    }

    static func getRegionCallbackPackageFingerprint(id: String) -> String? {
        getRegionCallbackPackageFingerprintMapping()[id] as? String
    }

    static func callbackPackageFingerprintsCurrent(
        ids: Set<String>,
        currentFingerprint: String
    ) -> Bool {
        ids.allSatisfy {
            getRegionCallbackPackageFingerprint(id: $0) == currentFingerprint
        }
    }

    @discardableResult
    static func commitPartialSynchronization(
        ids: Set<String>,
        packageFingerprint: String
    ) -> Bool {
        var mapping = getRegionCallbackPackageFingerprintMapping()
        let callbackIds = getRegionCallbackIds()
        for id in ids.intersection(callbackIds) {
            mapping[id] = packageFingerprint
        }
        setRegionCallbackPackageFingerprintMapping(mapping)
        return persistentState.synchronize()
    }

    @discardableResult
    static func commitAuthoritativeSynchronization(
        registrationFingerprint: String,
        packageFingerprint: String
    ) -> Bool {
        let callbackIds = getRegionCallbackIds()
        setRegionCallbackPackageFingerprintMapping(
            Dictionary(uniqueKeysWithValues: callbackIds.map {
                ($0, packageFingerprint as Any)
            })
        )
        persistentState.set(
            registrationFingerprint,
            forKey: Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY
        )
        persistentState.set(
            packageFingerprint,
            forKey: Constants.SYNCHRONIZED_PACKAGE_FINGERPRINT_KEY
        )
        return persistentState.synchronize()
    }

    static func currentPackageFingerprint() -> String {
        let bundle = Bundle.main
        let identifier = bundle.bundleIdentifier ?? "unknown"
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        return "\(identifier):\(version):\(build)"
    }

    static func synchronizationSnapshot() -> IosSynchronizationPersistenceSnapshot {
        IosSynchronizationPersistenceSnapshot(
            callbackMapping: persistentState.object(
                forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
            ),
            callbackContextMapping: persistentState.object(
                forKey: Constants.GEOFENCE_CALLBACK_CONTEXT_DICT_KEY
            ),
            callbackPackageFingerprintMapping: persistentState.object(
                forKey: Constants.GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_DICT_KEY
            ),
            dedupMapping: persistentState.object(
                forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY
            ),
            registrationFingerprint: persistentState.object(
                forKey: Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY
            ),
            packageFingerprint: persistentState.object(
                forKey: Constants.SYNCHRONIZED_PACKAGE_FINGERPRINT_KEY
            )
        )
    }

    @discardableResult
    static func restoreSynchronizationSnapshot(
        _ snapshot: IosSynchronizationPersistenceSnapshot
    ) -> Bool {
        restoreObject(snapshot.callbackMapping, key: Constants.GEOFENCE_CALLBACK_DICT_KEY)
        restoreObject(
            snapshot.callbackContextMapping,
            key: Constants.GEOFENCE_CALLBACK_CONTEXT_DICT_KEY
        )
        restoreObject(
            snapshot.callbackPackageFingerprintMapping,
            key: Constants.GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_DICT_KEY
        )
        restoreObject(snapshot.dedupMapping, key: Constants.GEOFENCE_LAST_EVENT_DICT_KEY)
        restoreObject(
            snapshot.registrationFingerprint,
            key: Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY
        )
        restoreObject(
            snapshot.packageFingerprint,
            key: Constants.SYNCHRONIZED_PACKAGE_FINGERPRINT_KEY
        )
        return persistentState.synchronize()
    }
    
    private static func getRegionCallbackMapping() -> [String: Any] {
        var callbackDict = persistentState.dictionary(forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY)
        if callbackDict == nil {
            callbackDict = [:]
            persistentState.set(callbackDict, forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY)
        }
        return callbackDict!
    }
    
    private static func setRegionCallbackMapping(_ mapping: [String: Any]) {
        persistentState.set(mapping, forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY)
    }

    private static func getRegionCallbackContextMapping() -> [String: Any] {
        persistentState.dictionary(
            forKey: Constants.GEOFENCE_CALLBACK_CONTEXT_DICT_KEY
        ) ?? [:]
    }

    private static func getRegionCallbackPackageFingerprintMapping() -> [String: Any] {
        persistentState.dictionary(
            forKey: Constants.GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_DICT_KEY
        ) ?? [:]
    }

    private static func setRegionCallbackPackageFingerprintMapping(
        _ mapping: [String: Any]
    ) {
        persistentState.set(
            mapping,
            forKey: Constants.GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_DICT_KEY
        )
    }

    private static func restoreObject(_ value: Any?, key: String) {
        if let value {
            persistentState.set(value, forKey: key)
        } else {
            persistentState.removeObject(forKey: key)
        }
    }
}
