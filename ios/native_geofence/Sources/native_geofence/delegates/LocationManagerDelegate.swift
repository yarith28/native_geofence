import CoreLocation
import Foundation
import OSLog

/// Process-stable Core Location delegate owned by
/// `IosGeofenceMutationAuthority`.
class LocationManagerDelegate: NSObject, CLLocationManagerDelegate {
    // Prevent multiple instances of CLLocationManager to avoid duplicate triggers.
    private static var sharedLocationManager: CLLocationManager?
    
    private let log = Logger(subsystem: Constants.PACKAGE_NAME, category: "LocationManagerDelegate")
    private let fileLog = IosNativeGeofenceFileLogger(
        category: "LocationManagerDelegate"
    )
    private let deliverEvent: (
        GeofenceCallbackParamsWire,
        @escaping (IosGeofenceCallbackDeliveryOutcome) -> Void
    ) -> Void
    private let eventDeduplicator: IosGeofenceEventDeduplicator
    private let callbackJournal: IosGeofenceCallbackJournal
    private let deliveryDiagnostics: IosNativeGeofenceDeliveryDiagnostics
    private let callbackDeliveryLock = NSLock()
    private var inFlightJournalEventIds: Set<String> = []
    private let pendingBoundaryEvents = PendingBoundaryEventBuffer()
    private var pendingBoundaryResolutionRetryIds: Set<String> = []
    private var pendingBoundaryCancellationRetryEventIds: Set<String> = []
    private var pendingBoundaryCancellationRetryScheduled = false
    private var pendingBoundaryPersistenceRetryScheduled = false
    let locationManager: CLLocationManager
    private lazy var regionRegistrationCoordinator = RegionRegistrationCoordinator(
        monitor: locationManager,
        getCallbackHandle: NativeGeofencePersistence.getRegionCallbackHandle,
        getCallbackContext: NativeGeofencePersistence.getRegionCallbackContext,
        setCallbackHandle: NativeGeofencePersistence.setRegionCallbackHandle,
        removeCallbackHandle: NativeGeofencePersistence.removeRegionCallbackHandle,
        setCallbackContext: NativeGeofencePersistence.setRegionCallbackContext,
        restoreCommittedRegion: { [weak self] region in
            self?.initialStateRequestGate.restoreCommittedRegions([region])
        },
        invalidateCommittedRegion: { [weak self] id in
            self?.initialStateRequestGate.remove(id)
            self?.resetBoundaryDeduplication(id: id)
        },
        invalidateMatchingCommittedRegion: { [weak self] region in
            guard let self,
                  self.initialStateRequestGate.remove(matching: region)
            else {
                return false
            }
            self.resetBoundaryDeduplication(id: region.identifier)
            return true
        },
        recordDiagnostic: { [weak self] message in
            _ = self?.fileLog.diagnostic(message)
        }
    )
    private let initialStateRequestGate = InitialStateRequestGate()
    private lazy var boundaryEventAdmissionCoordinator =
        PendingBoundaryEventAdmissionCoordinator(
            gate: initialStateRequestGate,
            buffer: pendingBoundaryEvents,
            hasPendingMutation: { [weak self] id in
                self?.regionRegistrationCoordinator.hasPendingMutation(id: id)
                    == true
            },
            pendingCandidates: { [weak self] id in
                self?.regionRegistrationCoordinator
                    .pendingBoundaryResolutionCandidates(id: id) ?? []
            }
        )
    private lazy var boundaryEventResolutionCoordinator =
        PendingBoundaryEventResolutionCoordinator(
            gate: initialStateRequestGate,
            admissionCoordinator: boundaryEventAdmissionCoordinator,
            getCallbackHandle:
                NativeGeofencePersistence.getRegionCallbackHandle,
            getCallbackContext:
                NativeGeofencePersistence.getRegionCallbackContext
        )
    
    init(
        deliverEvent: @escaping (
            GeofenceCallbackParamsWire,
            @escaping (IosGeofenceCallbackDeliveryOutcome) -> Void
        ) -> Void,
        eventDeduplicator: IosGeofenceEventDeduplicator = IosGeofenceEventDeduplicator(),
        callbackJournal: IosGeofenceCallbackJournal = IosGeofenceCallbackJournal(),
        deliveryDiagnostics: IosNativeGeofenceDeliveryDiagnostics = .shared
    ) {
        self.deliverEvent = deliverEvent
        self.eventDeduplicator = eventDeduplicator
        self.callbackJournal = callbackJournal
        self.deliveryDiagnostics = deliveryDiagnostics
        locationManager = LocationManagerDelegate.sharedLocationManager ?? CLLocationManager()
        LocationManagerDelegate.sharedLocationManager = locationManager
        
        super.init()
        initialStateRequestGate.restoreCommittedRegions(
            PluginOwnedRegions.select(
                from: locationManager.monitoredRegions,
                callbackIds: NativeGeofencePersistence.getRegionCallbackIds()
            )
        )
        locationManager.delegate = self
        DispatchQueue.main.async { [weak self] in
            self?.recoverPendingBoundaryEvents()
        }
        
        log.debug("LocationManagerDelegate created with instance ID=\(Int.random(in: 1 ... 1000000)).")
        fileLog.debug("LocationManagerDelegate created.")
    }

