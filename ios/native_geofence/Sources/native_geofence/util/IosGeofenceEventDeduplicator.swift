import Foundation

/// Stable persisted names, independent of generated enum ordinals.
enum IosGeofenceTransition: String {
    case enter
    case exit
    case dwell
}

/// Persists the last accepted iOS delivery per geofence and detects only short
/// same-direction bursts. Callers record after a delivery queue accepts work.
final class IosGeofenceEventDeduplicator {
    private enum EntryKey {
        static let transition = "event"
        static let eventAtMillis = "atMillis"
    }

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let suppressionWindowMillis: Int64

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = Constants.GEOFENCE_LAST_EVENT_DICT_KEY,
        suppressionWindowMillis: Int64 = Constants.LAST_EVENT_SUPPRESSION_TTL_MILLIS
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.suppressionWindowMillis = suppressionWindowMillis
    }

    /// Returns the age of a duplicate that should be suppressed, otherwise nil.
    func suppressedAgeMillis(
        id: String,
        transition: IosGeofenceTransition,
        eventAtMillis: Int64
    ) -> Int64? {
        guard suppressionWindowMillis > 0,
              let entry = mapping()[id] as? [String: Any],
              let storedName = entry[EntryKey.transition] as? String,
              let storedTransition = IosGeofenceTransition(rawValue: storedName),
              storedTransition == transition,
              let storedNumber = entry[EntryKey.eventAtMillis] as? NSNumber
        else {
            return nil
        }

        let storedAtMillis = storedNumber.int64Value
        // Corrupt/negative timestamps and wall-clock rollback fail open. The
        // accepted event will replace the bad baseline without risking overflow.
        guard storedAtMillis >= 0, eventAtMillis >= storedAtMillis else {
            return nil
        }
        let (ageMillis, overflow) = eventAtMillis.subtractingReportingOverflow(
            storedAtMillis
        )
        guard !overflow, ageMillis < suppressionWindowMillis else {
            return nil
        }
        return ageMillis
    }

    func recordAccepted(
        id: String,
        transition: IosGeofenceTransition,
        eventAtMillis: Int64
    ) {
        var mapping = mapping()
        mapping[id] = [
            EntryKey.transition: transition.rawValue,
            EntryKey.eventAtMillis: NSNumber(value: eventAtMillis),
        ]
        userDefaults.set(mapping, forKey: storageKey)
    }

    func remove(id: String) {
        var mapping = mapping()
        guard mapping.removeValue(forKey: id) != nil else { return }
        userDefaults.set(mapping, forKey: storageKey)
    }

    func removeAll() {
        userDefaults.set([String: Any](), forKey: storageKey)
    }

    private func mapping() -> [String: Any] {
        userDefaults.dictionary(forKey: storageKey) ?? [:]
    }
}
