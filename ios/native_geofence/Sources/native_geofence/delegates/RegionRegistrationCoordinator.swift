import CoreLocation
import Foundation

protocol RegionMonitoring: AnyObject {
    var monitoredRegions: Set<CLRegion> { get }

    func startMonitoring(for region: CLRegion)
    func stopMonitoring(for region: CLRegion)
}

extension CLLocationManager: RegionMonitoring {}

enum RegionRegistrationFailure: Error, Equatable {
    case missingLocationPermission(String)
    case monitoringFailed(String)

    var message: String {
        switch self {
        case .missingLocationPermission(let message), .monitoringFailed(let message):
            return message
        }
    }

    func appending(_ message: String) -> RegionRegistrationFailure {
        switch self {
        case .missingLocationPermission(let existingMessage):
            return .missingLocationPermission("\(existingMessage) \(message)")
        case .monitoringFailed(let existingMessage):
            return .monitoringFailed("\(existingMessage) \(message)")
        }
    }
}

private final class PendingRegionRegistration {
    let requestedRegion: CLCircularRegion
    let requestedCallbackHandle: Int64
    let requestedCallbackContext: Int64?
    let previousRegion: CLRegion?
    let previousCallbackHandle: Int64?
    let previousCallbackContext: Int64?
    let initialTrigger: Bool
    let completion: (Result<Void, RegionRegistrationFailure>) -> Void
    var confirmationAttempt = 0
    var observedAmbiguousCallbacks = 0
    var timeoutWorkItem: DispatchWorkItem?

    init(
        requestedRegion: CLCircularRegion,
        requestedCallbackHandle: Int64,
        requestedCallbackContext: Int64?,
        previousRegion: CLRegion?,
        previousCallbackHandle: Int64?,
        previousCallbackContext: Int64?,
        initialTrigger: Bool,
        completion: @escaping (Result<Void, RegionRegistrationFailure>) -> Void
    ) {
        self.requestedRegion = requestedRegion
        self.requestedCallbackHandle = requestedCallbackHandle
        self.requestedCallbackContext = requestedCallbackContext
        self.previousRegion = previousRegion
        self.previousCallbackHandle = previousCallbackHandle
        self.previousCallbackContext = previousCallbackContext
        self.initialTrigger = initialTrigger
        self.completion = completion
    }
}

private final class PendingRegionRestoration {
    let region: CLRegion
    let originalFailure: RegionRegistrationFailure
    let boundaryResolutionCandidates:
        [PendingBoundaryRegistrationCandidate]
    let completion: (Result<Void, RegionRegistrationFailure>) -> Void
    var confirmationAttempt = 0
    var observedAmbiguousCallbacks = 0
    var timeoutWorkItem: DispatchWorkItem?

    init(
        region: CLRegion,
        originalFailure: RegionRegistrationFailure,
        boundaryResolutionCandidates: [PendingBoundaryRegistrationCandidate],
        completion: @escaping (Result<Void, RegionRegistrationFailure>) -> Void
    ) {
        self.region = region
        self.originalFailure = originalFailure
        self.boundaryResolutionCandidates = boundaryResolutionCandidates
        self.completion = completion
    }
}

private final class CancelledRegionRegistration {
    let regions: [CLRegion]
    let quietPeriodSeconds: TimeInterval
    var timeoutWorkItem: DispatchWorkItem?

    init(
        regions: [CLRegion],
        quietPeriodSeconds: TimeInterval
    ) {
        self.regions = regions
        self.quietPeriodSeconds = quietPeriodSeconds
    }
}

private final class ConfirmedRetryRegistration {
    let region: CLRegion
    let quietPeriodSeconds: TimeInterval
    var remainingAmbiguousCallbacks: Int
    var requiresPlatformReconciliation: Bool
    var timeoutWorkItem: DispatchWorkItem?

    init(
        region: CLRegion,
        quietPeriodSeconds: TimeInterval,
        remainingAmbiguousCallbacks: Int,
        requiresPlatformReconciliation: Bool
    ) {
        self.region = region
        self.quietPeriodSeconds = quietPeriodSeconds
        self.remainingAmbiguousCallbacks = remainingAmbiguousCallbacks
        self.requiresPlatformReconciliation = requiresPlatformReconciliation
    }
}

struct CommittedRegionRegistration {
    let region: CLCircularRegion
    let initialTrigger: Bool
    let isNewMonitoringRegistration: Bool
}

enum RegionMonitoringFailureOutcome: Equatable {
    case pendingRegistrationHandled
    case pendingRestorationHandled
    case committedRegistrationInvalidated
    case ignoredUnattributed
    case ignoredStaleOrUnowned

