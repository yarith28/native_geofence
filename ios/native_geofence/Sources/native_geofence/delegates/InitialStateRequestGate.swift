import CoreLocation
import Foundation

enum InitialStateBoundaryEventRejectionReason: String, Equatable {
    case unsupportedRegionType = "unsupported_region_type"
    case privateInitialStateProbe = "private_initial_state_probe"
    case unknownIdentifier = "unknown_identifier"
}

enum InitialStateBoundaryEventAcceptanceReason: String, Equatable {
    case monitoringSemanticsMatch = "committed_identifier_semantics_match"
    case monitoringSemanticsMismatch = "committed_identifier_semantics_mismatch"
}

enum InitialStateBoundaryEventDecision {
    case accepted(
        CLCircularRegion,
        reason: InitialStateBoundaryEventAcceptanceReason
    )
    case rejected(InitialStateBoundaryEventRejectionReason)
}

enum PendingBoundaryTransition: String, Codable, Equatable {
    case enter
    case exit
}

struct PendingBoundaryRegionSnapshot: Codable, Equatable {
    let identifier: String
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees
    let radius: CLLocationDistance
    let notifyOnEntry: Bool
    let notifyOnExit: Bool

    init(region: CLCircularRegion) {
        identifier = region.identifier
        latitude = region.center.latitude
        longitude = region.center.longitude
        radius = region.radius
        notifyOnEntry = region.notifyOnEntry
        notifyOnExit = region.notifyOnExit
    }

    var region: CLCircularRegion {
        let value = CLCircularRegion(
            center: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: longitude
            ),
            radius: radius,
            identifier: identifier
        )
        value.notifyOnEntry = notifyOnEntry
        value.notifyOnExit = notifyOnExit
        return value
    }
}

struct PendingBoundaryRegistrationCandidate: Codable, Equatable {
    let regionSnapshot: PendingBoundaryRegionSnapshot
    let callbackHandle: Int64
    let callbackContext: Int64?

    init(
        region: CLCircularRegion,
        callbackHandle: Int64,
        callbackContext: Int64?
    ) {
        regionSnapshot = PendingBoundaryRegionSnapshot(region: region)
        self.callbackHandle = callbackHandle
        self.callbackContext = callbackContext
    }

    var region: CLCircularRegion {
        regionSnapshot.region
    }
}

enum PendingBoundaryRegistrationWinnerResolver {
    static func uniqueCandidates(
        _ candidates: [PendingBoundaryRegistrationCandidate]
    ) -> [PendingBoundaryRegistrationCandidate] {
        candidates.reduce(into: []) { unique, candidate in
            if !unique.contains(candidate) {
                unique.append(candidate)
            }
        }
    }

    static func select(
        from candidates: [PendingBoundaryRegistrationCandidate],
        committedRegion: CLCircularRegion,
        currentCallbackHandle: Int64?,
        currentCallbackContext: Int64?
    ) -> PendingBoundaryRegistrationCandidate? {
        let candidates = uniqueCandidates(candidates)
        let matching = candidates.filter {
            RegionMonitoringSemantics.matches($0.region, committedRegion)
        }
        guard !matching.isEmpty else { return nil }
        if let exact = matching.last(where: {
            $0.callbackHandle == currentCallbackHandle
                && $0.callbackContext == currentCallbackContext
        }) {
            return exact
        }
        if currentCallbackHandle == nil, candidates.count == 1 {
            return matching.last
        }
        // An interrupted commit is proven only when the currently persisted
        // metadata still describes another candidate in this same mutation.
        // Otherwise this may be a canceled event from an older same-ID
        // generation and must not claim the current registration.
        guard candidates.contains(where: {
            $0.callbackHandle == currentCallbackHandle
                && $0.callbackContext == currentCallbackContext
        }) else {
            return nil
        }
        return matching.last
    }
}

struct PendingBoundarySynchronizationAuthority {
    let region: CLCircularRegion
    let winnerCandidate: PendingBoundaryRegistrationCandidate?
    let resetsDeduplication: Bool
}

struct PendingBoundarySynchronizationRollbackPlan {
    let authorities: [PendingBoundarySynchronizationAuthority]
    let incoherentIdentifiers: [String]
}

