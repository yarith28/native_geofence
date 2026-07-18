import Foundation

/// Stable persisted names, independent of generated enum ordinals.
enum IosGeofenceTransition: String, Codable {
    case enter
    case exit
    case dwell
}

/// Codable, versioned payload retained before any Flutter runtime is touched.
/// The event ID remains stable across retries so Dart can enforce idempotency.
struct IosGeofenceCallbackJournalEnvelope: Codable, Equatable {
    struct GeofenceSnapshot: Codable, Equatable {
        let id: String
        let latitude: Double
        let longitude: Double
        let radiusMeters: Double
        let triggers: [IosGeofenceTransition]
    }

    let eventId: String
    let traceId: String
    let geofence: GeofenceSnapshot
    let transition: IosGeofenceTransition
    let eventAtMillis: Int64
    let callbackHandle: Int64
    let callbackContext: Int64?
    var attemptCount: Int
    var nextAttemptAtMillis: Int64
    let expiresAtMillis: Int64
}

/// Durable iOS callback journal with bounded retry and terminal expiry.
final class IosGeofenceCallbackJournal {
    enum EnqueueResult: Equatable {
        case stored
        case duplicate
        case storageFailure
    }

    enum CompletionResult: Equatable {
        case acknowledged
        case retryAfter(milliseconds: Int64)
        case terminallyDiscarded
        case missing
        case storageFailure
    }