    var shouldRecordRegistrationFailureFact: Bool {
        self == .committedRegistrationInvalidated
    }
}

final class RegionRegistrationCoordinator {
    typealias TimeoutScheduler = (TimeInterval, DispatchWorkItem) -> Void
    typealias CommittedRegionRestorer = (CLCircularRegion) -> Void
    typealias CommittedRegionInvalidator = (String) -> Void
    typealias MatchingCommittedRegionInvalidator = (CLRegion) -> Bool

    private let monitor: any RegionMonitoring
    private let timeoutSeconds: TimeInterval
    private let maximumConfirmationAttempts: Int
    private let scheduleTimeout: TimeoutScheduler
    private let getCallbackHandle: (String) -> Int64?
    private let getCallbackContext: (String) -> Int64?
    private let setCallbackHandle: (String, Int64) -> Void
    private let removeCallbackHandle: (String) -> Void
    private let setCallbackContext: (String, Int64?) -> Void
    private let restoreCommittedRegion: CommittedRegionRestorer
    private let invalidateCommittedRegion: CommittedRegionInvalidator
    private let invalidateMatchingCommittedRegion: MatchingCommittedRegionInvalidator
    private var pendingRegistrations: [String: PendingRegionRegistration] = [:]
    private var pendingRestorations: [String: PendingRegionRestoration] = [:]
    private var cancelledRegistrations: [String: CancelledRegionRegistration] = [:]
    private var confirmedRetryRegistrations:
        [String: ConfirmedRetryRegistration] = [:]

    init(
        monitor: any RegionMonitoring,
        timeoutSeconds: TimeInterval = 10,
        maximumConfirmationAttempts: Int = 3,
        scheduleTimeout: @escaping TimeoutScheduler = { delay, workItem in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        },
        getCallbackHandle: @escaping (String) -> Int64?,
        getCallbackContext: @escaping (String) -> Int64? = { _ in nil },
        setCallbackHandle: @escaping (String, Int64) -> Void,
        removeCallbackHandle: @escaping (String) -> Void,
        setCallbackContext: @escaping (String, Int64?) -> Void = { _, _ in },
        restoreCommittedRegion: @escaping CommittedRegionRestorer = { _ in },
        invalidateCommittedRegion: @escaping CommittedRegionInvalidator = { _ in },
        invalidateMatchingCommittedRegion: @escaping MatchingCommittedRegionInvalidator = { _ in false }
    ) {
        self.monitor = monitor
        self.timeoutSeconds = timeoutSeconds
        self.maximumConfirmationAttempts = max(1, maximumConfirmationAttempts)
        self.scheduleTimeout = scheduleTimeout
        self.getCallbackHandle = getCallbackHandle
        self.getCallbackContext = getCallbackContext
        self.setCallbackHandle = setCallbackHandle
        self.removeCallbackHandle = removeCallbackHandle
        self.setCallbackContext = setCallbackContext
        self.restoreCommittedRegion = restoreCommittedRegion
        self.invalidateCommittedRegion = invalidateCommittedRegion
        self.invalidateMatchingCommittedRegion = invalidateMatchingCommittedRegion
    }

    /// Starts monitoring and returns a committed registration immediately when
    /// an identical registration is already active.
    func start(
        region: CLCircularRegion,
        callbackHandle: Int64,
        callbackContext: Int64? = nil,
        initialTrigger: Bool,
        completion: @escaping (Result<Void, RegionRegistrationFailure>) -> Void
    ) -> CommittedRegionRegistration? {
        start(
            region: region,
            callbackHandle: callbackHandle,
            callbackContext: callbackContext,
            initialTrigger: initialTrigger,
            enforceRegionLimit: true,
            forceMonitoring: false,
            allowsDifferentSemanticTombstones: false,
            completion: completion
        )
    }

    /// Transaction code has already preflighted the final app-wide capacity.
    /// It may also need to force a rollback start while Core Location still
    /// exposes a region for which stopMonitoring was just requested.
    func startForSynchronization(
        region: CLCircularRegion,
        callbackHandle: Int64,
        callbackContext: Int64? = nil,
        forceMonitoring: Bool = false,
        completion: @escaping (Result<Void, RegionRegistrationFailure>) -> Void
    ) -> CommittedRegionRegistration? {
        start(
            region: region,
            callbackHandle: callbackHandle,
            callbackContext: callbackContext,
            initialTrigger: false,
            enforceRegionLimit: false,
            forceMonitoring: forceMonitoring,
            allowsDifferentSemanticTombstones: true,
            completion: completion
        )
    }