enum PendingBoundarySynchronizationRollbackPlanner {
    static func makePlan(
        monitoredRegions: [CLCircularRegion],
        authorityTouchedIdentifiers: Set<String>,
        candidatesByIdentifier:
            [String: [PendingBoundaryRegistrationCandidate]],
        getCallbackHandle: (String) -> Int64?,
        getCallbackContext: (String) -> Int64?
    ) -> PendingBoundarySynchronizationRollbackPlan {
        var authorities: [PendingBoundarySynchronizationAuthority] = []
        var incoherentIdentifiers: [String] = []
        for region in monitoredRegions {
            guard authorityTouchedIdentifiers.contains(region.identifier),
                  let candidates = candidatesByIdentifier[region.identifier]
            else {
                authorities.append(
                    PendingBoundarySynchronizationAuthority(
                        region: region,
                        winnerCandidate: nil,
                        resetsDeduplication: false
                    )
                )
                continue
            }
            let currentCallbackHandle = getCallbackHandle(region.identifier)
            let currentCallbackContext = getCallbackContext(region.identifier)
            guard let winner =
                PendingBoundaryRegistrationWinnerResolver.select(
                    from: candidates,
                    committedRegion: region,
                    currentCallbackHandle: currentCallbackHandle,
                    currentCallbackContext: currentCallbackContext
                )
            else {
                incoherentIdentifiers.append(region.identifier)
                continue
            }
            authorities.append(
                PendingBoundarySynchronizationAuthority(
                    region: region,
                    winnerCandidate: winner,
                    resetsDeduplication:
                        winner.callbackHandle != currentCallbackHandle
                        || winner.callbackContext != currentCallbackContext
                )
            )
        }
        return PendingBoundarySynchronizationRollbackPlan(
            authorities: authorities,
            incoherentIdentifiers: incoherentIdentifiers.sorted()
        )
    }
}

struct PendingBoundaryEvent: Codable, Equatable {
    let eventId: String
    let sequence: Int64
    let transition: PendingBoundaryTransition
    let responseRegionSnapshot: PendingBoundaryRegionSnapshot
    let receivedAtMillis: Int64
    let resolutionCandidates: [PendingBoundaryRegistrationCandidate]
    var resolvedRegistrationCandidate:
        PendingBoundaryRegistrationCandidate? = nil

    var responseRegion: CLCircularRegion {
        responseRegionSnapshot.region
    }
}

enum PendingBoundaryEventCancellationResult: Equatable {
    case completed
    case cleanupPending(eventIds: Set<String>)
    case persistenceFailure(eventIds: Set<String>)

    var retryEventIds: Set<String> {
        switch self {
        case .completed:
            return []
        case .cleanupPending(let eventIds),
             .persistenceFailure(let eventIds):
            return eventIds
        }
    }

    var establishedDurableCancellation: Bool {
        switch self {
        case .completed, .cleanupPending:
            return true
        case .persistenceFailure:
            return false
        }
    }
}

struct PendingBoundaryEventRecoveryPlan {
    let winnerCandidate: PendingBoundaryRegistrationCandidate
    let resetsDeduplication: Bool
}

/// Resolves relaunch recovery using the same durable candidate evidence that
/// was captured when Core Location delivered the callback.
enum PendingBoundaryEventRecoveryPlanner {
    static func makePlan(
        events: [PendingBoundaryEvent],
        committedRegion: CLCircularRegion,
        currentCallbackHandle: Int64?,
        currentCallbackContext: Int64?
    ) -> PendingBoundaryEventRecoveryPlan? {
        guard let winner =
            PendingBoundaryRegistrationWinnerResolver.select(
                from: events.flatMap(\.resolutionCandidates),
                committedRegion: committedRegion,
                currentCallbackHandle: currentCallbackHandle,
                currentCallbackContext: currentCallbackContext
            )
        else {
            return nil
        }
        return PendingBoundaryEventRecoveryPlan(
            winnerCandidate: winner,
            resetsDeduplication:
                winner.callbackHandle != currentCallbackHandle
                || winner.callbackContext != currentCallbackContext
        )
    }
}

/// Persists boundary callbacks before winner-dependent metadata is known.
///
/// Stable event IDs make the handoff to the callback journal crash-idempotent,
/// while a persisted sequence preserves identifier-scoped FIFO even when
/// multiple callbacks share the same wall-clock millisecond.
final class PendingBoundaryEventBuffer {
    private struct PersistedState: Codable {
        let revision: Int64?
        let events: [PendingBoundaryEvent]
        let cancelledEventIds: [String]

