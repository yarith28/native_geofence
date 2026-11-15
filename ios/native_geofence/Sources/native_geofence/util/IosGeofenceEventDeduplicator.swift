import Foundation

/// Captured at native admission, before a pending registration can change owner.
/// A present origin with a nil scope is known to be unscoped; it must not be
/// adopted by a later opted-in registration with the same ID and callbacks.
struct IosGeofenceRecoveryOrigin: Codable, Equatable {
    let scope: String?
}

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

        func matchesRecoveryRegistration(_ other: Self) -> Bool {
            id == other.id && latitude == other.latitude &&
                longitude == other.longitude && radiusMeters == other.radiusMeters &&
                triggers.map(\.rawValue).sorted() == other.triggers.map(\.rawValue).sorted()
        }
    }

    let eventId: String
    let traceId: String
    let geofence: GeofenceSnapshot
    let transition: IosGeofenceTransition
    let eventAtMillis: Int64
    var callbackHandle: Int64
    var callbackContext: Int64?
    var recoveryScope: String? = nil
    var recoveryRefreshRevision: String? = nil
    var waitingForRefresh: Bool? = nil
    var attemptCount: Int
    var nextAttemptAtMillis: Int64
    let expiresAtMillis: Int64
}

/// Durable iOS callback journal with bounded retry and terminal expiry.
final class IosGeofenceCallbackJournal {
    struct RecoveryRegistration: Codable, Equatable {
        let geofence: IosGeofenceCallbackJournalEnvelope.GeofenceSnapshot
        let scope: String
        let callbackHandle: Int64
        let callbackContext: Int64?
    }
    enum EnqueueResult: Equatable {
        case stored
        case duplicate
        case staleRecoveryOrigin
        case storageFailure
    }

    enum CompletionResult: Equatable {
        case acknowledged
        case retryScheduled(nextAttemptAtMillis: Int64)
        case retryExhausted
        case awaitingCallbackRefresh
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
        let recoveryScope: String?

        init(_ envelope: IosGeofenceCallbackJournalEnvelope) {
            geofence = envelope.geofence
            transition = envelope.transition
            eventAtMillis = envelope.eventAtMillis
            callbackHandle = envelope.callbackHandle
            callbackContext = envelope.callbackContext
            recoveryScope = envelope.recoveryScope
        }

        func belongsToSameRegistration(
            as envelope: IosGeofenceCallbackJournalEnvelope
        ) -> Bool {
            geofence == envelope.geofence
                && callbackHandle == envelope.callbackHandle
                && callbackContext == envelope.callbackContext
                && recoveryScope == envelope.recoveryScope
        }
    }

    private struct PersistedState: Codable, Equatable {
        var envelopes: [IosGeofenceCallbackJournalEnvelope]
        var deduplicationCursorsByIdentifier: [String: DeduplicationCursor]
        var recoveryRegistrations: [String: RecoveryRegistration]? = nil
    }

    /// Separate from the journal so unreadable event data cannot block a stop
    /// or later revive an opted-in callback after that stop.
    private struct RecoveryCancellation: Codable {
        var all = false
        var identifiers: [String] = []

        var isEmpty: Bool { !all && identifiers.isEmpty }
        func contains(_ id: String) -> Bool { all || identifiers.contains(id) }
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
    private var pendingRecoveryCancellation = RecoveryCancellation()
    private var recoveryCancellationStorageKey: String {
        storageKey + ".recovery-cancellation"
    }
    private var recoveryIdentifiersStorageKey: String {
        storageKey + ".recovery-identifiers"
    }

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

    func recoveryOrigin(identifier: String) -> IosGeofenceRecoveryOrigin {
        withLock { .init(scope: loadLocked()?.recoveryRegistrations?[identifier]?.scope) }
    }