    private func start(
        region: CLCircularRegion,
        callbackHandle: Int64,
        callbackContext: Int64?,
        initialTrigger: Bool,
        enforceRegionLimit: Bool,
        forceMonitoring: Bool,
        allowsDifferentSemanticTombstones: Bool,
        completion: @escaping (Result<Void, RegionRegistrationFailure>) -> Void
    ) -> CommittedRegionRegistration? {
        let id = region.identifier
        guard pendingRegistrations[id] == nil, pendingRestorations[id] == nil else {
            completion(
                .failure(
                    .monitoringFailed(
                        "A registration for geofence ID=\(id) is already pending."
                    )
                )
            )
            return nil
        }
        let removalTombstoneBlocksStart = cancelledRegistrations[id].map {
            cancelled in
            !allowsDifferentSemanticTombstones
                || cancelled.regions.contains(where: {
                    RegionMonitoringSemantics.matches(region, $0)
                })
        } ?? false
        guard !removalTombstoneBlocksStart else {
            completion(
                .failure(
                    .monitoringFailed(
                        "A recent removal for geofence ID=\(id) is still being processed by iOS."
                    )
                )
            )
            return nil
        }

        let monitoredRegion = monitor.monitoredRegions.first {
            $0.identifier == id
        }
        // A forced synchronization start belongs to rollback. If it fails,
        // the still-visible region being stopped is not a valid compensation
        // target; only the snapshot registration may win.
        let previousRegion = forceMonitoring ? nil : monitoredRegion
        let storedCallbackHandle = getCallbackHandle(id)
        let storedCallbackContext = getCallbackContext(id)
        let previousCallbackHandle = previousRegion.flatMap { _ in storedCallbackHandle }
        let previousCallbackContext = previousRegion.flatMap {
            _ in storedCallbackContext
        }
        // A callback handle is the plugin's ownership marker for legacy region
        // identifiers. Never replace or restore an unowned app region.
        if let monitoredRegion,
           storedCallbackHandle == nil || !(monitoredRegion is CLCircularRegion)
        {
            completion(
                .failure(
                    .monitoringFailed(
                        "Geofence ID=\(id) conflicts with a region not registered by this plugin."
                    )
                )
            )
            return nil
        }
        let monitoredRegionIds = Set(monitor.monitoredRegions.map(\.identifier))
        let reservedRegionIds = Set(
            pendingRegistrations.values.map(\.requestedRegion.identifier)
                + pendingRestorations.values.map(\.region.identifier)
        )
        let reservedRegionCount = reservedRegionIds.subtracting(monitoredRegionIds).count
        if enforceRegionLimit,
           monitoredRegion == nil,
           monitor.monitoredRegions.count + reservedRegionCount >= 20
        {
            completion(
                .failure(
                    .monitoringFailed(
                        "iOS allows at most 20 monitored regions per app."
                    )
                )
            )
            return nil
        }

        if !forceMonitoring,
           let existingRegion = monitoredRegion as? CLCircularRegion,
           RegionMonitoringSemantics.matches(existingRegion, region)
        {
            setCallbackHandle(id, callbackHandle)
            setCallbackContext(id, callbackContext)
            completion(.success(()))
            return CommittedRegionRegistration(
                region: existingRegion,
                initialTrigger: initialTrigger,
                isNewMonitoringRegistration: false
            )
        }

        let pending = PendingRegionRegistration(
            requestedRegion: region,
            requestedCallbackHandle: callbackHandle,
            requestedCallbackContext: callbackContext,
            previousRegion: previousRegion,
            previousCallbackHandle: previousCallbackHandle,
            previousCallbackContext: previousCallbackContext,
            initialTrigger: initialTrigger,
            completion: completion
        )
        // Keep the previous handle active until Core Location confirms the new
        // registration, so events from the old region cannot reach a new callback.
        pendingRegistrations[id] = pending

        // A callback handle without a live region is stale. Do not publish it
        // while a genuinely new registration is awaiting confirmation.
        if monitoredRegion == nil, storedCallbackHandle != nil {
            removeCallbackMetadata(id: id)
            invalidateCommittedRegion(id)
        }
        beginRegistrationConfirmationAttempt(id: id, pending: pending)
        return nil
    }