    struct DrainBatch: Equatable {
        let due: [IosGeofenceCallbackJournalEnvelope]
        let terminallyDiscardedEventIds: [String]
        let nextDueAtMillis: Int64?
        let storageReadable: Bool
    }

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let storageKey: String
    private let eventTimeToLiveMillis: Int64
    private let pendingDuplicateWindowMillis: Int64
    private let maximumAttempts: Int
    private let retryDelaysMillis: [Int64]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = NativeGeofenceUserDefaults.standard(),
        storageKey: String = Constants.GEOFENCE_CALLBACK_JOURNAL_KEY,
        eventTimeToLiveMillis: Int64 = 24 * 60 * 60 * 1000,
        pendingDuplicateWindowMillis: Int64 = Constants.LAST_EVENT_SUPPRESSION_TTL_MILLIS,
        maximumAttempts: Int = 8,
        retryDelaysMillis: [Int64] = [
            1_000,
            5_000,
            30_000,
            5 * 60 * 1000,
            30 * 60 * 1000,
            60 * 60 * 1000,
        ]
    ) {
        precondition(eventTimeToLiveMillis > 0)
        precondition(pendingDuplicateWindowMillis >= 0)
        precondition(maximumAttempts > 0)
        precondition(!retryDelaysMillis.isEmpty && retryDelaysMillis.allSatisfy { $0 > 0 })
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.eventTimeToLiveMillis = eventTimeToLiveMillis
        self.pendingDuplicateWindowMillis = pendingDuplicateWindowMillis
        self.maximumAttempts = maximumAttempts
        self.retryDelaysMillis = retryDelaysMillis
        encoder.outputFormatting = [.sortedKeys]
    }

    func makeEnvelope(
        eventId: String,
        traceId: String,
        geofence: IosGeofenceCallbackJournalEnvelope.GeofenceSnapshot,
        transition: IosGeofenceTransition,
        eventAtMillis: Int64,
        callbackHandle: Int64,
        callbackContext: Int64?,
        nowMillis: Int64
    ) -> IosGeofenceCallbackJournalEnvelope {
        IosGeofenceCallbackJournalEnvelope(
            eventId: eventId,
            traceId: traceId,
            geofence: geofence,
            transition: transition,
            eventAtMillis: eventAtMillis,
            callbackHandle: callbackHandle,
            callbackContext: callbackContext,
            attemptCount: 0,
            nextAttemptAtMillis: nowMillis,
            expiresAtMillis: safeAdd(nowMillis, eventTimeToLiveMillis)
        )
    }

    func enqueue(_ envelope: IosGeofenceCallbackJournalEnvelope) -> EnqueueResult {
        withLock {
            guard var envelopes = loadLocked() else { return .storageFailure }
            if envelopes.contains(where: { $0.eventId == envelope.eventId }) {
                return .duplicate
            }
            if envelopes.contains(where: { pending in
                guard pending.geofence.id == envelope.geofence.id,
                      pending.transition == envelope.transition,
                      envelope.eventAtMillis >= pending.eventAtMillis
                else { return false }
                let (age, overflow) = envelope.eventAtMillis
                    .subtractingReportingOverflow(pending.eventAtMillis)
                return !overflow && age < pendingDuplicateWindowMillis
            }) {
                return .duplicate
            }
            envelopes.append(envelope)
            return storeLocked(envelopes) ? .stored : .storageFailure
        }
    }

    func drainBatch(nowMillis: Int64) -> DrainBatch {
        withLock {
            guard let envelopes = loadLocked() else {
                return DrainBatch(
                    due: [],
                    terminallyDiscardedEventIds: [],
                    nextDueAtMillis: nil,
                    storageReadable: false
                )
            }
            let terminal = envelopes.filter {
                $0.expiresAtMillis <= nowMillis || $0.attemptCount >= maximumAttempts
            }
            let retained = envelopes.filter {
                $0.expiresAtMillis > nowMillis && $0.attemptCount < maximumAttempts
            }
            if !terminal.isEmpty && !storeLocked(retained) {
                return DrainBatch(
                    due: [],
                    terminallyDiscardedEventIds: [],
                    nextDueAtMillis: nil,
                    storageReadable: false
                )
            }
            return DrainBatch(
                due: retained
                    .filter { $0.nextAttemptAtMillis <= nowMillis }
                    .sorted {
                        if $0.eventAtMillis == $1.eventAtMillis {
                            return $0.eventId < $1.eventId
                        }
                        return $0.eventAtMillis < $1.eventAtMillis
                    },
                terminallyDiscardedEventIds: terminal.map(\.eventId).sorted(),
                nextDueAtMillis: retained
                    .map(\.nextAttemptAtMillis)
                    .filter { $0 > nowMillis }
                    .min(),
                storageReadable: true
            )
        }
    }

    func beginAttempt(
        eventId: String,
        nowMillis: Int64
    ) -> IosGeofenceCallbackJournalEnvelope? {
        withLock {
            guard var envelopes = loadLocked(),
                  let index = envelopes.firstIndex(where: { $0.eventId == eventId }),
                  envelopes[index].expiresAtMillis > nowMillis,
                  envelopes[index].attemptCount < maximumAttempts
            else { return nil }
            envelopes[index].attemptCount += 1
            envelopes[index].nextAttemptAtMillis = safeAdd(
                nowMillis,
                retryDelayMillis(attemptCount: envelopes[index].attemptCount)
            )
            guard storeLocked(envelopes) else { return nil }
            return envelopes[index]
        }
    }

    func complete(
        eventId: String,
        succeeded: Bool,
        nowMillis: Int64
    ) -> CompletionResult {
        withLock {
            guard var envelopes = loadLocked() else { return .storageFailure }
            guard let index = envelopes.firstIndex(where: { $0.eventId == eventId }) else {
                return .missing
            }
            if succeeded {
                envelopes.remove(at: index)
                return storeLocked(envelopes) ? .acknowledged : .storageFailure
            }
            let envelope = envelopes[index]
            if envelope.expiresAtMillis <= nowMillis || envelope.attemptCount >= maximumAttempts {
                envelopes.remove(at: index)
                return storeLocked(envelopes) ? .terminallyDiscarded : .storageFailure
            }
            return .retryAfter(
                milliseconds: max(0, envelope.nextAttemptAtMillis - nowMillis)
            )
        }
    }

    func pendingCount() -> Int? {
        withLock { loadLocked()?.count }
    }

    private func retryDelayMillis(attemptCount: Int) -> Int64 {
        retryDelaysMillis[min(max(0, attemptCount - 1), retryDelaysMillis.count - 1)]
    }

    private func loadLocked() -> [IosGeofenceCallbackJournalEnvelope]? {
        guard let data = userDefaults.data(forKey: storageKey) else { return [] }
        return try? decoder.decode([IosGeofenceCallbackJournalEnvelope].self, from: data)
    }

    private func storeLocked(_ envelopes: [IosGeofenceCallbackJournalEnvelope]) -> Bool {
        if envelopes.isEmpty {
            userDefaults.removeObject(forKey: storageKey)
            return userDefaults.data(forKey: storageKey) == nil
        }
        guard let data = try? encoder.encode(envelopes) else { return false }
        userDefaults.set(data, forKey: storageKey)
        return userDefaults.data(forKey: storageKey) == data
    }

    private func safeAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : sum
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
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
        userDefaults: UserDefaults = NativeGeofenceUserDefaults.standard(),
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