        var effectiveRevision: Int64 {
            revision ?? 0
        }
    }

    struct AppendResult {
        let event: PendingBoundaryEvent
        let persisted: Bool
    }

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let storageKey: String
    private let fallbackStorageURL: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var events: [PendingBoundaryEvent]
    private var cancelledEventIds: Set<String>
    private var revision: Int64

    init(
        userDefaults: UserDefaults = NativeGeofenceUserDefaults.standard(),
        storageKey: String = Constants.GEOFENCE_PENDING_BOUNDARY_EVENTS_KEY,
        fallbackStorageURL: URL? = nil
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.fallbackStorageURL = fallbackStorageURL
            ?? (
                storageKey == Constants.GEOFENCE_PENDING_BOUNDARY_EVENTS_KEY
                    ? Self.defaultFallbackStorageURL()
                    : nil
            )
        let primaryState = Self.decodeState(
            userDefaults.data(forKey: storageKey),
            decoder: decoder
        )
        let fallbackState = Self.decodeState(
            self.fallbackStorageURL.flatMap {
                try? Data(contentsOf: $0)
            },
            decoder: decoder
        )
        let state: PersistedState?
        switch (primaryState, fallbackState) {
        case (.some(let primary), .some(let fallback)):
            state = fallback.effectiveRevision > primary.effectiveRevision
                ? fallback
                : primary
        case (.some(let primary), .none):
            state = primary
        case (.none, .some(let fallback)):
            state = fallback
        case (.none, .none):
            state = nil
        }
        if let state {
            events = state.events
            cancelledEventIds = Set(state.cancelledEventIds)
            revision = state.effectiveRevision
        } else {
            events = []
            cancelledEventIds = []
            revision = 0
        }
        encoder.outputFormatting = [.sortedKeys]
    }

    @discardableResult
    func append(
        _ transition: PendingBoundaryTransition,
        responseRegion: CLCircularRegion,
        receivedAtMillis: Int64,
        resolutionCandidates: [PendingBoundaryRegistrationCandidate]
    ) -> AppendResult {
        withLock {
            let nextSequence = events.map(\.sequence).max().map {
                $0 == Int64.max ? Int64.max : $0 + 1
            } ?? 0
            let event = PendingBoundaryEvent(
                eventId: UUID().uuidString,
                sequence: nextSequence,
                transition: transition,
                responseRegionSnapshot: PendingBoundaryRegionSnapshot(
                    region: responseRegion
                ),
                receivedAtMillis: receivedAtMillis,
                resolutionCandidates: resolutionCandidates
            )
            events.append(event)
            return AppendResult(event: event, persisted: storeLocked())
        }
    }

    func pending(identifier: String) -> [PendingBoundaryEvent] {
        withLock {
            events
                .filter {
                    !cancelledEventIds.contains($0.eventId)
                        && $0.responseRegionSnapshot.identifier == identifier
                }
                .sorted { $0.sequence < $1.sequence }
        }
    }

    func pendingIdentifiers() -> [String] {
        withLock {
            Array(
                Set(
                    events
                        .filter {
                            !cancelledEventIds.contains($0.eventId)
                        }
                        .map(\.responseRegionSnapshot.identifier)
                )
            ).sorted()
        }
    }

    func pendingCancellationEventIds() -> Set<String> {
        withLock { cancelledEventIds }
    }

    @discardableResult
    func retryPersistence() -> Bool {
        withLock { storeLocked() }
    }

    @discardableResult
    func pinResolvedCandidates(
        _ candidatesByEventId:
            [String: PendingBoundaryRegistrationCandidate]
    ) -> Bool {
        withLock {
            guard !candidatesByEventId.isEmpty else { return true }
            var replacement = events
            var changed = false
            for index in replacement.indices {
                guard let candidate = candidatesByEventId[
                    replacement[index].eventId
                ] else {
                    continue
                }
                if let existing =
                    replacement[index].resolvedRegistrationCandidate
                {
                    guard existing == candidate else { return false }
                    continue
                }
                replacement[index].resolvedRegistrationCandidate = candidate
                changed = true
            }
            guard changed else { return true }
            return replaceEventsLocked(with: replacement)
        }
    }