    /// Completes a matching pending registration and returns its committed
    /// initial-trigger contract.
    func didStartMonitoring(for region: CLRegion) -> CommittedRegionRegistration? {
        let id = region.identifier
        if let pending = pendingRegistrations[id],
           RegionMonitoringSemantics.matches(region, pending.requestedRegion)
        {
            pendingRegistrations.removeValue(forKey: id)
            pending.timeoutWorkItem?.cancel()
            installConfirmedRetryRegistration(
                for: pending.requestedRegion,
                confirmationAttempt: pending.confirmationAttempt,
                observedAmbiguousCallbacks:
                    pending.observedAmbiguousCallbacks
            )
            setCallbackHandle(id, pending.requestedCallbackHandle)
            setCallbackContext(id, pending.requestedCallbackContext)
            pending.completion(.success(()))
            return CommittedRegionRegistration(
                region: pending.requestedRegion,
                initialTrigger: pending.initialTrigger,
                isNewMonitoringRegistration: true
            )
        }

        if let restoration = pendingRestorations[id],
           RegionMonitoringSemantics.matches(region, restoration.region)
        {
            pendingRestorations.removeValue(forKey: id)
            restoration.timeoutWorkItem?.cancel()
            installConfirmedRetryRegistration(
                for: restoration.region,
                confirmationAttempt: restoration.confirmationAttempt,
                observedAmbiguousCallbacks:
                    restoration.observedAmbiguousCallbacks
            )
            if let restoredRegion = restoration.region as? CLCircularRegion {
                restoreCommittedRegion(restoredRegion)
            }
            restoration.completion(.failure(restoration.originalFailure))
            return nil
        }

        if let cancelled = cancelledRegistrations[id],
           cancelled.regions.contains(where: {
               RegionMonitoringSemantics.matches(region, $0)
           })
        {
            monitor.stopMonitoring(for: region)
            // Require a complete quiet period after every observed late start;
            // another confirmation from the same bounded retry batch may follow.
            scheduleCancellationTombstoneExpiry(
                id: id,
                cancelled: cancelled
            )
            return nil
        }
        _ = consumeConfirmedRetryCallback(for: region)
        return nil
    }

    func didFailMonitoring(
        for region: CLRegion?,
        error: any Error
    ) -> RegionMonitoringFailureOutcome {
        // Core Location occasionally reports a nil region. That error cannot be
        // attributed safely, so let each token-owned operation resolve through
        // its matching callback or timeout instead of cancelling unrelated work.
        guard let region else { return .ignoredUnattributed }
        let failure = registrationFailure(from: error, regionId: region.identifier)
        if let pending = pendingRegistrations[region.identifier] {
            if RegionMonitoringSemantics.matches(region, pending.requestedRegion) {
                // Once a timeout has issued another semantically identical start,
                // Core Location provides no token that can attribute this failure
                // to the old or current attempt. Keep the bounded timeout retry
                // authoritative unless iOS has proven permission is unavailable.
                if pending.confirmationAttempt > 1,
                   case .monitoringFailed = failure
                {
                    pending.observedAmbiguousCallbacks += 1
                    return .pendingRegistrationHandled
                }
                if case .monitoringFailed = failure,
                   consumeConfirmedRetryCallback(for: region)
                {
                    return .pendingRegistrationHandled
                }
                finishRegistrationWithFailure(
                    id: region.identifier,
                    matching: region,
                    failure: failure,
                    installLateStartBarrier:
                        pending.confirmationAttempt > 1
                )
                return .pendingRegistrationHandled
            }
            return .ignoredStaleOrUnowned
        }
        if let restoration = pendingRestorations[region.identifier] {
            if RegionMonitoringSemantics.matches(region, restoration.region) {
                if restoration.confirmationAttempt > 1,
                   case .monitoringFailed = failure
                {
                    restoration.observedAmbiguousCallbacks += 1
                    return .pendingRestorationHandled
                }
                if case .monitoringFailed = failure,
                   consumeConfirmedRetryCallback(for: region)
                {
                    return .pendingRestorationHandled
                }
                finishRestorationWithFailure(
                    id: region.identifier,
                    matching: region,
                    failure: restoration.originalFailure.appending(
                        "Restoring the previous registration also failed: \(failure.message)"
                    ),
                    installLateStartBarrier:
                        restoration.confirmationAttempt > 1
                )
                return .pendingRestorationHandled
            }
            return .ignoredStaleOrUnowned
        }

        if case .monitoringFailed = failure,
           monitor.monitoredRegions.contains(where: {
               RegionMonitoringSemantics.matches(region, $0)
           }),
           consumeConfirmedRetryCallback(
               for: region,
               requiresPlatformReconciliation: true
           )
        {
            return .ignoredStaleOrUnowned
        }
        clearConfirmedRetryRegistration(matching: region)
        if invalidateMatchingCommittedRegion(region) {
            monitor.stopMonitoring(for: region)
            removeCallbackMetadata(id: region.identifier)
            return .committedRegistrationInvalidated
        }
        return .ignoredStaleOrUnowned
    }

