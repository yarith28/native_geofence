import Foundation

enum NativeGeofenceDiagnosticStage: String {
    case registration
    case removal
    case broadcast
    case enqueue
    case worker
    case recovery
    case foreground
}

enum NativeGeofenceDiagnostics {
    private static let lock = NSLock()
    private static let defaults = UserDefaults.standard

    static func record(
        _ stage: NativeGeofenceDiagnosticStage,
        succeeded: Bool,
        outcome: String,
        geofenceCount: Int? = nil
    ) {
        var fact: [String: Any] = [
            "occurredAtMillis": Int64(Date().timeIntervalSince1970 * 1000),
            "succeeded": succeeded,
            "outcome": sanitize(outcome),
        ]
        if let geofenceCount {
            fact["geofenceCount"] = max(0, geofenceCount)
        }
        lock.lock()
        defer { lock.unlock() }
        defaults.set(fact, forKey: Constants.DIAGNOSTIC_FACT_KEY_PREFIX + stage.rawValue)
    }

    static func fact(_ stage: NativeGeofenceDiagnosticStage) -> NativeGeofenceLifecycleFactWire? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = defaults.dictionary(
            forKey: Constants.DIAGNOSTIC_FACT_KEY_PREFIX + stage.rawValue
        ),
        let occurredAtMillis = (value["occurredAtMillis"] as? NSNumber)?.int64Value,
        let succeeded = value["succeeded"] as? Bool,
        let outcome = value["outcome"] as? String
        else {
            return nil
        }
        let count = (value["geofenceCount"] as? NSNumber)?.int64Value
        return NativeGeofenceLifecycleFactWire(
            occurredAtMillis: occurredAtMillis,
            succeeded: succeeded,
            outcome: outcome,
            geofenceCount: count
        )
    }

    private static func sanitize(_ outcome: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = outcome.lowercased().unicodeScalars.prefix(80).map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let value = String(scalars)
        return value.isEmpty ? "unknown" : value
    }
}