    /// Fail-closed cancellation. The tombstone is committed before raw event
    /// deletion so a failed cleanup or process death cannot revive delivery.
    @discardableResult
    func cancel(
        eventIds: Set<String>
    ) -> PendingBoundaryEventCancellationResult {
        withLock {
            let trackedEventIds = Set(events.map(\.eventId))
                .union(cancelledEventIds)
            let eventIds = eventIds.intersection(trackedEventIds)
            guard !eventIds.isEmpty else { return .completed }

            let previousCancelledEventIds = cancelledEventIds
            cancelledEventIds.formUnion(eventIds)
            guard storeLocked() else {
                // No durable cancellation authority was established. Restore
                // visibility so callers can abort removal without silently
                // swallowing an event that still belongs to the live region.
                cancelledEventIds = previousCancelledEventIds
                return .persistenceFailure(eventIds: eventIds)
            }

            let tombstonedEvents = events
            let tombstonedEventIds = cancelledEventIds
            events.removeAll { eventIds.contains($0.eventId) }
            cancelledEventIds.subtract(eventIds)
            guard storeLocked() else {
                events = tombstonedEvents
                cancelledEventIds = tombstonedEventIds
                return .cleanupPending(eventIds: eventIds)
            }
            return .completed
        }
    }

    @discardableResult
    func remove(eventId: String) -> Bool {
        remove(eventIds: [eventId])
    }

    @discardableResult
    func remove(eventIds: Set<String>) -> Bool {
        withLock {
            guard !eventIds.isEmpty else { return true }
            return replaceEventsLocked(
                with: events.filter { !eventIds.contains($0.eventId) }
            )
        }
    }

    @discardableResult
    func remove(identifier: String) -> Bool {
        withLock {
            replaceEventsLocked(
                with: events.filter {
                    $0.responseRegionSnapshot.identifier != identifier
                }
            )
        }
    }

    @discardableResult
    func removeAll() -> Bool {
        withLock {
            replaceEventsLocked(with: [])
        }
    }

    private func replaceEventsLocked(
        with replacement: [PendingBoundaryEvent]
    ) -> Bool {
        guard replacement != events else { return true }
        let previous = events
        events = replacement
        guard storeLocked() else {
            events = previous
            return false
        }
        return true
    }

    private func storeLocked() -> Bool {
        let nextRevision =
            revision == Int64.max ? Int64.max : revision + 1
        let state = PersistedState(
            revision: nextRevision,
            events: events,
            cancelledEventIds: cancelledEventIds.sorted()
        )
        guard let data = try? encoder.encode(state) else { return false }
        userDefaults.set(data, forKey: storageKey)
        if userDefaults.synchronize(),
           userDefaults.data(forKey: storageKey) == data
        {
            revision = nextRevision
            removeFallbackStorage()
            return true
        }
        guard storeFallback(data) else { return false }
        revision = nextRevision
        return true
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func storeFallback(_ data: Data) -> Bool {
        guard let fallbackStorageURL else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fallbackStorageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fallbackStorageURL, options: .atomic)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var storedURL = fallbackStorageURL
            try? storedURL.setResourceValues(resourceValues)
            return try Data(contentsOf: fallbackStorageURL) == data
        } catch {
            return false
        }
    }

    private func removeFallbackStorage() {
        guard let fallbackStorageURL else { return }
        try? FileManager.default.removeItem(at: fallbackStorageURL)
    }

    private static func decodeState(
        _ data: Data?,
        decoder: JSONDecoder
    ) -> PersistedState? {
        guard let data else { return nil }
        if let state = try? decoder.decode(PersistedState.self, from: data) {
            return state
        }
        guard let legacyEvents = try? decoder.decode(
            [PendingBoundaryEvent].self,
            from: data
        ) else {
            return nil
        }
        return PersistedState(
            revision: nil,
            events: legacyEvents,
            cancelledEventIds: []
        )
    }

    private static func defaultFallbackStorageURL() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent(Constants.PACKAGE_NAME, isDirectory: true)
            .appendingPathComponent(
                "pending-boundary-events-v1.json",
                isDirectory: false
            )
    }
}

enum PendingBoundaryEventAdmissionDecision {
    case accepted(
        CLCircularRegion,
        receivedAtMillis: Int64,
        reason: InitialStateBoundaryEventAcceptanceReason
    )
    case deferred(persisted: Bool)
    case rejected(InitialStateBoundaryEventRejectionReason)
}