    func startMonitoring(
        region: CLCircularRegion,
        callbackHandle: Int64,
        callbackContext: Int64?,
        initialTrigger: Bool,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        let committedRegistration = regionRegistrationCoordinator.start(
            region: region,
            callbackHandle: callbackHandle,
            callbackContext: callbackContext,
            initialTrigger: initialTrigger
        ) { [weak self] result in
            switch result {
            case .success:
                self?.completeBoundaryMutationWhenDurable(
                    identifier: region.identifier,
                    result: .success(()),
                    completion: completion
                )
            case .failure(let failure):
                guard let self else { return }
                let result: Result<Void, any Error> = .failure(
                    nativeGeofenceError(failure)
                )
                // A synchronous duplicate rejection does not own the active
                // mutation and must not wait for its buffered events.
                if regionRegistrationCoordinator.hasPendingMutation(
                    id: region.identifier
                ) {
                    completion(result)
                } else {
                    completeBoundaryMutationWhenDurable(
                        identifier: region.identifier,
                        result: result,
                        completion: completion
                    )
                }
            }
        }

        applyInitialStateContract(committedRegistration, using: locationManager)
        log.debug("Handled monitoring request for geofence ID=\(region.identifier).")
        fileLog.diagnostic(
            "Handled monitoring request for geofence ID=\(region.identifier)."
        )
    }

    func startMonitoringForSynchronization(
        region: CLCircularRegion,
        callbackHandle: Int64,
        callbackContext: Int64?,
        forceMonitoring: Bool = false,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        let committedRegistration = regionRegistrationCoordinator
            .startForSynchronization(
                region: region,
                callbackHandle: callbackHandle,
                callbackContext: callbackContext,
                forceMonitoring: forceMonitoring
            ) { [weak self] result in
                switch result {
                case .success:
                    DispatchQueue.main.async {
                        completion(.success(()))
                    }
                case .failure(let failure):
                    // Keep rollback-owned events scoped to this transaction
                    // before its continuation can advance another mutation.
                    self?.resolvePendingBoundaryEventsIfSettled(
                        identifier: region.identifier
                    )
                    completion(.failure(nativeGeofenceError(failure)))
                }
            }
        // A matching synchronization registration is a metadata-only refresh.
        // It must not cancel an already-authorized initial-state probe for the
        // unchanged platform registration.
        if committedRegistration?.isNewMonitoringRegistration == true {
            applyInitialStateContract(committedRegistration, using: locationManager)
        }
        log.debug(
            "Handled synchronization monitoring request for geofence ID=\(region.identifier)."
        )
        fileLog.diagnostic(
            "Handled synchronization monitoring request for geofence ID=\(region.identifier)."
        )
    }

    @discardableResult
    func cancelMonitoringStart(id: String) -> Bool {
        guard establishPendingBoundaryCancellation(
            boundaryEventAdmissionCoordinator.cancel(identifier: id)
        ) else {
            return false
        }
        initialStateRequestGate.remove(id)
        resetBoundaryDeduplication(id: id)
        regionRegistrationCoordinator.cancel(id: id)
        return true
    }

    @discardableResult
    func cancelAllMonitoringStarts() -> Bool {
        guard establishPendingBoundaryCancellation(
            boundaryEventAdmissionCoordinator.cancelAll()
        ) else {
            return false
        }
        initialStateRequestGate.removeAll()
        resetAllBoundaryDeduplication()
        regionRegistrationCoordinator.cancelAll()
        return true
    }

    func recordRemoval(of region: CLRegion) {
        initialStateRequestGate.remove(region.identifier)
        regionRegistrationCoordinator.recordRemoval(of: region)
    }

    func clearSynchronizationRemovalTombstone(
        matching region: CLRegion,
        protectRetainedRegionsThroughConfirmationAttempts: Bool = false
    ) {
        regionRegistrationCoordinator.clearRemovalTombstone(
            matching: region,
            protectRetainedRegionsThroughConfirmationAttempts:
                protectRetainedRegionsThroughConfirmationAttempts
        )
    }

    func beginSynchronizationBoundaryEventDeferral(
        identifier: String,
        candidates: [PendingBoundaryRegistrationCandidate]
    ) {
        boundaryEventAdmissionCoordinator.beginSynchronization(
            identifier: identifier,
            candidates: candidates
        )
    }

    func finishSynchronizationBoundaryEventDeferral(
        identifiers: Set<String>,
        completion: @escaping () -> Void
    ) {
        for identifier in identifiers {
            boundaryEventAdmissionCoordinator.finishSynchronization(
                identifier: identifier
            )
        }
        finishSynchronizationBoundaryEventsWhenDurable(
            identifiers: identifiers,
            completion: completion
        )
    }

    func restoreSynchronizationAuthority(
        regions: [CLCircularRegion],
        transactionOwnedIds: Set<String>
    ) {
        initialStateRequestGate.replaceCommittedRegions(
            for: transactionOwnedIds,
            with: regions
        )
    }

