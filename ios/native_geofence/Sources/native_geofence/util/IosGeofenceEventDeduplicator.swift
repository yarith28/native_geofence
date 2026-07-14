import Foundation

/// Stable persisted names, independent of generated enum ordinals.
enum IosGeofenceTransition: String {
    case enter
    case exit
    case dwell
}

/// Persists the last accepted iOS delivery per geofence and detects only short
/// same-direction bursts. Queue work rechecks and reserves immediately before
/// a runtime attempt, so accepted work suppresses later queued duplicates while
/// rejected work leaves the next candidate eligible.
final class IosGeofenceEventDeduplicator {
    struct Reservation {
        fileprivate let token: UUID
        fileprivate let id: String
        fileprivate let transition: IosGeofenceTransition
        fileprivate let eventAtMillis: Int64
    }

    enum ReservationResult {
        case reserved(Reservation)
        case suppressed(ageMillis: Int64)
    }

    final class Admission {
        enum Decision {
            case admitted
            case suppressed(ageMillis: Int64)
            case unavailable
        }

        private enum State {
            case pending
            case reserved(Reservation)
            case resolved
        }

        private let lock = NSLock()
        private let deduplicator: IosGeofenceEventDeduplicator
        private let id: String
        private let transition: IosGeofenceTransition
        private let eventAtMillis: Int64
        private var state = State.pending

        fileprivate init(
            deduplicator: IosGeofenceEventDeduplicator,
            id: String,
            transition: IosGeofenceTransition,
            eventAtMillis: Int64
        ) {
            self.deduplicator = deduplicator
            self.id = id
            self.transition = transition
            self.eventAtMillis = eventAtMillis
        }

        func attempt() -> Decision {
            withLock {
                guard case .pending = state else { return .unavailable }
                switch deduplicator.reserve(
                    id: id,
                    transition: transition,
                    eventAtMillis: eventAtMillis
                ) {
                case .reserved(let reservation):
                    state = .reserved(reservation)
                    return .admitted
                case .suppressed(let ageMillis):
                    state = .resolved
                    return .suppressed(ageMillis: ageMillis)
                }
            }
        }

        func commit() {
            guard let reservation = takeReservation() else { return }
            deduplicator.commit(reservation)
        }

        func cancel() {
            guard let reservation = takeReservation() else { return }
            deduplicator.cancel(reservation)
        }

        private func takeReservation() -> Reservation? {
            withLock {
                guard case .reserved(let reservation) = state else {
                    state = .resolved
                    return nil
                }
                state = .resolved
                return reservation
            }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private enum EntryKey {
        static let transition = "event"
        static let eventAtMillis = "atMillis"
    }

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let storageKey: String
    private let suppressionWindowMillis: Int64
    private var pendingById: [String: [Reservation]] = [:]

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = Constants.GEOFENCE_LAST_EVENT_DICT_KEY,
        suppressionWindowMillis: Int64 = Constants.LAST_EVENT_SUPPRESSION_TTL_MILLIS
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.suppressionWindowMillis = suppressionWindowMillis
    }

    func admission(
        id: String,
        transition: IosGeofenceTransition,
        eventAtMillis: Int64
    ) -> Admission {
        Admission(
            deduplicator: self,
            id: id,
            transition: transition,
            eventAtMillis: eventAtMillis
        )
    }

    /// Returns the age of a duplicate that should be suppressed, otherwise nil.
    func suppressedAgeMillis(
        id: String,
        transition: IosGeofenceTransition,
        eventAtMillis: Int64
    ) -> Int64? {
        withLock {
            suppressedAgeMillisLocked(
                id: id,
                transition: transition,
                eventAtMillis: eventAtMillis
            )
        }
    }

    func reserve(
        id: String,
        transition: IosGeofenceTransition,
        eventAtMillis: Int64
    ) -> ReservationResult {
        withLock {
            if let ageMillis = suppressedAgeMillisLocked(
                id: id,
                transition: transition,
                eventAtMillis: eventAtMillis
            ) {
                return .suppressed(ageMillis: ageMillis)
            }
            let reservation = Reservation(
                token: UUID(),
                id: id,
                transition: transition,
                eventAtMillis: eventAtMillis
            )
            pendingById[id, default: []].append(reservation)
            return .reserved(reservation)
        }
    }

    func commit(_ reservation: Reservation) {
        withLock {
            guard removePendingLocked(reservation) else { return }
            recordAcceptedLocked(
                id: reservation.id,
                transition: reservation.transition,
                eventAtMillis: reservation.eventAtMillis
            )
        }
    }

    func cancel(_ reservation: Reservation) {
        withLock {
            _ = removePendingLocked(reservation)
        }
    }

    func recordAccepted(
        id: String,
        transition: IosGeofenceTransition,
        eventAtMillis: Int64
    ) {
        withLock {
            recordAcceptedLocked(
                id: id,
                transition: transition,
                eventAtMillis: eventAtMillis
            )
        }
    }

    func remove(id: String) {
        withLock {
            pendingById.removeValue(forKey: id)
            var mapping = mappingLocked()
            guard mapping.removeValue(forKey: id) != nil else { return }
            userDefaults.set(mapping, forKey: storageKey)
        }
    }

    func removeAll() {
        withLock {
            pendingById.removeAll()
            userDefaults.set([String: Any](), forKey: storageKey)
        }
    }

    private func suppressedAgeMillisLocked(
        id: String,
        transition: IosGeofenceTransition,
        eventAtMillis: Int64
    ) -> Int64? {
        let baseline: (IosGeofenceTransition, Int64)?
        if let pending = pendingById[id]?.last {
            baseline = (pending.transition, pending.eventAtMillis)
        } else if let entry = mappingLocked()[id] as? [String: Any],
                  let storedName = entry[EntryKey.transition] as? String,
                  let storedTransition = IosGeofenceTransition(rawValue: storedName),
                  let storedNumber = entry[EntryKey.eventAtMillis] as? NSNumber
        {
            baseline = (storedTransition, storedNumber.int64Value)
        } else {
            baseline = nil
        }

        guard suppressionWindowMillis > 0,
              let (baselineTransition, baselineAtMillis) = baseline,
              baselineTransition == transition,
              baselineAtMillis >= 0,
              eventAtMillis >= baselineAtMillis
        else {
            return nil
        }
        // Corrupt/negative timestamps and wall-clock rollback fail open. The
        // admitted event will replace the bad baseline without risking overflow.
        let (ageMillis, overflow) = eventAtMillis.subtractingReportingOverflow(
            baselineAtMillis
        )
        guard !overflow, ageMillis < suppressionWindowMillis else { return nil }
        return ageMillis
    }

    private func recordAcceptedLocked(
        id: String,
        transition: IosGeofenceTransition,
        eventAtMillis: Int64
    ) {
        var mapping = mappingLocked()
        mapping[id] = [
            EntryKey.transition: transition.rawValue,
            EntryKey.eventAtMillis: NSNumber(value: eventAtMillis),
        ]
        userDefaults.set(mapping, forKey: storageKey)
    }

    private func removePendingLocked(_ reservation: Reservation) -> Bool {
        guard var pending = pendingById[reservation.id],
              let index = pending.firstIndex(where: { $0.token == reservation.token })
        else {
            return false
        }
        pending.remove(at: index)
        if pending.isEmpty {
            pendingById.removeValue(forKey: reservation.id)
        } else {
            pendingById[reservation.id] = pending
        }
        return true
    }

    private func mappingLocked() -> [String: Any] {
        userDefaults.dictionary(forKey: storageKey) ?? [:]
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