/// Production admission coordinator shared by the CLLocationManager delegate
/// and standalone tests. It checks mutation ownership before committed gate
/// authority so new registrations and rollback restorations can defer safely.
final class PendingBoundaryEventAdmissionCoordinator {
    typealias PendingMutationLookup = (String) -> Bool
    typealias CandidateLookup =
        (String) -> [PendingBoundaryRegistrationCandidate]

    private let lock = NSLock()
    private let gate: InitialStateRequestGate
    private let buffer: PendingBoundaryEventBuffer
    private let hasPendingMutation: PendingMutationLookup
    private let pendingCandidates: CandidateLookup
    private var synchronizationCandidatesByIdentifier:
        [String: [PendingBoundaryRegistrationCandidate]] = [:]

    init(
        gate: InitialStateRequestGate,
        buffer: PendingBoundaryEventBuffer,
        hasPendingMutation: @escaping PendingMutationLookup,
        pendingCandidates: @escaping CandidateLookup
    ) {
        self.gate = gate
        self.buffer = buffer
        self.hasPendingMutation = hasPendingMutation
        self.pendingCandidates = pendingCandidates
    }

    func beginSynchronization(
        identifier: String,
        candidates: [PendingBoundaryRegistrationCandidate]
    ) {
        withLock {
            synchronizationCandidatesByIdentifier[identifier] = candidates
        }
    }

    func finishSynchronization(identifier: String) {
        _ = withLock {
            synchronizationCandidatesByIdentifier.removeValue(
                forKey: identifier
            )
        }
    }

    @discardableResult
    func cancel(
        identifier: String
    ) -> PendingBoundaryEventCancellationResult {
        let eventIds = Set(
            buffer.pending(identifier: identifier).map(\.eventId)
        )
        finishSynchronization(identifier: identifier)
        return buffer.cancel(eventIds: eventIds)
    }

    @discardableResult
    func cancelAll() -> PendingBoundaryEventCancellationResult {
        let eventIds = Set(
            buffer.pendingIdentifiers().flatMap {
                buffer.pending(identifier: $0).map(\.eventId)
            }
        )
        withLock {
            synchronizationCandidatesByIdentifier.removeAll()
        }
        return buffer.cancel(eventIds: eventIds)
    }

    func cancel(
        eventIds: Set<String>
    ) -> PendingBoundaryEventCancellationResult {
        buffer.cancel(eventIds: eventIds)
    }

    func retryCancellation(
        eventIds: Set<String>
    ) -> PendingBoundaryEventCancellationResult {
        buffer.cancel(eventIds: eventIds)
    }

    func pendingCancellationEventIds() -> Set<String> {
        buffer.pendingCancellationEventIds()
    }

    func retryPersistence() -> Bool {
        buffer.retryPersistence()
    }

    func pinResolvedCandidates(
        _ candidatesByEventId:
            [String: PendingBoundaryRegistrationCandidate]
    ) -> Bool {
        buffer.pinResolvedCandidates(candidatesByEventId)
    }

    func isSettled(identifier: String) -> Bool {
        !hasPendingMutation(identifier)
            && synchronizationCandidates(identifier: identifier) == nil
    }

    func pendingEvents(identifier: String) -> [PendingBoundaryEvent] {
        buffer.pending(identifier: identifier)
    }

    func pendingIdentifiers() -> [String] {
        buffer.pendingIdentifiers()
    }

    @discardableResult
    func remove(eventId: String) -> Bool {
        buffer.remove(eventId: eventId)
    }

    func admit(
        responseRegion: CLRegion,
        transition: PendingBoundaryTransition,
        receivedAtMillis: Int64
    ) -> PendingBoundaryEventAdmissionDecision {
        if let reason = gate.preflightBoundaryEvent(responseRegion) {
            return .rejected(reason)
        }
        guard let circularRegion = responseRegion as? CLCircularRegion else {
            return .rejected(.unsupportedRegionType)
        }

        let identifier = circularRegion.identifier
        let scopedCandidates =
            synchronizationCandidates(identifier: identifier)
        let mutationPending = hasPendingMutation(identifier)
        let backlogPending = !buffer.pending(identifier: identifier).isEmpty
        if mutationPending
            || scopedCandidates != nil
            || backlogPending
        {
            gate.noteBoundaryEventReceived(
                identifier: identifier
            )
            let result = buffer.append(
                transition,
                responseRegion: circularRegion,
                receivedAtMillis: receivedAtMillis,
                // A synchronization scope describes the only globally valid
                // winners. Coordinator-local "previous" metadata can be
                // temporarily incoherent after rollback persistence restores,
                // so never mix it into a scoped event.
                resolutionCandidates: scopedCandidates
                    ?? (
                        mutationPending
                            ? pendingCandidates(identifier)
                            : []
                    )
            )
            return .deferred(persisted: result.persisted)
        }

        switch gate.decideBoundaryEvent(for: circularRegion) {
        case .accepted(let publicRegion, let reason):
            return .accepted(
                publicRegion,
                receivedAtMillis: receivedAtMillis,
                reason: reason
            )
        case .rejected(let reason):
            return .rejected(reason)
        }
    }