    func applySynchronizationBoundaryAuthority(
        _ authority: PendingBoundarySynchronizationAuthority
    ) {
        guard let winner = authority.winnerCandidate else { return }
        if authority.resetsDeduplication {
            resetBoundaryDeduplication(id: authority.region.identifier)
        }
        NativeGeofencePersistence.setRegionCallbackHandle(
            id: authority.region.identifier,
            handle: winner.callbackHandle
        )
        NativeGeofencePersistence.setRegionCallbackContext(
            id: authority.region.identifier,
            context: winner.callbackContext
        )
    }
    
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        resumePendingCallbackDeliveryAfterExternalWake()
        let diagnosticEvent: String = switch state {
        case .inside: "state_inside"
        case .outside: "state_outside"
        case .unknown: "state_unknown"
        }
        deliveryDiagnostics.record(
            stage: "core_location_callback",
            outcome: "received",
            event: diagnosticEvent,
            geofenceCount: 1,
            owner: "ios_delegate"
        )
        log.debug("didDetermineState: \(String(describing: state)) for geofence ID: \(region.identifier)")
        fileLog.diagnostic(
            "didDetermineState: \(String(describing: state)) for geofence ID: \(region.identifier)"
        )
        
        guard let publicRegion = initialStateRequestGate.consumeInitialStateResponse(
            for: region
        ) else {
            deliveryDiagnostics.record(
                stage: "initial_state_gate",
                outcome: "rejected",
                event: diagnosticEvent,
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: "unrequested_state"
            )
            log.debug("Ignoring unrequested state for geofence ID: \(region.identifier)")
            fileLog.diagnostic(
                "Ignoring unrequested state for geofence ID: \(region.identifier)"
            )
            return
        }

        guard let event: GeofenceEvent = switch state {
        case .unknown: nil
        case .inside: .enter
        case .outside: .exit
        } else {
            deliveryDiagnostics.record(
                stage: "initial_state_gate",
                outcome: "rejected",
                event: diagnosticEvent,
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: "unknown_state"
            )
            log.error("Unknown CLRegionState: \(String(describing: state))")
            fileLog.error("Unknown CLRegionState: \(String(describing: state))")
            return
        }
        deliveryDiagnostics.record(
            stage: "initial_state_gate",
            outcome: "accepted",
            event: event == .enter ? "enter" : "exit",
            geofenceCount: 1,
            owner: "ios_delegate",
            reasonCode: "explicit_private_probe"
        )
        