    @discardableResult
    func cancel(id: String) -> Bool {
        if let pending = pendingRegistrations.removeValue(forKey: id) {
            pending.timeoutWorkItem?.cancel()
            monitor.stopMonitoring(for: pending.requestedRegion)
            removeCallbackMetadata(id: id)
            addCancellationTombstone(
                for: pending.requestedRegion,
                quietIntervalCount: pending.confirmationAttempt
            )
            cancelConfirmedRetryRegistration(
                id: id,
                unlessMatching: pending.requestedRegion
            )
            pending.completion(.failure(cancellationFailure(id: id)))
            return true
        }

        if let restoration = pendingRestorations.removeValue(forKey: id) {
            restoration.timeoutWorkItem?.cancel()
            monitor.stopMonitoring(for: restoration.region)
            removeCallbackMetadata(id: id)
            addCancellationTombstone(
                for: restoration.region,
                quietIntervalCount: restoration.confirmationAttempt
            )
            cancelConfirmedRetryRegistration(
                id: id,
                unlessMatching: restoration.region
            )
            restoration.completion(.failure(cancellationFailure(id: id)))
            return true
        }

        return cancelConfirmedRetryRegistration(id: id)
    }

    func cancelAll() {
        let ids = Set(
            Array(pendingRegistrations.keys)
                + Array(pendingRestorations.keys)
                + Array(confirmedRetryRegistrations.keys)
        )
        for id in ids {
            cancel(id: id)
        }
    }

    func recordRemoval(of region: CLRegion) {
        let confirmedQuietPeriod = confirmedRetryRegistrations[
            region.identifier
        ].flatMap {
            RegionMonitoringSemantics.matches(region, $0.region)
                ? $0.quietPeriodSeconds
                : nil
        }
        clearConfirmedRetryRegistration(id: region.identifier)
        addCancellationTombstone(
            for: region,
            minimumQuietPeriodSeconds: confirmedQuietPeriod ?? 0
        )
    }

    /// Whether Core Location and committed callback metadata can temporarily
    /// describe different same-ID registrations.
    func hasPendingMutation(id: String) -> Bool {
        pendingRegistrations[id] != nil || pendingRestorations[id] != nil
    }

    func pendingBoundaryResolutionCandidates(
        id: String
    ) -> [PendingBoundaryRegistrationCandidate] {
        if let pending = pendingRegistrations[id] {
            var candidates: [PendingBoundaryRegistrationCandidate] = []
            if let previousRegion = pending.previousRegion as? CLCircularRegion,
               let previousCallbackHandle = pending.previousCallbackHandle
            {
                candidates.append(
                    PendingBoundaryRegistrationCandidate(
                        region: previousRegion,
                        callbackHandle: previousCallbackHandle,
                        callbackContext: pending.previousCallbackContext
                    )
                )
            }
            candidates.append(
                PendingBoundaryRegistrationCandidate(
                    region: pending.requestedRegion,
                    callbackHandle: pending.requestedCallbackHandle,
                    callbackContext: pending.requestedCallbackContext
                )
            )
            return candidates
        }

        if let restoration = pendingRestorations[id] {
            return restoration.boundaryResolutionCandidates
        }
        return []
    }

    /// Synchronization rollback is an intentional re-registration of the
    /// exact pre-transaction region. Clear only that region's removal barrier
    /// before restoration so failed same-ID replacement geometries remain
    /// protected from late confirmations.
    func clearRemovalTombstone(
        matching region: CLRegion,
        protectRetainedRegionsThroughConfirmationAttempts: Bool = false
    ) {
        let id = region.identifier
        guard let existing = cancelledRegistrations[id] else { return }
        existing.timeoutWorkItem?.cancel()
        let retainedRegions = existing.regions.filter {
            !RegionMonitoringSemantics.matches(region, $0)
        }
        guard !retainedRegions.isEmpty else {
            cancelledRegistrations.removeValue(forKey: id)
            return
        }
        let retained = CancelledRegionRegistration(
            regions: retainedRegions,
            quietPeriodSeconds: existing.quietPeriodSeconds
                + (
                    protectRetainedRegionsThroughConfirmationAttempts
                        ? timeoutSeconds
                            * Double(maximumConfirmationAttempts)
                        : 0
                )
        )
        cancelledRegistrations[id] = retained
        scheduleCancellationTombstoneExpiry(id: id, cancelled: retained)
    }

