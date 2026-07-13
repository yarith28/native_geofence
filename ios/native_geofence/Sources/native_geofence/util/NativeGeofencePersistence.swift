import Foundation

class NativeGeofencePersistence {
    private static let persistentState: UserDefaults = .standard
    
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
    }

    static func removeAllRegionCallbackHandles() {
        setRegionCallbackMapping([:])
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
}