        handleRegionEvent(event: event, region: publicRegion)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        resumePendingCallbackDeliveryAfterExternalWake()
        deliveryDiagnostics.record(
            stage: "core_location_callback",
            outcome: "received",
            event: "enter",
            geofenceCount: 1,
            owner: "ios_delegate"
        )
        log.debug("didEnterRegion for geofence ID: \(region.identifier)")
        fileLog.diagnostic("didEnterRegion for geofence ID: \(region.identifier)")
        guard let admitted = admittedBoundaryRegion(
            for: region,
            event: .enter
        ) else {
            return
        }
        handleRegionEvent(
            event: .enter,
            region: admitted.region,
            eventAtMillis: admitted.receivedAtMillis
        )
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        resumePendingCallbackDeliveryAfterExternalWake()
        deliveryDiagnostics.record(
            stage: "core_location_callback",
            outcome: "received",
            event: "exit",
            geofenceCount: 1,
            owner: "ios_delegate"
        )
        log.debug("didExitRegion for geofence ID: \(region.identifier)")
        fileLog.diagnostic("didExitRegion for geofence ID: \(region.identifier)")
        guard let admitted = admittedBoundaryRegion(
            for: region,
            event: .exit
        ) else {
            return
        }
        handleRegionEvent(
            event: .exit,
            region: admitted.region,
            eventAtMillis: admitted.receivedAtMillis
        )
    }

    private func admittedBoundaryRegion(
        for region: CLRegion,
        event: GeofenceEvent
    ) -> (region: CLCircularRegion, receivedAtMillis: Int64)? {
        let eventName = event == .enter ? "enter" : "exit"
        let receivedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        switch boundaryEventAdmissionCoordinator.admit(
            responseRegion: region,
            transition: event.pendingBoundaryTransition,
            receivedAtMillis: receivedAtMillis
        ) {
        case .accepted(let publicRegion, let acceptedAtMillis, let reason):
            deliveryDiagnostics.record(
                stage: "boundary_gate",
                outcome: "accepted",
                event: eventName,
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: reason.rawValue
            )
            return (publicRegion, acceptedAtMillis)
        case .deferred(let persisted):
            deliveryDiagnostics.record(
                stage: "boundary_gate",
                outcome: persisted ? "deferred" : "failed",
                event: eventName,
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: persisted
                    ? "pending_mutation"
                    : "pending_mutation_persistence_failure"
            )
            if persisted {
                log.debug(
                    "Deferred \(eventName) for geofence ID=\(region.identifier) until its pending mutation resolves."
                )
                fileLog.diagnostic(
                    "Deferred \(eventName) for geofence ID=\(region.identifier) until its pending mutation resolves."
                )
            } else {
                log.error(
                    "Deferred \(eventName) for geofence ID=\(region.identifier) only in memory because durable storage failed."
                )
                fileLog.error(
                    "Deferred \(eventName) for geofence ID=\(region.identifier) only in memory because durable storage failed."
                )
                if !boundaryEventAdmissionCoordinator.retryPersistence() {
                    schedulePendingBoundaryPersistence()
                }
            }
            // A settled identifier can still own a raw FIFO backlog after a
            // transient handoff failure. Keep newly admitted work behind it
            // and ensure the backlog has an active retry.
            if boundaryEventAdmissionCoordinator.isSettled(
                identifier: region.identifier
            ) {
                schedulePendingBoundaryResolution(
                    identifier: region.identifier
                )
            }
            return nil
        case .rejected(let reason):
            deliveryDiagnostics.record(
                stage: "boundary_gate",
                outcome: "rejected",
                event: eventName,
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: reason.rawValue
            )
            log.debug(
                "Ignoring \(eventName) for geofence ID=\(region.identifier), reason=\(reason.rawValue)"
            )
            fileLog.diagnostic(
                "Ignoring \(eventName) for geofence ID=\(region.identifier), reason=\(reason.rawValue)"
            )
            return nil
        }
    }

    private func recoverPendingBoundaryEvents() {
        schedulePendingBoundaryCancellation(
            eventIds: boundaryEventAdmissionCoordinator
                .pendingCancellationEventIds()
        )
        for identifier in boundaryEventAdmissionCoordinator
            .pendingIdentifiers()
        {
            let events = boundaryEventAdmissionCoordinator.pendingEvents(
                identifier: identifier
            )
            let unresolvedEvents = events.filter {
                $0.resolvedRegistrationCandidate == nil
            }
            let monitoredRegion = locationManager.monitoredRegions.first(
                where: { $0.identifier == identifier }
            ) as? CLCircularRegion
            if !unresolvedEvents.isEmpty {
                guard let monitoredRegion,
                      let recoveryPlan =
                          PendingBoundaryEventRecoveryPlanner.makePlan(
                              events: unresolvedEvents,
                              committedRegion: monitoredRegion,
                              currentCallbackHandle:
                                  NativeGeofencePersistence
                                      .getRegionCallbackHandle(
                                          id: identifier
                                      ),
                              currentCallbackContext:
                                  NativeGeofencePersistence
                                      .getRegionCallbackContext(
                                          id: identifier
                                      )
                          )
                else {
                    // Preserve already-pinned older generations, but prevent
                    // unresolved stale work from claiming a recreation.
                    let cancellation =
                        boundaryEventAdmissionCoordinator.cancel(
                            eventIds: Set(
                                unresolvedEvents.map(\.eventId)
                            )
                        )
                    schedulePendingBoundaryCancellation(
                        eventIds: cancellation.retryEventIds
                    )
                    if cancellation.establishedDurableCancellation {
                        _ = resolvePendingBoundaryEventsIfSettled(
                            identifier: identifier
                        )
                    }
                    continue
                }
                let candidate = recoveryPlan.winnerCandidate
                // A process may terminate after Core Location accepts a new
                // region but before didStartMonitoring publishes metadata.
                NativeGeofencePersistence.setRegionCallbackHandle(
                    id: identifier,
                    handle: candidate.callbackHandle
                )
                NativeGeofencePersistence.setRegionCallbackContext(
                    id: identifier,
                    context: candidate.callbackContext
                )
                initialStateRequestGate.restoreCommittedRegions(
                    [monitoredRegion]
                )
                if recoveryPlan.resetsDeduplication {
                    resetBoundaryDeduplication(id: identifier)
                }
            } else if let monitoredRegion {
                initialStateRequestGate.restoreCommittedRegions(
                    [monitoredRegion]
                )
            }
            if !resolvePendingBoundaryEventsIfSettled(
                identifier: identifier
            ) {
                schedulePendingBoundaryCancellation(
                    eventIds: boundaryEventAdmissionCoordinator
                        .pendingCancellationEventIds()
                )
            }
        }
    }

    @discardableResult
    private func resolvePendingBoundaryEventsIfSettled(
        identifier: String
    ) -> Bool {
        switch boundaryEventResolutionCoordinator.prepare(
            identifier: identifier
        ) {
        case .unsettled:
            return false
        case .storageFailure:
            log.error(
                "Failed to prepare deferred boundary events for geofence ID=\(identifier); retrying."
            )
            fileLog.error(
                "Failed to prepare deferred boundary events for geofence ID=\(identifier); retrying."
            )
            schedulePendingBoundaryResolution(identifier: identifier)
            return false
        case .ready(let cleanupRetryEventIds):
            schedulePendingBoundaryCancellation(
                eventIds: cleanupRetryEventIds
            )
        }
        while true {
            switch boundaryEventResolutionCoordinator.next(
                identifier: identifier
            ) {
            case .unsettled:
                return false
            case .empty:
                return true
            case .deliver(
                let pending,
                let publicRegion,
                let callbackCandidate,
                let reason
            ):
                let event = pending.transition.geofenceEvent
                let eventName = event == .enter ? "enter" : "exit"
                deliveryDiagnostics.record(
                    stage: "boundary_gate",
                    outcome: "accepted",
                    event: eventName,
                    geofenceCount: 1,
                    owner: "ios_delegate",
                    reasonCode: reason.rawValue
                )
                // The pinned candidate belongs to this event generation only.
                // Pass it into the journal envelope without rewriting the
                // current registration's callback metadata.
                let consumed = handleRegionEvent(
                    event: event,
                    region: publicRegion,
                    eventAtMillis: pending.receivedAtMillis,
                    eventId: pending.eventId,
                    callbackCandidate: callbackCandidate
                )
                if consumed {
                    if !boundaryEventResolutionCoordinator.remove(
                        eventId: pending.eventId
                    ) {
                        log.error(
                            "Failed to remove handed-off deferred \(eventName) event ID=\(pending.eventId); retrying cleanup."
                        )
                        fileLog.error(
                            "Failed to remove handed-off deferred \(eventName) event ID=\(pending.eventId); retrying cleanup."
                        )
                        schedulePendingBoundaryResolution(identifier: identifier)
                        return true
                    }
                    // Deferred events are journaled without starting delivery.
                    // Removing the durable raw record is the handoff commit; only
                    // then may the callback journal begin delivering it.
                    drainPendingEvents()
                } else {
                    schedulePendingBoundaryResolution(identifier: identifier)
                    return true
                }
            case .discard(let pending, let reason):
                let event = pending.transition.geofenceEvent
                let eventName = event == .enter ? "enter" : "exit"
                deliveryDiagnostics.record(
                    stage: "boundary_gate",
                    outcome: "rejected",
                    event: eventName,
                    geofenceCount: 1,
                    owner: "ios_delegate",
                    reasonCode: reason.rawValue
                )
                log.debug(
                    "Discarded deferred \(eventName) for geofence ID=\(identifier), reason=\(reason.rawValue)"
                )
                fileLog.diagnostic(
                    "Discarded deferred \(eventName) for geofence ID=\(identifier), reason=\(reason.rawValue)"
                )
                if !boundaryEventResolutionCoordinator.remove(
                    eventId: pending.eventId
                ) {
                    log.error(
                        "Failed to remove discarded deferred \(eventName) event ID=\(pending.eventId); retrying cleanup."
                    )
                    fileLog.error(
                        "Failed to remove discarded deferred \(eventName) event ID=\(pending.eventId); retrying cleanup."
                    )
                    schedulePendingBoundaryResolution(identifier: identifier)
                    return false
                }
            case .incoherent(let pending):
                let event = pending.transition.geofenceEvent
                let eventName = event == .enter ? "enter" : "exit"
                deliveryDiagnostics.record(
                    stage: "boundary_gate",
                    outcome: "rejected",
                    event: eventName,
                    geofenceCount: 1,
                    owner: "ios_delegate",
                    reasonCode: "no_coherent_registration_winner"
                )
                log.error(
                    "Discarded deferred \(eventName) for geofence ID=\(identifier) because no coherent registration won."
                )
                fileLog.error(
                    "Discarded deferred \(eventName) for geofence ID=\(identifier) because no coherent registration won."
                )
                if !boundaryEventResolutionCoordinator.remove(
                    eventId: pending.eventId
                ) {
                    log.error(
                        "Failed to remove incoherent deferred \(eventName) event ID=\(pending.eventId); retrying cleanup."
                    )
                    fileLog.error(
                        "Failed to remove incoherent deferred \(eventName) event ID=\(pending.eventId); retrying cleanup."
                    )
                    schedulePendingBoundaryResolution(identifier: identifier)
                    return false
                }
            }
        }
    }

    private func schedulePendingBoundaryResolution(identifier: String) {
        guard pendingBoundaryResolutionRetryIds.insert(identifier).inserted else {
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(5)
        ) { [weak self] in
            guard let self else { return }
            pendingBoundaryResolutionRetryIds.remove(identifier)
            resolvePendingBoundaryEventsIfSettled(identifier: identifier)
        }
    }

    private func schedulePendingBoundaryCancellation(
        eventIds: Set<String>
    ) {
        guard !eventIds.isEmpty else { return }
        pendingBoundaryCancellationRetryEventIds.formUnion(eventIds)
        guard !pendingBoundaryCancellationRetryScheduled else { return }
        pendingBoundaryCancellationRetryScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(5)
        ) { [weak self] in
            guard let self else { return }
            pendingBoundaryCancellationRetryScheduled = false
            let retryEventIds = pendingBoundaryCancellationRetryEventIds
            let result =
                boundaryEventAdmissionCoordinator.retryCancellation(
                    eventIds: retryEventIds
                )
            guard !result.retryEventIds.isEmpty else {
                pendingBoundaryCancellationRetryEventIds.subtract(
                    retryEventIds
                )
                return
            }
            schedulePendingBoundaryCancellation(
                eventIds: result.retryEventIds
            )
        }
    }

    private func establishPendingBoundaryCancellation(
        _ initialResult: PendingBoundaryEventCancellationResult
    ) -> Bool {
        var result = initialResult
        if case .persistenceFailure(let eventIds) = result {
            // One immediate retry avoids reporting a failed removal for a
            // momentary UserDefaults write failure.
            result = boundaryEventAdmissionCoordinator.retryCancellation(
                eventIds: eventIds
            )
        }
        guard result.establishedDurableCancellation else {
            return false
        }
        schedulePendingBoundaryCancellation(
            eventIds: result.retryEventIds
        )
        return true
    }

    private func completeBoundaryMutationWhenDurable(
        identifier: String,
        result: Result<Void, any Error>,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.retryBoundaryMutationCompletion(
                identifier: identifier,
                result: result,
                completion: completion
            )
        }
    }

    private func retryBoundaryMutationCompletion(
        identifier: String,
        result: Result<Void, any Error>,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guard !resolvePendingBoundaryEventsIfSettled(
            identifier: identifier
        ) else {
            completion(result)
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(5)
        ) { [weak self] in
            self?.retryBoundaryMutationCompletion(
                identifier: identifier,
                result: result,
                completion: completion
            )
        }
    }

    private func finishSynchronizationBoundaryEventsWhenDurable(
        identifiers: Set<String>,
        completion: @escaping () -> Void
    ) {
        let unresolved = identifiers.filter {
            !resolvePendingBoundaryEventsIfSettled(identifier: $0)
        }
        guard !unresolved.isEmpty else {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(5)
        ) { [weak self] in
            self?.finishSynchronizationBoundaryEventsWhenDurable(
                identifiers: Set(unresolved),
                completion: completion
            )
        }
    }

    private func schedulePendingBoundaryPersistence() {
        guard !pendingBoundaryPersistenceRetryScheduled else { return }
        pendingBoundaryPersistenceRetryScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(5)
        ) { [weak self] in
            guard let self else { return }
            pendingBoundaryPersistenceRetryScheduled = false
            guard !boundaryEventAdmissionCoordinator.retryPersistence()
            else {
                return
            }
            schedulePendingBoundaryPersistence()
        }
    }

    private func resetBoundaryDeduplication(id: String) {
        eventDeduplicator.remove(id: id)
        if !callbackJournal.resetDeduplication(identifier: id) {
            log.error(
                "Failed to reset callback journal deduplication for geofence ID=\(id)."
            )
            fileLog.error(
                "Failed to reset callback journal deduplication for geofence ID=\(id)."
            )
        }
    }

    private func resetAllBoundaryDeduplication() {
        eventDeduplicator.removeAll()
        if !callbackJournal.resetAllDeduplication() {
            log.error("Failed to reset callback journal deduplication.")
            fileLog.error("Failed to reset callback journal deduplication.")
        }
    }

    @discardableResult
    private func handleRegionEvent(
        event: GeofenceEvent,
        region: CLRegion,
        eventAtMillis receivedAtMillis: Int64? = nil,
        eventId suppliedEventId: String? = nil,
        callbackCandidate: PendingBoundaryRegistrationCandidate? = nil
    ) -> Bool {
        guard let activeGeofence = ActiveGeofenceWires.fromRegion(region) else {
            deliveryDiagnostics.record(
                stage: "event_resolution",
                outcome: "rejected",
                event: event == .enter ? "enter" : "exit",
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: "unsupported_region_type"
            )
            log.error("Unknown CLRegion type: \(String(describing: type(of: region)))")
            fileLog.error(
                "Unknown CLRegion type: \(String(describing: type(of: region)))"
            )
            return true
        }

        if !activeGeofence.triggers.contains(event) {
            let eventName = event == .enter ? "enter" : "exit"
            deliveryDiagnostics.record(
                stage: "event_resolution",
                outcome: "rejected",
                event: eventName,
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: "transition_not_configured"
            )
            log.info(
                "Ignoring \(eventName) for geofence ID=\(activeGeofence.id) because that transition is not configured."
            )
            fileLog.info(
                "Ignoring \(eventName) for geofence ID=\(activeGeofence.id) because that transition is not configured."
            )
            return true
        }
        NativeGeofenceDiagnostics.record(
            .broadcast,
            succeeded: true,
            outcome: "resolved",
            geofenceCount: 1
        )
        
        guard let callbackHandle = callbackCandidate?.callbackHandle
            ?? NativeGeofencePersistence.getRegionCallbackHandle(
                id: activeGeofence.id
            )
        else {
            deliveryDiagnostics.record(
                stage: "event_resolution",
                outcome: "rejected",
                event: event == .enter ? "enter" : "exit",
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: "callback_missing"
            )
            NativeGeofenceDiagnostics.record(
                .broadcast,
                succeeded: false,
                outcome: "callback_missing",
                geofenceCount: 1
            )
            log.error("Callback handle for region \(activeGeofence.id) not found.")
            fileLog.error(
                "Callback handle for region \(activeGeofence.id) not found."
            )
            return true
        }
        
        let transition = IosGeofenceTransition(event)
        let eventAtMillis =
            receivedAtMillis ?? Int64(Date().timeIntervalSince1970 * 1000)

        let eventId = suppliedEventId ?? UUID().uuidString
        let callbackContext = callbackCandidate.map(\.callbackContext)
            ?? NativeGeofencePersistence
                .getRegionCallbackContext(id: activeGeofence.id)
        let envelope = callbackJournal.makeEnvelope(
            eventId: eventId,
            traceId: eventId,
            geofence: .init(
                id: activeGeofence.id,
                latitude: activeGeofence.location.latitude,
                longitude: activeGeofence.location.longitude,
                radiusMeters: activeGeofence.radiusMeters,
                triggers: activeGeofence.triggers.map(IosGeofenceTransition.init)
            ),
            transition: transition,
            eventAtMillis: eventAtMillis,
            callbackHandle: callbackHandle,
            callbackContext: callbackContext,
            nowMillis: eventAtMillis
        )
        switch callbackJournal.enqueue(envelope) {
        case .stored:
            deliveryDiagnostics.record(
                stage: "callback_journal",
                outcome: "stored",
                event: event == .enter ? "enter" : "exit",
                geofenceCount: 1,
                owner: "ios_delegate"
            )
            NativeGeofenceDiagnostics.record(
                .enqueue,
                succeeded: true,
                outcome: "ios_journaled",
                geofenceCount: 1
            )
            if suppliedEventId == nil {
                drainPendingEvents()
            }
            log.debug("Geofence trigger event persisted in the callback journal.")
            fileLog.diagnostic(
                "Geofence trigger event persisted in the callback journal."
            )
            return true
        case .duplicate:
            deliveryDiagnostics.record(
                stage: "callback_journal",
                outcome: "rejected",
                event: event == .enter ? "enter" : "exit",
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: "journal_duplicate"
            )
            log.info("Suppressed duplicate callback journal event.")
            fileLog.info("Suppressed duplicate callback journal event.")
            return true
        case .storageFailure:
            deliveryDiagnostics.record(
                stage: "callback_journal",
                outcome: "failed",
                event: event == .enter ? "enter" : "exit",
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: "storage_failure"
            )
            NativeGeofenceDiagnostics.record(
                .enqueue,
                succeeded: false,
                outcome: "ios_journal_write_failed",
                geofenceCount: 1
            )
            log.error("Failed to persist the geofence callback journal event.")
            fileLog.error("Failed to persist the geofence callback journal event.")
            return false
        }
    }

    /// Drains persisted events on plugin attachment and after bounded backoff.
    func drainPendingEvents() {
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = callbackJournal.drainBatch(nowMillis: nowMillis)
        guard batch.storageReadable else {
            NativeGeofenceDiagnostics.record(
                .enqueue,
                succeeded: false,
                outcome: "ios_journal_read_failed"
            )
            log.error("Failed to read the iOS callback journal.")
            fileLog.error("Failed to read the iOS callback journal.")
            return
        }
        for eventId in batch.terminallyDiscardedEventIds {
            NativeGeofenceDiagnostics.record(
                .worker,
                succeeded: false,
                outcome: "ios_journal_terminal_expiry"
            )
            log.error(
                "Discarded expired iOS callback journal event ID=\(eventId)."
            )
            fileLog.error(
                "Discarded expired iOS callback journal event ID=\(eventId)."
            )
        }
        if let nextDueAtMillis = batch.nextDueAtMillis {
            scheduleJournalDrain(
                afterMillis: max(0, nextDueAtMillis - nowMillis)
            )
        }
        for pending in batch.due {
            guard reserveJournalDelivery(eventId: pending.eventId) else { continue }
            guard let attempted = callbackJournal.beginAttempt(
                eventId: pending.eventId,
                nowMillis: nowMillis
            ) else {
                releaseJournalDelivery(eventId: pending.eventId)
                log.error(
                    "Could not begin iOS callback journal event ID=\(pending.eventId); retaining it for a later wake."
                )
                fileLog.error(
                    "Could not begin iOS callback journal event ID=\(pending.eventId); retaining it for a later wake."
                )
                continue
            }
            deliverEvent(attempted.callbackParamsWire) { [weak self] outcome in
                self?.completeJournalDelivery(
                    attempted,
                    outcome: outcome
                )
            }
        }
    }

    /// Foreground activation and Core Location delegate callbacks are
    /// system-driven execution opportunities. Re-drain the durable journal on
    /// each one so a timer missed during suspension cannot strand due work.
    func resumePendingCallbackDeliveryAfterExternalWake() {
        drainPendingEvents()
    }

    private func completeJournalDelivery(
        _ envelope: IosGeofenceCallbackJournalEnvelope,
        outcome: IosGeofenceCallbackDeliveryOutcome
    ) {
        releaseJournalDelivery(eventId: envelope.eventId)
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        if outcome.didSucceed {
            eventDeduplicator.recordAccepted(
                id: envelope.geofence.id,
                transition: envelope.transition,
                eventAtMillis: envelope.eventAtMillis
            )
        }
        switch callbackJournal.complete(
            eventId: envelope.eventId,
            outcome: outcome,
            nowMillis: nowMillis
        ) {
        case .acknowledged:
            log.debug("Acknowledged completed iOS callback journal event.")
            fileLog.diagnostic("Acknowledged completed iOS callback journal event.")
        case .retryScheduled(let nextAttemptAtMillis):
            NativeGeofenceDiagnostics.record(
                .worker,
                succeeded: false,
                outcome: "ios_journal_delivery_retry_scheduled"
            )
            scheduleJournalDrain(
                afterMillis: max(0, nextAttemptAtMillis - nowMillis)
            )
            log.error("Retained failed iOS callback journal event for retry.")
            fileLog.error("Retained failed iOS callback journal event for retry.")
        case .retryExhausted:
            NativeGeofenceDiagnostics.record(
                .worker,
                succeeded: false,
                outcome: "ios_journal_delivery_retry_exhausted"
            )
            log.error("Discarded iOS callback journal event after retry exhaustion.")
            fileLog.error(
                "Discarded iOS callback journal event after retry exhaustion."
            )
        case .terminallyDiscarded(let reason):
            NativeGeofenceDiagnostics.record(
                .worker,
                succeeded: false,
                outcome: "ios_journal_terminal_\(reason.rawValue)"
            )
            log.error(
                "Discarded terminal iOS callback journal event: \(reason.rawValue)."
            )
            fileLog.error(
                "Discarded terminal iOS callback journal event: \(reason.rawValue)."
            )
        case .storageFailure:
            NativeGeofenceDiagnostics.record(
                .worker,
                succeeded: false,
                outcome: "ios_journal_update_failed"
            )
            log.error("Failed to update the iOS callback journal; retrying.")
            fileLog.error("Failed to update the iOS callback journal; retrying.")
            scheduleJournalDrain(afterMillis: 5_000)
        case .missing:
            log.debug("Ignoring completion for a missing callback journal event.")
            fileLog.debug("Ignoring completion for a missing callback journal event.")
        }
    }

    private func scheduleJournalDrain(afterMillis: Int64) {
        let bounded = min(max(0, afterMillis), 60 * 60 * 1000)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(bounded))
        ) { [weak self] in
            self?.drainPendingEvents()
        }
    }

    private func reserveJournalDelivery(eventId: String) -> Bool {
        callbackDeliveryLock.lock()
        defer { callbackDeliveryLock.unlock() }
        return inFlightJournalEventIds.insert(eventId).inserted
    }

    private func releaseJournalDelivery(eventId: String) {
        callbackDeliveryLock.lock()
        inFlightJournalEventIds.remove(eventId)
        callbackDeliveryLock.unlock()
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        resumePendingCallbackDeliveryAfterExternalWake()
        log.debug("didStartMonitoringFor geofence ID: \(region.identifier)")
        fileLog.diagnostic(
            "didStartMonitoringFor geofence ID: \(region.identifier)"
        )
        let committedRegistration = regionRegistrationCoordinator.didStartMonitoring(
            for: region
        )
        applyInitialStateContract(committedRegistration, using: manager)
        resolvePendingBoundaryEventsIfSettled(identifier: region.identifier)
    }
    
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: any Error) {
        resumePendingCallbackDeliveryAfterExternalWake()
        log.error("monitoringDidFailFor: \(region?.identifier ?? "nil") withError: \(error)")
        fileLog.error(
            "monitoringDidFailFor: \(region?.identifier ?? "nil") withError: \(error)"
        )
        let outcome = regionRegistrationCoordinator.didFailMonitoring(
            for: region,
            error: error
        )
        if outcome.shouldRecordRegistrationFailureFact {
            NativeGeofenceDiagnostics.record(
                .registration,
                succeeded: false,
                outcome: "monitoring_failed",
                geofenceCount: 1
            )
        }
        if let region {
            resolvePendingBoundaryEventsIfSettled(identifier: region.identifier)
        }
    }

    private func applyInitialStateContract(
        _ committedRegistration: CommittedRegionRegistration?,
        using manager: CLLocationManager
    ) {
        guard let committedRegistration else { return }
        if committedRegistration.isNewMonitoringRegistration {
            resetBoundaryDeduplication(
                id: committedRegistration.region.identifier
            )
        }
        guard let probe = initialStateRequestGate.commit(
            region: committedRegistration.region,
            initialTrigger: committedRegistration.initialTrigger
        ) else { return }
        manager.requestState(for: probe)
    }

}