    private func finishRegistrationWithFailure(
        id: String,
        matching region: CLRegion?,
        failure: RegionRegistrationFailure,
        installLateStartBarrier: Bool = false
    ) {
        guard let pending = pendingRegistrations[id],
              region.map({
                  RegionMonitoringSemantics.matches($0, pending.requestedRegion)
              }) ?? true
        else {
            return
        }

        pendingRegistrations.removeValue(forKey: id)
        pending.timeoutWorkItem?.cancel()
        monitor.stopMonitoring(for: pending.requestedRegion)
        if installLateStartBarrier {
            let restorationAttemptCount =
                pending.previousRegion != nil
                    && pending.previousCallbackHandle != nil
                    ? maximumConfirmationAttempts
                    : 0
            addCancellationTombstone(
                for: pending.requestedRegion,
                quietIntervalCount:
                    pending.confirmationAttempt + restorationAttemptCount
            )
        }

        if let previousRegion = pending.previousRegion,
           pending.previousCallbackHandle != nil
        {
            beginRestoration(
                region: previousRegion,
                originalFailure: failure,
                boundaryResolutionCandidates:
                    boundaryResolutionCandidates(for: pending),
                completion: pending.completion
            )
        } else {
            removeCallbackMetadata(id: id)
            invalidateCommittedRegion(id)
            pending.completion(.failure(failure))
        }
    }

    private func beginRegistrationConfirmationAttempt(
        id: String,
        pending: PendingRegionRegistration
    ) {
        guard pendingRegistrations[id] === pending else { return }
        pending.confirmationAttempt += 1
        let attempt = pending.confirmationAttempt
        let timeoutWorkItem = DispatchWorkItem {
            [weak self, weak pending] in
            guard let self,
                  let pending,
                  pendingRegistrations[id] === pending,
                  pending.confirmationAttempt == attempt
            else {
                return
            }
            guard attempt >= maximumConfirmationAttempts else {
                monitor.stopMonitoring(for: pending.requestedRegion)
                beginRegistrationConfirmationAttempt(
                    id: id,
                    pending: pending
                )
                return
            }
            finishRegistrationWithFailure(
                id: id,
                matching: pending.requestedRegion,
                failure: .monitoringFailed(
                    "Timed out waiting for iOS to confirm region monitoring for geofence ID=\(id) after \(maximumConfirmationAttempts) attempts."
                ),
                installLateStartBarrier: true
            )
        }
        pending.timeoutWorkItem = timeoutWorkItem
        scheduleTimeout(timeoutSeconds, timeoutWorkItem)

        // A custom scheduler may execute synchronously in a test. Do not start
        // monitoring after that scheduler has already exhausted this request.
        guard pendingRegistrations[id] === pending,
              pending.confirmationAttempt == attempt
        else {
            return
        }
        monitor.startMonitoring(for: pending.requestedRegion)
    }

    private func beginRestoration(
        region: CLRegion,
        originalFailure: RegionRegistrationFailure,
        boundaryResolutionCandidates:
            [PendingBoundaryRegistrationCandidate],
        completion: @escaping (Result<Void, RegionRegistrationFailure>) -> Void
    ) {
        let id = region.identifier
        let restoration = PendingRegionRestoration(
            region: region,
            originalFailure: originalFailure,
            boundaryResolutionCandidates: boundaryResolutionCandidates,
            completion: completion
        )
        pendingRestorations[id] = restoration
        beginRestorationConfirmationAttempt(
            id: id,
            restoration: restoration
        )
    }

    private func beginRestorationConfirmationAttempt(
        id: String,
        restoration: PendingRegionRestoration
    ) {
        guard pendingRestorations[id] === restoration else { return }
        restoration.confirmationAttempt += 1
        let attempt = restoration.confirmationAttempt
        let timeoutWorkItem = DispatchWorkItem {
            [weak self, weak restoration] in
            guard let self,
                  let restoration,
                  pendingRestorations[id] === restoration,
                  restoration.confirmationAttempt == attempt
            else {
                return
            }
            guard attempt >= maximumConfirmationAttempts else {
                monitor.stopMonitoring(for: restoration.region)
                beginRestorationConfirmationAttempt(
                    id: id,
                    restoration: restoration
                )
                return
            }
            finishRestorationWithFailure(
                id: id,
                matching: restoration.region,
                failure: restoration.originalFailure.appending(
                    "Timed out while restoring the previous registration after \(maximumConfirmationAttempts) attempts."
                ),
                installLateStartBarrier: true
            )
        }
        restoration.timeoutWorkItem = timeoutWorkItem
        scheduleTimeout(timeoutSeconds, timeoutWorkItem)

        guard pendingRestorations[id] === restoration,
              restoration.confirmationAttempt == attempt
        else {
            return
        }
        monitor.startMonitoring(for: restoration.region)
    }

