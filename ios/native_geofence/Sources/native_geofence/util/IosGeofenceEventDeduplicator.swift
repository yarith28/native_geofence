import Foundation

/// Stable persisted names, independent of generated enum ordinals.
enum IosGeofenceTransition: String, Codable {
    case enter
    case exit
    case dwell
}

/// Native delivery disposition for a journal-owned callback attempt.
///
/// Runtime availability, teardown, timeout, and ordinary Dart errors are
/// retryable. Only the two callback lookup failures emitted by the Dart bridge
/// prove that the persisted callback can no longer be invoked.
enum IosGeofenceCallbackDeliveryOutcome: Equatable {
    enum TerminalFailure: String, Equatable {
        case callbackNotFound = "callback_not_found"
        case callbackInvalid = "callback_invalid"

        static func classify(
            errorCode: String,
            details: String?,
            callbackNotFoundCode: String,
            callbackInvalidCode: String
        ) -> TerminalFailure? {
            guard details == Constants.CALLBACK_LOOKUP_TERMINAL_ERROR_MARKER else {
                return nil
            }
            switch errorCode {
            case callbackNotFoundCode:
                return .callbackNotFound
            case callbackInvalidCode:
                return .callbackInvalid
            default:
                return nil
            }
        }
    }

    case succeeded
    case retryableFailure
    case terminalFailure(TerminalFailure)