private extension IosGeofenceTransition {
    init(_ event: GeofenceEvent) {
        switch event {
        case .enter: self = .enter
        case .exit: self = .exit
        case .dwell: self = .dwell
        }
    }

    var geofenceEvent: GeofenceEvent {
        switch self {
        case .enter: return .enter
        case .exit: return .exit
        case .dwell: return .dwell
        }
    }
}

private extension GeofenceEvent {
    var pendingBoundaryTransition: PendingBoundaryTransition {
        switch self {
        case .enter: return .enter
        case .exit: return .exit
        case .dwell:
            preconditionFailure("iOS boundary deferral does not support dwell.")
        }
    }
}

private extension PendingBoundaryTransition {
    var geofenceEvent: GeofenceEvent {
        switch self {
        case .enter: return .enter
        case .exit: return .exit
        }
    }
}

private extension IosGeofenceCallbackJournalEnvelope {
    var callbackParamsWire: GeofenceCallbackParamsWire {
        let activeGeofence = ActiveGeofenceWire(
            id: geofence.id,
            location: LocationWire(
                latitude: geofence.latitude,
                longitude: geofence.longitude,
                accuracyMeters: nil,
                isMock: false
            ),
            radiusMeters: geofence.radiusMeters,
            triggers: geofence.triggers.map(\.geofenceEvent)
        )
        return GeofenceCallbackParamsWire(
            geofences: [activeGeofence],
            event: transition.geofenceEvent,
            eventAtMillis: eventAtMillis,
            callbackHandle: callbackHandle,
            eventId: eventId,
            callbackContextsByGeofenceId: callbackContext.map { [geofence.id: $0] },
            traceId: traceId
        )
    }
}