    private func finishRestorationWithFailure(
        id: String,
        matching region: CLRegion?,
        failure: RegionRegistrationFailure,
        installLateStartBarrier: Bool = false
    ) {
        guard let restoration = pendingRestorations[id],
              region.map({
                  RegionMonitoringSemantics.matches($0, restoration.region)
              }) ?? true
        else {
            return
        }

        pendingRestorations.removeValue(forKey: id)
        restoration.timeoutWorkItem?.cancel()
        monitor.stopMonitoring(for: restoration.region)
        if installLateStartBarrier {
            addCancellationTombstone(
                for: restoration.region,
                quietIntervalCount: restoration.confirmationAttempt
            )
        }
        removeCallbackMetadata(id: id)
        invalidateCommittedRegion(id)
        restoration.completion(.failure(failure))
    }

    private func addCancellationTombstone(
        for region: CLRegion,
        quietIntervalCount: Int = 1,
        minimumQuietPeriodSeconds: TimeInterval = 0
    ) {
        let id = region.identifier
        let existing = cancelledRegistrations[id]
        existing?.timeoutWorkItem?.cancel()
        var regions = existing?.regions ?? []
        if !regions.contains(where: {
            RegionMonitoringSemantics.matches(region, $0)
        }) {
            regions.append(region)
        }
        let quietPeriodSeconds = max(
            existing?.quietPeriodSeconds ?? 0,
            timeoutSeconds * Double(max(1, quietIntervalCount)),
            minimumQuietPeriodSeconds
        )
        let cancelled = CancelledRegionRegistration(
            regions: regions,
            quietPeriodSeconds: quietPeriodSeconds
        )
        cancelledRegistrations[id] = cancelled
        scheduleCancellationTombstoneExpiry(id: id, cancelled: cancelled)
    }

    private func scheduleCancellationTombstoneExpiry(
        id: String,
        cancelled: CancelledRegionRegistration
    ) {
        cancelled.timeoutWorkItem?.cancel()
        let timeoutWorkItem = DispatchWorkItem { [weak self, weak cancelled] in
            guard let self, let cancelled,
                  self.cancelledRegistrations[id] === cancelled
            else {
                return
            }
            self.cancelledRegistrations.removeValue(forKey: id)
        }
        cancelled.timeoutWorkItem = timeoutWorkItem
        scheduleTimeout(cancelled.quietPeriodSeconds, timeoutWorkItem)
    }

    private func installConfirmedRetryRegistration(
        for region: CLRegion,
        confirmationAttempt: Int,
        observedAmbiguousCallbacks: Int
    ) {
        let id = region.identifier
        let existing = confirmedRetryRegistrations[id].flatMap {
            RegionMonitoringSemantics.matches(region, $0.region) ? $0 : nil
        }
        confirmedRetryRegistrations[id]?.timeoutWorkItem?.cancel()
        confirmedRetryRegistrations.removeValue(forKey: id)
        let remainingAmbiguousCallbacks = max(
            0,
            (existing?.remainingAmbiguousCallbacks ?? 0)
                + max(0, confirmationAttempt - 1)
                - observedAmbiguousCallbacks
        )
        let requiresPlatformReconciliation =
            existing?.requiresPlatformReconciliation ?? false
        guard remainingAmbiguousCallbacks > 0
                || requiresPlatformReconciliation
        else {
            return
        }
        let confirmed = ConfirmedRetryRegistration(
            region: region,
            quietPeriodSeconds: max(
                existing?.quietPeriodSeconds ?? 0,
                timeoutSeconds * Double(max(1, confirmationAttempt))
            ),
            remainingAmbiguousCallbacks: remainingAmbiguousCallbacks,
            requiresPlatformReconciliation:
                requiresPlatformReconciliation
        )
        confirmedRetryRegistrations[id] = confirmed
        scheduleConfirmedRetryRegistrationExpiry(
            id: id,
            confirmed: confirmed
        )
    }

    private func consumeConfirmedRetryCallback(
        for region: CLRegion,
        requiresPlatformReconciliation: Bool = false
    ) -> Bool {
        let id = region.identifier
        guard let confirmed = confirmedRetryRegistrations[id],
              RegionMonitoringSemantics.matches(region, confirmed.region),
              confirmed.remainingAmbiguousCallbacks > 0
        else {
            return false
        }
        confirmed.remainingAmbiguousCallbacks -= 1
        if requiresPlatformReconciliation {
            confirmed.requiresPlatformReconciliation = true
        }
        if confirmed.remainingAmbiguousCallbacks <= 0,
           !confirmed.requiresPlatformReconciliation
        {
            clearConfirmedRetryRegistration(id: id)
        } else {
            scheduleConfirmedRetryRegistrationExpiry(
                id: id,
                confirmed: confirmed
            )
        }
        return true
    }