    private func synchronizationCandidates(
        identifier: String
    ) -> [PendingBoundaryRegistrationCandidate]? {
        withLock {
            synchronizationCandidatesByIdentifier[identifier]
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

enum PendingBoundaryEventResolutionStep {
    case unsettled
    case empty
    case deliver(
        PendingBoundaryEvent,
        region: CLCircularRegion,
        callbackCandidate: PendingBoundaryRegistrationCandidate?,
        reason: InitialStateBoundaryEventAcceptanceReason
    )
    case discard(
        PendingBoundaryEvent,
        reason: InitialStateBoundaryEventRejectionReason
    )
    case incoherent(PendingBoundaryEvent)
}

enum PendingBoundaryEventPreparationResult: Equatable {
    case ready(cleanupRetryEventIds: Set<String>)
    case unsettled
    case storageFailure
}

/// The production delegate's identifier-scoped resolution state machine.
///
/// One event is returned at a time so durable raw-buffer deletion remains the
/// commit point before the next FIFO event can advance.
final class PendingBoundaryEventResolutionCoordinator {
    private let gate: InitialStateRequestGate
    private let admissionCoordinator:
        PendingBoundaryEventAdmissionCoordinator
    private let getCallbackHandle: (String) -> Int64?
    private let getCallbackContext: (String) -> Int64?

    init(
        gate: InitialStateRequestGate,
        admissionCoordinator: PendingBoundaryEventAdmissionCoordinator,
        getCallbackHandle: @escaping (String) -> Int64?,
        getCallbackContext: @escaping (String) -> Int64?
    ) {
        self.gate = gate
        self.admissionCoordinator = admissionCoordinator
        self.getCallbackHandle = getCallbackHandle
        self.getCallbackContext = getCallbackContext
    }

    func next(
        identifier: String
    ) -> PendingBoundaryEventResolutionStep {
        guard admissionCoordinator.isSettled(identifier: identifier) else {
            return .unsettled
        }
        guard let pending = admissionCoordinator.pendingEvents(
            identifier: identifier
        ).first else {
            return .empty
        }
        if let resolved = pending.resolvedRegistrationCandidate {
            let reason: InitialStateBoundaryEventAcceptanceReason =
                RegionMonitoringSemantics.matches(
                    pending.responseRegion,
                    resolved.region
                )
                    ? .monitoringSemanticsMatch
                    : .monitoringSemanticsMismatch
            return .deliver(
                pending,
                region: resolved.region,
                callbackCandidate: resolved,
                reason: reason
            )
        }
        switch gate.decideBoundaryEvent(for: pending.responseRegion) {
        case .accepted(let publicRegion, let reason):
            let callbackCandidate = selectWinner(
                from: pending.resolutionCandidates,
                committedRegion: publicRegion
            )
            if !pending.resolutionCandidates.isEmpty,
               callbackCandidate == nil
            {
                return .incoherent(pending)
            }
            return .deliver(
                pending,
                region: publicRegion,
                callbackCandidate: callbackCandidate,
                reason: reason
            )
        case .rejected(let reason):
            return .discard(pending, reason: reason)
        }
    }

    /// Makes every event's winner durable before an external mutation
    /// completion can release queued same-ID work.
    func prepare(
        identifier: String
    ) -> PendingBoundaryEventPreparationResult {
        guard admissionCoordinator.isSettled(identifier: identifier) else {
            return .unsettled
        }
        var candidatesByEventId:
            [String: PendingBoundaryRegistrationCandidate] = [:]
        var terminalEventIds: Set<String> = []
        for pending in admissionCoordinator.pendingEvents(
            identifier: identifier
        ) {
            guard pending.resolvedRegistrationCandidate == nil else {
                continue
            }
            switch gate.decideBoundaryEvent(for: pending.responseRegion) {
            case .accepted(let publicRegion, _):
                let candidate = selectWinner(
                    from: pending.resolutionCandidates,
                    committedRegion: publicRegion
                ) ?? currentRegistrationCandidate(region: publicRegion)
                guard let candidate else {
                    terminalEventIds.insert(pending.eventId)
                    continue
                }
                if !pending.resolutionCandidates.isEmpty,
                   !pending.resolutionCandidates.contains(candidate)
                {
                    terminalEventIds.insert(pending.eventId)
                    continue
                }
                candidatesByEventId[pending.eventId] = candidate
            case .rejected:
                terminalEventIds.insert(pending.eventId)
            }
        }
        guard admissionCoordinator.pinResolvedCandidates(
            candidatesByEventId
        ) else {
            return .storageFailure
        }
        guard !terminalEventIds.isEmpty else {
            return .ready(cleanupRetryEventIds: [])
        }
        let cancellation = admissionCoordinator.cancel(
            eventIds: terminalEventIds
        )
        guard cancellation.establishedDurableCancellation else {
            return .storageFailure
        }
        return .ready(
            cleanupRetryEventIds: cancellation.retryEventIds
        )
    }

    func selectWinner(
        from candidates: [PendingBoundaryRegistrationCandidate],
        committedRegion: CLCircularRegion
    ) -> PendingBoundaryRegistrationCandidate? {
        PendingBoundaryRegistrationWinnerResolver.select(
            from: candidates,
            committedRegion: committedRegion,
            currentCallbackHandle: getCallbackHandle(
                committedRegion.identifier
            ),
            currentCallbackContext: getCallbackContext(
                committedRegion.identifier
            )
        )
    }

    func remove(eventId: String) -> Bool {
        admissionCoordinator.remove(eventId: eventId)
    }

    private func currentRegistrationCandidate(
        region: CLCircularRegion
    ) -> PendingBoundaryRegistrationCandidate? {
        guard let callbackHandle = getCallbackHandle(region.identifier) else {
            return nil
        }
        return PendingBoundaryRegistrationCandidate(
            region: region,
            callbackHandle: callbackHandle,
            callbackContext: getCallbackContext(region.identifier)
        )
    }
}

/// Correlates explicit initial-state checks using private, one-shot probes.
final class InitialStateRequestGate {
    private static let probeIdentifierPrefix = "native_geofence.initial-state."

    private var committedRegionsByIdentifier: [String: CLCircularRegion] = [:]
    private var publicRegionsByProbeIdentifier: [String: CLCircularRegion] = [:]
    private var probeIdentifierByPublicIdentifier: [String: String] = [:]

    /// Seeds registrations restored by Core Location when the plugin starts.
    func restoreCommittedRegions(_ regions: [CLCircularRegion]) {
        for region in regions {
            if let existingRegion = committedRegionsByIdentifier[region.identifier],
               !RegionMonitoringSemantics.matches(existingRegion, region)
            {
                cancelProbe(for: region.identifier)
            }
            committedRegionsByIdentifier[region.identifier] = region
        }
    }

    /// Replaces only authority owned by one failed synchronization transaction.
    /// Unrelated committed regions and their outstanding one-shot probes remain
    /// valid. Responses for touched pre-transaction probes are stale after a
    /// stop/restart and are deliberately invalidated.
    func replaceCommittedRegions(
        for identifiers: Set<String>,
        with regions: [CLCircularRegion]
    ) {
        for identifier in identifiers {
            remove(identifier)
        }
        restoreCommittedRegions(
            regions.filter { identifiers.contains($0.identifier) }
        )
    }

    /// Applies a successfully committed registration and returns its optional
    /// one-shot state probe.
    func commit(
        region publicRegion: CLCircularRegion,
        initialTrigger: Bool
    ) -> CLCircularRegion? {
        cancelProbe(for: publicRegion.identifier)
        committedRegionsByIdentifier[publicRegion.identifier] = publicRegion
        guard initialTrigger else { return nil }

        var probeIdentifier: String
        repeat {
            probeIdentifier = "\(Self.probeIdentifierPrefix)\(UUID().uuidString)"
        } while probeIdentifier == publicRegion.identifier
            || publicRegionsByProbeIdentifier[probeIdentifier] != nil

        let probe = CLCircularRegion(
            center: publicRegion.center,
            radius: publicRegion.radius,
            identifier: probeIdentifier
        )
        probe.notifyOnEntry = publicRegion.notifyOnEntry
        probe.notifyOnExit = publicRegion.notifyOnExit

        publicRegionsByProbeIdentifier[probeIdentifier] = publicRegion
        probeIdentifierByPublicIdentifier[publicRegion.identifier] = probeIdentifier
        return probe
    }

    /// Consumes only the response to a currently authorized private probe.
    func consumeInitialStateResponse(for responseRegion: CLRegion) -> CLCircularRegion? {
        guard let publicRegion = publicRegionsByProbeIdentifier.removeValue(
            forKey: responseRegion.identifier
        ) else {
            return nil
        }

        guard let committedRegion = committedRegionsByIdentifier[publicRegion.identifier],
              RegionMonitoringSemantics.matches(committedRegion, publicRegion)
        else {
            return nil
        }
        if probeIdentifierByPublicIdentifier[publicRegion.identifier]
            == responseRegion.identifier
        {
            probeIdentifierByPublicIdentifier.removeValue(forKey: publicRegion.identifier)
        }
        return committedRegion
    }

    /// Routes a real boundary callback using Core Location's documented
    /// identifier contract and invalidates its pending initial-state probe.
    ///
    /// The region supplied to `didEnterRegion` or `didExitRegion` is not
    /// guaranteed to preserve the registered region's geometry. Registration
    /// transactions decide which same-ID configuration is committed; callback
    /// admission must therefore use the current committed identifier rather
    /// than comparing callback coordinates, radius, or notification flags.
    /// The delegate defers callbacks while such a transaction is pending and
    /// asks this gate again after the winning registration commits.
    func decideBoundaryEvent(
        for responseRegion: CLRegion
    ) -> InitialStateBoundaryEventDecision {
        if let reason = preflightBoundaryEvent(responseRegion) {
            return .rejected(reason)
        }
        guard let committedRegion = committedRegionsByIdentifier[responseRegion.identifier]
        else {
            return .rejected(.unknownIdentifier)
        }

        let reason: InitialStateBoundaryEventAcceptanceReason =
            RegionMonitoringSemantics.matches(responseRegion, committedRegion)
                ? .monitoringSemanticsMatch
                : .monitoringSemanticsMismatch
        cancelProbe(for: committedRegion.identifier)
        return .accepted(committedRegion, reason: reason)
    }

    func preflightBoundaryEvent(
        _ responseRegion: CLRegion
    ) -> InitialStateBoundaryEventRejectionReason? {
        guard responseRegion is CLCircularRegion else {
            return .unsupportedRegionType
        }
        guard publicRegionsByProbeIdentifier[responseRegion.identifier] == nil else {
            return .privateInitialStateProbe
        }
        return nil
    }

    func noteBoundaryEventReceived(identifier: String) {
        cancelProbe(for: identifier)
    }

    func consumeBoundaryEvent(for responseRegion: CLRegion) -> CLCircularRegion? {
        guard case .accepted(let region, _) = decideBoundaryEvent(
            for: responseRegion
        ) else {
            return nil
        }
        return region
    }

    func remove(_ publicRegionIdentifier: String) {
        committedRegionsByIdentifier.removeValue(forKey: publicRegionIdentifier)
        cancelProbe(for: publicRegionIdentifier)
    }

    /// Removes a committed registration only when the failure describes its
    /// current monitoring semantics, not a replaced same-ID configuration.
    @discardableResult
    func remove(matching region: CLRegion) -> Bool {
        guard let committedRegion = committedRegionsByIdentifier[region.identifier],
              RegionMonitoringSemantics.matches(region, committedRegion)
        else {
            return false
        }
        remove(committedRegion.identifier)
        return true
    }

    func removeAll() {
        committedRegionsByIdentifier.removeAll()
        publicRegionsByProbeIdentifier.removeAll()
        probeIdentifierByPublicIdentifier.removeAll()
    }

    private func cancelProbe(for publicRegionIdentifier: String) {
        guard let probeIdentifier = probeIdentifierByPublicIdentifier.removeValue(
            forKey: publicRegionIdentifier
        ) else {
            return
        }
        publicRegionsByProbeIdentifier.removeValue(forKey: probeIdentifier)
    }
}