    func enqueue(
        _ envelope: IosGeofenceCallbackJournalEnvelope,
        recoveryOrigin: IosGeofenceRecoveryOrigin? = nil
    ) -> EnqueueResult {
        withLock {
            guard var state = loadLocked() else { return .storageFailure }
            var envelope = envelope
            let registration = state.recoveryRegistrations?[envelope.geofence.id]
            if let recoveryOrigin {
                if let registration, registration.scope != recoveryOrigin.scope {
                    return .staleRecoveryOrigin
                }
                envelope.recoveryScope = recoveryOrigin.scope
            } else if let registration,
               registration.geofence.matchesRecoveryRegistration(envelope.geofence),
               registration.callbackHandle == envelope.callbackHandle,
               registration.callbackContext == envelope.callbackContext {
                envelope.recoveryScope = registration.scope
            }
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

    func drainBatch(nowMillis: Int64, inFlightEventIds: Set<String> = []) -> DrainBatch {
        withLock {
            guard var state = loadLocked() else {
                return DrainBatch(
                    due: [],
                    terminallyDiscardedEventIds: [],
                    nextDueAtMillis: nil,
                    storageReadable: false
                )
            }
            func isActiveScopedAttempt(_ event: IosGeofenceCallbackJournalEnvelope) -> Bool {
                event.recoveryScope != nil && inFlightEventIds.contains(event.eventId)
            }
            // A non-nil waiting flag means lookup actually failed: true waits
            // for refresh, false is its replay. Ordinary retries retain the
            // original expiry policy, including on opted-in registrations.
            func isActiveRecoveryAttempt(_ event: IosGeofenceCallbackJournalEnvelope) -> Bool {
                event.waitingForRefresh != nil && isActiveScopedAttempt(event)
            }
            let terminal = state.envelopes.filter {
                !isActiveRecoveryAttempt($0) &&
                    ($0.expiresAtMillis <= nowMillis || $0.attemptCount >= maximumAttempts)
            }
            let retained = state.envelopes.filter {
                isActiveRecoveryAttempt($0) ||
                    ($0.expiresAtMillis > nowMillis && $0.attemptCount < maximumAttempts)
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
            // Admit one scoped callback at a time so its lookup result is known
            // before a following event is delivered. An ordinary backoff does
            // not block later events; only lookup recovery establishes a barrier.
            var seen: [String: Set<String>] = [:]
            for event in retained where isActiveScopedAttempt(event) {
                if let scope = event.recoveryScope {
                    seen[scope, default: []].insert(event.geofence.id)
                }
            }
            let eligible = retained.filter { event in
                guard let scope = event.recoveryScope else { return true }
                guard !seen[scope, default: []].contains(event.geofence.id) else { return false }
                if event.waitingForRefresh != nil || event.nextAttemptAtMillis <= nowMillis {
                    seen[scope, default: []].insert(event.geofence.id)
                }
                return true
            }
            return DrainBatch(
                due: eligible.filter {
                    !isActiveScopedAttempt($0) &&
                        $0.waitingForRefresh != true && $0.nextAttemptAtMillis <= nowMillis
                },
                terminallyDiscardedEventIds: terminal.map(\.eventId).sorted(),
                nextDueAtMillis: eligible.filter {
                    !isActiveScopedAttempt($0) && $0.waitingForRefresh != true
                }
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
                  state.envelopes[index].waitingForRefresh != true,
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
        nowMillis: Int64,
        deliveredHandle: Int64? = nil,
        deliveredContext: Int64? = nil,
        deliveredRecoveryRefreshRevision: String? = nil
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
                if state.envelopes[index].recoveryScope != nil {
                    if let deliveredHandle,
                       (state.envelopes[index].callbackHandle != deliveredHandle ||
                        state.envelopes[index].callbackContext != deliveredContext ||
                        state.envelopes[index].recoveryRefreshRevision != deliveredRecoveryRefreshRevision) {
                        // A successful refresh overtook this failed attempt.
                        state.envelopes[index].waitingForRefresh = false
                        state.envelopes[index].nextAttemptAtMillis = nowMillis
                        return storeLocked(state) ? .retryScheduled(nextAttemptAtMillis: nowMillis) : .storageFailure
                    }
                    state.envelopes[index].waitingForRefresh = true
                    return storeLocked(state) ? .awaitingCallbackRefresh : .storageFailure
                }
                state.envelopes.remove(at: index)
                pruneDeduplicationCursorsLocked(
                    in: &state,
                    nowMillis: nowMillis
                )
                return storeLocked(state)
                    ? .terminallyDiscarded(reason)
                    : .storageFailure
            case .retryableFailure:
                // Callback lookup is no longer the failure being recovered.
                // Restore ordinary retry scheduling for this event and its tail.
                state.envelopes[index].waitingForRefresh = nil
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

    /// Called only after native synchronization has committed. Callback lookup
    /// failures cannot repair themselves by retrying their old handles.
    @discardableResult
    func reconcileRecovery(
        registrations: [RecoveryRegistration],
        managedIds: Set<String>,
        authoritative: Bool,
        nowMillis: Int64
    ) -> Bool {
        withLock {
            if registrations.isEmpty && !hasRecoveryLocked(managedIds: managedIds, authoritative: authoritative) {
                return true
            }
            guard var state = loadLocked() else { return false }
            let desired = Dictionary(uniqueKeysWithValues: registrations.map { ($0.geofence.id, $0) })
            var current = state.recoveryRegistrations ?? [:]
            for id in current.keys where authoritative || managedIds.contains(id) {
                current.removeValue(forKey: id)
            }
            current.merge(desired) { _, value in value }
            state.recoveryRegistrations = current
            // Raw callback handles can remain unchanged across a successful
            // refresh. Distinguish its result from an older in-flight failure.
            let refreshRevision = UUID().uuidString
            state.envelopes = state.envelopes.compactMap { original in
                guard let scope = original.recoveryScope,
                      authoritative || managedIds.contains(original.geofence.id)
                else { return original }
                guard let registration = desired[original.geofence.id],
                      registration.scope == scope,
                      registration.geofence.matchesRecoveryRegistration(original.geofence) else { return nil }
                var event = original
                event.callbackHandle = registration.callbackHandle
                event.callbackContext = registration.callbackContext
                event.recoveryRefreshRevision = refreshRevision
                if event.waitingForRefresh == true {
                    event.waitingForRefresh = false
                    event.nextAttemptAtMillis = nowMillis
                }
                return event
            }
            return storeLocked(state)
        }
    }

    @discardableResult
    func cancelRecovery(identifier: String?, deferCleanupOnFailure: Bool = false) -> Bool {
        withLock {
            guard hasRecoveryLocked(
                managedIds: identifier.map { Set([$0]) } ?? [],
                authoritative: identifier == nil
            ) else { return true }
            var cancellation = recoveryCancellationLocked()
            if let identifier {
                cancellation.identifiers = Array(Set(cancellation.identifiers + [identifier])).sorted()
            } else {
                cancellation.all = true
            }
            if var state = loadLocked() {
                removeRecoveryLocked(from: &state, cancellation: cancellation)
                if storeLocked(state) { return true }
            }
            // A failed direct replacement still leaves its old registration
            // running. Only explicit removal may defer cancellation like this.
            guard deferCleanupOnFailure else { return false }
            // Keep cancellation independent of journal decoding/writing. The
            // in-memory copy also blocks replay if this fallback write fails.
            pendingRecoveryCancellation = cancellation
            if let data = try? encoder.encode(cancellation) {
                userDefaults.set(data, forKey: recoveryCancellationStorageKey)
                if userDefaults.data(forKey: recoveryCancellationStorageKey) == data {
                    pendingRecoveryCancellation = RecoveryCancellation()
                }
            }
            return false
        }
    }

    private func recoveryCancellationLocked() -> RecoveryCancellation {
        var cancellation = pendingRecoveryCancellation
        if let data = userDefaults.data(forKey: recoveryCancellationStorageKey) {
            let saved = (try? decoder.decode(RecoveryCancellation.self, from: data))
                ?? RecoveryCancellation(all: true)
            cancellation.all = cancellation.all || saved.all
            cancellation.identifiers = Array(Set(cancellation.identifiers + saved.identifiers)).sorted()
        }
        return cancellation
    }

    private func removeRecoveryLocked(
        from state: inout PersistedState,
        cancellation: RecoveryCancellation
    ) {
        state.envelopes.removeAll {
            $0.recoveryScope != nil && cancellation.contains($0.geofence.id)
        }
        state.recoveryRegistrations = state.recoveryRegistrations?.filter {
            !cancellation.contains($0.key)
        }
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
        guard var state = readStateLocked() else { return nil }
        let cancellation = recoveryCancellationLocked()
        guard !cancellation.isEmpty else { return state }
        removeRecoveryLocked(from: &state, cancellation: cancellation)
        // The stop's normal deduplication reset may have failed with the same
        // storage error. Do not suppress the next generation's first event.
        state.deduplicationCursorsByIdentifier = state.deduplicationCursorsByIdentifier.filter {
            $0.value.recoveryScope == nil || !cancellation.contains($0.key)
        }
        // Do not expose any journal state until cancellation has been applied
        // durably. Leave legacy/unscoped entries untouched during that cleanup.
        guard storeLocked(state) else { return nil }
        userDefaults.removeObject(forKey: recoveryCancellationStorageKey)
        guard userDefaults.data(forKey: recoveryCancellationStorageKey) == nil else {
            return nil
        }
        pendingRecoveryCancellation = RecoveryCancellation()
        return state
    }

    private func readStateLocked() -> PersistedState? {
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
        let recoveryIds = Set((state.recoveryRegistrations ?? [:]).keys).union(
            state.envelopes.compactMap { $0.recoveryScope == nil ? nil : $0.geofence.id }
        )
        // Record opt-in before publishing scoped state. Legacy callers can then
        // bypass an unreadable journal without bypassing active recovery guards.
        let previousIds = recoveryIdentifiersLocked()
        if !recoveryIds.isEmpty && previousIds.map({ recoveryIds.isSubset(of: $0) }) != true {
            guard storeRecoveryIdentifiersLocked((previousIds ?? []).union(recoveryIds)) else { return false }
        }
        let stored: Bool
        if state.envelopes.isEmpty
            && state.deduplicationCursorsByIdentifier.isEmpty
            && (state.recoveryRegistrations ?? [:]).isEmpty
        {
            userDefaults.removeObject(forKey: storageKey)
            stored = userDefaults.data(forKey: storageKey) == nil
        } else {
            guard let data = try? encoder.encode(state) else { return false }
            userDefaults.set(data, forKey: storageKey)
            stored = userDefaults.data(forKey: storageKey) == data
        }
        guard stored else { return false }
        // Shrink only after journal cleanup commits. A failed index cleanup
        // leaves a conservative superset and can be retried by a later write.
        if recoveryIdentifiersLocked() != recoveryIds {
            _ = storeRecoveryIdentifiersLocked(recoveryIds)
        }
        return true
    }

    private func recoveryIdentifiersLocked() -> Set<String>? {
        guard let value = userDefaults.object(forKey: recoveryIdentifiersStorageKey) else { return [] }
        guard let identifiers = value as? [String] else { return nil }
        return Set(identifiers)
    }

    private func storeRecoveryIdentifiersLocked(_ identifiers: Set<String>) -> Bool {
        if identifiers.isEmpty {
            userDefaults.removeObject(forKey: recoveryIdentifiersStorageKey)
        } else {
            userDefaults.set(identifiers.sorted(), forKey: recoveryIdentifiersStorageKey)
        }
        return recoveryIdentifiersLocked() == identifiers
    }

    private func hasRecoveryLocked(managedIds: Set<String>, authoritative: Bool) -> Bool {
        guard let identifiers = recoveryIdentifiersLocked() else { return true }
        return authoritative ? !identifiers.isEmpty : !identifiers.isDisjoint(with: managedIds)
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