    private func clearConfirmedRetryRegistration(matching region: CLRegion) {
        guard let confirmed = confirmedRetryRegistrations[region.identifier],
              RegionMonitoringSemantics.matches(region, confirmed.region)
        else {
            return
        }
        clearConfirmedRetryRegistration(id: region.identifier)
    }

    private func clearConfirmedRetryRegistration(id: String) {
        confirmedRetryRegistrations.removeValue(forKey: id)?
            .timeoutWorkItem?.cancel()
    }

    @discardableResult
    private func cancelConfirmedRetryRegistration(
        id: String,
        unlessMatching protectedRegion: CLRegion? = nil
    ) -> Bool {
        guard let confirmed = confirmedRetryRegistrations[id] else {
            return false
        }
        clearConfirmedRetryRegistration(id: id)
        guard protectedRegion.map({
            RegionMonitoringSemantics.matches($0, confirmed.region)
        }) != true
        else {
            return true
        }
        monitor.stopMonitoring(for: confirmed.region)
        addCancellationTombstone(
            for: confirmed.region,
            minimumQuietPeriodSeconds: confirmed.quietPeriodSeconds
        )
        removeCallbackMetadata(id: id)
        return true
    }

    private func scheduleConfirmedRetryRegistrationExpiry(
        id: String,
        confirmed: ConfirmedRetryRegistration
    ) {
        confirmed.timeoutWorkItem?.cancel()
        let timeoutWorkItem = DispatchWorkItem { [weak self, weak confirmed] in
            guard let self, let confirmed,
                  self.confirmedRetryRegistrations[id] === confirmed
            else {
                return
            }
            guard self.pendingRegistrations[id] == nil,
                  self.pendingRestorations[id] == nil
            else {
                self.scheduleConfirmedRetryRegistrationExpiry(
                    id: id,
                    confirmed: confirmed
                )
                return
            }
            self.confirmedRetryRegistrations.removeValue(forKey: id)
            guard confirmed.requiresPlatformReconciliation,
                  !self.monitor.monitoredRegions.contains(where: {
                      RegionMonitoringSemantics.matches(
                          confirmed.region,
                          $0
                      )
                  }),
                  self.invalidateMatchingCommittedRegion(confirmed.region)
            else {
                return
            }
            self.monitor.stopMonitoring(for: confirmed.region)
            self.removeCallbackMetadata(id: id)
        }
        confirmed.timeoutWorkItem = timeoutWorkItem
        scheduleTimeout(confirmed.quietPeriodSeconds, timeoutWorkItem)
    }

    private func boundaryResolutionCandidates(
        for pending: PendingRegionRegistration
    ) -> [PendingBoundaryRegistrationCandidate] {
        var candidates: [PendingBoundaryRegistrationCandidate] = []
        if let previousRegion = pending.previousRegion as? CLCircularRegion,
           let previousCallbackHandle = pending.previousCallbackHandle
        {
            candidates.append(
                PendingBoundaryRegistrationCandidate(
                    region: previousRegion,
                    callbackHandle: previousCallbackHandle,
                    callbackContext: pending.previousCallbackContext
                )
            )
        }
        candidates.append(
            PendingBoundaryRegistrationCandidate(
                region: pending.requestedRegion,
                callbackHandle: pending.requestedCallbackHandle,
                callbackContext: pending.requestedCallbackContext
            )
        )
        return candidates
    }

    private func removeCallbackMetadata(id: String) {
        removeCallbackHandle(id)
        setCallbackContext(id, nil)
    }

    private func cancellationFailure(id: String) -> RegionRegistrationFailure {
        .monitoringFailed(
            "Registration for geofence ID=\(id) was cancelled because the geofence was removed."
        )
    }

    private func registrationFailure(
        from error: any Error,
        regionId: String?
    ) -> RegionRegistrationFailure {
        let idDescription = regionId.map { " for geofence ID=\($0)" } ?? ""
        let message = "iOS region monitoring failed\(idDescription): \(error.localizedDescription)"
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain,
           let code = CLError.Code(rawValue: nsError.code),
           code == .denied || code == .regionMonitoringDenied
        {
            return .missingLocationPermission(message)
        }
        return .monitoringFailed(message)
    }

}