    var didSucceed: Bool {
        self == .succeeded
    }
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
        case retryScheduled(nextAttemptAtMillis: Int64)
        case retryExhausted
        case terminallyDiscarded(IosGeofenceCallbackDeliveryOutcome.TerminalFailure)
        case missing
        case storageFailure
    }

    struct DrainBatch: Equatable {
        let due: [IosGeofenceCallbackJournalEnvelope]
        let terminallyDiscardedEventIds: [String]
        let nextDueAtMillis: Int64?
        let storageReadable: Bool
    }

    private struct DeduplicationCursor: Codable, Equatable {
        let geofence: IosGeofenceCallbackJournalEnvelope.GeofenceSnapshot
        let transition: IosGeofenceTransition
        let eventAtMillis: Int64
        let callbackHandle: Int64
        let callbackContext: Int64?

        init(_ envelope: IosGeofenceCallbackJournalEnvelope) {
            geofence = envelope.geofence
            transition = envelope.transition
            eventAtMillis = envelope.eventAtMillis
            callbackHandle = envelope.callbackHandle
            callbackContext = envelope.callbackContext
        }

        func belongsToSameRegistration(
            as envelope: IosGeofenceCallbackJournalEnvelope
        ) -> Bool {
            geofence == envelope.geofence
                && callbackHandle == envelope.callbackHandle
                && callbackContext == envelope.callbackContext
        }
    }

    private struct PersistedState: Codable, Equatable {
        var envelopes: [IosGeofenceCallbackJournalEnvelope]
        var deduplicationCursorsByIdentifier: [String: DeduplicationCursor]
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
            guard var state = loadLocked() else { return .storageFailure }
            if state.envelopes.contains(where: {
                $0.eventId == envelope.eventId
            }) {
                return .duplicate
            }
            if let cursor = state.deduplicationCursorsByIdentifier[
                envelope.geofence.id
            ],
               cursor.belongsToSameRegistration(as: envelope),
               cursor.transition == envelope.transition,
               envelope.eventAtMillis >= cursor.eventAtMillis
            {
                let (age, overflow) = envelope.eventAtMillis
                    .subtractingReportingOverflow(cursor.eventAtMillis)
                if !overflow && age < pendingDuplicateWindowMillis {
                    return .duplicate
                }
            }
            state.envelopes.append(envelope)
            state.deduplicationCursorsByIdentifier[envelope.geofence.id] =
                DeduplicationCursor(envelope)
            return storeLocked(state) ? .stored : .storageFailure
        }
    }

    func drainBatch(nowMillis: Int64) -> DrainBatch {
        withLock {
            guard var state = loadLocked() else {
                return DrainBatch(
                    due: [],
                    terminallyDiscardedEventIds: [],
                    nextDueAtMillis: nil,
                    storageReadable: false
                )
            }
            let terminal = state.envelopes.filter {
                $0.expiresAtMillis <= nowMillis || $0.attemptCount >= maximumAttempts
            }
            let retained = state.envelopes.filter {
                $0.expiresAtMillis > nowMillis && $0.attemptCount < maximumAttempts
            }
            state.envelopes = retained
            let previousCursorCount =
                state.deduplicationCursorsByIdentifier.count
            pruneDeduplicationCursorsLocked(
                in: &state,
                nowMillis: nowMillis
            )
            if (!terminal.isEmpty
                || state.deduplicationCursorsByIdentifier.count
                    != previousCursorCount)
                && !storeLocked(state)
            {
                return DrainBatch(
                    due: [],
                    terminallyDiscardedEventIds: [],
                    nextDueAtMillis: nil,
                    storageReadable: false
                )
            }
            return DrainBatch(
                due: retained.filter {
                    $0.nextAttemptAtMillis <= nowMillis
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
            guard var state = loadLocked(),
                  let index = state.envelopes.firstIndex(where: {
                      $0.eventId == eventId
                  }),
                  state.envelopes[index].expiresAtMillis > nowMillis,
                  state.envelopes[index].attemptCount < maximumAttempts
            else { return nil }
            state.envelopes[index].attemptCount += 1
            state.envelopes[index].nextAttemptAtMillis = safeAdd(
                nowMillis,
                retryDelayMillis(
                    attemptCount: state.envelopes[index].attemptCount
                )
            )
            guard storeLocked(state) else { return nil }
            return state.envelopes[index]
        }
    }

    func complete(
        eventId: String,
        outcome: IosGeofenceCallbackDeliveryOutcome,
        nowMillis: Int64
    ) -> CompletionResult {
        withLock {
            guard var state = loadLocked() else { return .storageFailure }
            guard let index = state.envelopes.firstIndex(where: {
                $0.eventId == eventId
            }) else {
                return .missing
            }
            switch outcome {
            case .succeeded:
                state.envelopes.remove(at: index)
                pruneDeduplicationCursorsLocked(
                    in: &state,
                    nowMillis: nowMillis
                )
                return storeLocked(state) ? .acknowledged : .storageFailure
            case .terminalFailure(let reason):
                state.envelopes.remove(at: index)
                pruneDeduplicationCursorsLocked(
                    in: &state,
                    nowMillis: nowMillis
                )
                return storeLocked(state)
                    ? .terminallyDiscarded(reason)
                    : .storageFailure
            case .retryableFailure:
                guard state.envelopes[index].expiresAtMillis > nowMillis,
                      state.envelopes[index].attemptCount < maximumAttempts
                else {
                    state.envelopes.remove(at: index)
                    pruneDeduplicationCursorsLocked(
                        in: &state,
                        nowMillis: nowMillis
                    )
                    return storeLocked(state)
                        ? .retryExhausted
                        : .storageFailure
                }
                state.envelopes[index].nextAttemptAtMillis = safeAdd(
                    nowMillis,
                    retryDelayMillis(
                        attemptCount: state.envelopes[index].attemptCount
                    )
                )
                let nextAttemptAtMillis =
                    state.envelopes[index].nextAttemptAtMillis
                return storeLocked(state)
                    ? .retryScheduled(nextAttemptAtMillis: nextAttemptAtMillis)
                    : .storageFailure
            }
        }
    }

    func pendingCount() -> Int? {
        withLock { loadLocked()?.envelopes.count }
    }

    @discardableResult
    func resetDeduplication(identifier: String) -> Bool {
        withLock {
            guard var state = loadLocked() else { return false }
            guard state.deduplicationCursorsByIdentifier.removeValue(
                forKey: identifier
            ) != nil else {
                return true
            }
            return storeLocked(state)
        }
    }

    @discardableResult
    func resetAllDeduplication() -> Bool {
        withLock {
            guard var state = loadLocked() else { return false }
            guard !state.deduplicationCursorsByIdentifier.isEmpty else {
                return true
            }
            state.deduplicationCursorsByIdentifier.removeAll()
            return storeLocked(state)
        }
    }

    private func retryDelayMillis(attemptCount: Int) -> Int64 {
        retryDelaysMillis[min(max(0, attemptCount - 1), retryDelaysMillis.count - 1)]
    }

    private func loadLocked() -> PersistedState? {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return PersistedState(
                envelopes: [],
                deduplicationCursorsByIdentifier: [:]
            )
        }
        if let state = try? decoder.decode(PersistedState.self, from: data) {
            return state
        }
        guard let legacyEnvelopes = try? decoder.decode(
            [IosGeofenceCallbackJournalEnvelope].self,
            from: data
        ) else {
            return nil
        }
        return PersistedState(
            envelopes: legacyEnvelopes,
            deduplicationCursorsByIdentifier:
                deduplicationCursors(for: legacyEnvelopes)
        )
    }

    private func storeLocked(_ state: PersistedState) -> Bool {
        if state.envelopes.isEmpty
            && state.deduplicationCursorsByIdentifier.isEmpty
        {
            userDefaults.removeObject(forKey: storageKey)
            return userDefaults.data(forKey: storageKey) == nil
        }
        guard let data = try? encoder.encode(state) else { return false }
        userDefaults.set(data, forKey: storageKey)
        return userDefaults.data(forKey: storageKey) == data
    }

    private func deduplicationCursors(
        for envelopes: [IosGeofenceCallbackJournalEnvelope]
    ) -> [String: DeduplicationCursor] {
        var cursors: [String: DeduplicationCursor] = [:]
        for envelope in envelopes {
            cursors[envelope.geofence.id] = DeduplicationCursor(envelope)
        }
        return cursors
    }

    private func pruneDeduplicationCursorsLocked(
        in state: inout PersistedState,
        nowMillis: Int64
    ) {
        let pendingIdentifiers = Set(state.envelopes.map(\.geofence.id))
        state.deduplicationCursorsByIdentifier = state
            .deduplicationCursorsByIdentifier.filter { identifier, cursor in
                if pendingIdentifiers.contains(identifier) {
                    return true
                }
                let expiresAt = safeAdd(
                    cursor.eventAtMillis,
                    pendingDuplicateWindowMillis
                )
                return expiresAt > nowMillis
            }
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
