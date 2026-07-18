import CoreLocation
import Foundation
import OSLog

/// Process-stable Core Location delegate owned by
/// `IosGeofenceMutationAuthority`.
class LocationManagerDelegate: NSObject, CLLocationManagerDelegate {
    // Prevent multiple instances of CLLocationManager to avoid duplicate triggers.
    private static var sharedLocationManager: CLLocationManager?
    
    private let log = Logger(subsystem: Constants.PACKAGE_NAME, category: "LocationManagerDelegate")
    private let deliverEvent: (
        GeofenceCallbackParamsWire,
        @escaping (Bool) -> Void
    ) -> Void
    private let eventDeduplicator: IosGeofenceEventDeduplicator
    private let callbackJournal: IosGeofenceCallbackJournal
    private let deliveryDiagnostics: IosNativeGeofenceDeliveryDiagnostics
    private let callbackDeliveryLock = NSLock()
    private var inFlightJournalEventIds: Set<String> = []
    let locationManager: CLLocationManager
    private lazy var regionRegistrationCoordinator = RegionRegistrationCoordinator(
        monitor: locationManager,
        getCallbackHandle: NativeGeofencePersistence.getRegionCallbackHandle,
        setCallbackHandle: NativeGeofencePersistence.setRegionCallbackHandle,
        removeCallbackHandle: NativeGeofencePersistence.removeRegionCallbackHandle,
        setCallbackContext: NativeGeofencePersistence.setRegionCallbackContext,
        restoreCommittedRegion: { [weak self] region in
            self?.initialStateRequestGate.restoreCommittedRegions([region])
        },
        invalidateCommittedRegion: { [weak self] id in
            self?.initialStateRequestGate.remove(id)
            self?.eventDeduplicator.remove(id: id)
        },
        invalidateMatchingCommittedRegion: { [weak self] region in
            guard let self,
                  self.initialStateRequestGate.remove(matching: region)
            else {
                return false
            }
            self.eventDeduplicator.remove(id: region.identifier)
            return true
        }
    )
    private let initialStateRequestGate = InitialStateRequestGate()
    
    init(
        deliverEvent: @escaping (
            GeofenceCallbackParamsWire,
            @escaping (Bool) -> Void
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
        
        log.debug("LocationManagerDelegate created with instance ID=\(Int.random(in: 1 ... 1000000)).")
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
        ) { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let failure):
                completion(.failure(nativeGeofenceError(failure)))
            }
        }

        applyInitialStateContract(committedRegistration, using: locationManager)
        log.debug("Handled monitoring request for geofence ID=\(region.identifier).")
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
            ) { result in
                switch result {
                case .success:
                    completion(.success(()))
                case .failure(let failure):
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
    }

    func cancelMonitoringStart(id: String) {
        initialStateRequestGate.remove(id)
        regionRegistrationCoordinator.cancel(id: id)
        eventDeduplicator.remove(id: id)
    }

    func cancelAllMonitoringStarts() {
        initialStateRequestGate.removeAll()
        regionRegistrationCoordinator.cancelAll()
        eventDeduplicator.removeAll()
    }

    func recordRemoval(of region: CLRegion) {
        initialStateRequestGate.remove(region.identifier)
        regionRegistrationCoordinator.recordRemoval(of: region)
    }

    func clearSynchronizationRemovalTombstone(id: String) {
        regionRegistrationCoordinator.clearRemovalTombstone(id: id)
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
    
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
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
        deliveryDiagnostics.record(
            stage: "core_location_callback",
            outcome: "received",
            event: "enter",
            geofenceCount: 1,
            owner: "ios_delegate"
        )
        log.debug("didEnterRegion for geofence ID: \(region.identifier)")
        guard let publicRegion = admittedBoundaryRegion(
            for: region,
            event: "enter"
        ) else {
            return
        }
        handleRegionEvent(event: .enter, region: publicRegion)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        deliveryDiagnostics.record(
            stage: "core_location_callback",
            outcome: "received",
            event: "exit",
            geofenceCount: 1,
            owner: "ios_delegate"
        )
        log.debug("didExitRegion for geofence ID: \(region.identifier)")
        guard let publicRegion = admittedBoundaryRegion(
            for: region,
            event: "exit"
        ) else {
            return
        }
        handleRegionEvent(event: .exit, region: publicRegion)
    }

    private func admittedBoundaryRegion(
        for region: CLRegion,
        event: String
    ) -> CLCircularRegion? {
        switch initialStateRequestGate.decideBoundaryEvent(
            for: region,
            requireMonitoringSemanticsMatch: regionRegistrationCoordinator
                .hasPendingMutation(id: region.identifier)
        ) {
        case .accepted(let publicRegion, let reason):
            deliveryDiagnostics.record(
                stage: "boundary_gate",
                outcome: "accepted",
                event: event,
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: reason.rawValue
            )
            return publicRegion
        case .rejected(let reason):
            deliveryDiagnostics.record(
                stage: "boundary_gate",
                outcome: "rejected",
                event: event,
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: reason.rawValue
            )
            log.debug(
                "Ignoring \(event) for geofence ID=\(region.identifier), reason=\(reason.rawValue)"
            )
            return nil
        }
    }

    private func handleRegionEvent(event: GeofenceEvent, region: CLRegion) {
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
            return
        }

        if !activeGeofence.triggers.contains(event) {
            deliveryDiagnostics.record(
                stage: "event_resolution",
                outcome: "rejected",
                event: event == .enter ? "enter" : "exit",
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: "transition_not_configured"
            )
            return
        }
        NativeGeofenceDiagnostics.record(
            .broadcast,
            succeeded: true,
            outcome: "resolved",
            geofenceCount: 1
        )
        
        guard let callbackHandle = NativeGeofencePersistence.getRegionCallbackHandle(id: activeGeofence.id) else {
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
            return
        }
        
        let transition = IosGeofenceTransition(event)
        let eventAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        if let ageMillis = eventDeduplicator.suppressedAgeMillis(
            id: activeGeofence.id,
            transition: transition,
            eventAtMillis: eventAtMillis
        ) {
            deliveryDiagnostics.record(
                stage: "event_deduplication",
                outcome: "rejected",
                event: event == .enter ? "enter" : "exit",
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: "same_direction_burst"
            )
            log.info(
                "Suppressed repeat \(String(describing: event)) for geofence ID=\(activeGeofence.id); same direction completed \(ageMillis)ms ago."
            )
            return
        }

        let eventId = UUID().uuidString
        let callbackContext = NativeGeofencePersistence
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
            drainPendingEvents()
            log.debug("Geofence trigger event persisted in the callback journal.")
        case .duplicate:
            deliveryDiagnostics.record(
                stage: "callback_journal",
                outcome: "rejected",
                event: event == .enter ? "enter" : "exit",
                geofenceCount: 1,
                owner: "ios_delegate",
                reasonCode: "pending_duplicate"
            )
            log.info("Suppressed duplicate pending callback journal event.")
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
            return
        }
        for _ in batch.terminallyDiscardedEventIds {
            NativeGeofenceDiagnostics.record(
                .worker,
                succeeded: false,
                outcome: "ios_journal_terminal_expiry"
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
                continue
            }
            deliverEvent(attempted.callbackParamsWire) { [weak self] succeeded in
                self?.completeJournalDelivery(
                    attempted,
                    succeeded: succeeded
                )
            }
        }
    }

    private func completeJournalDelivery(
        _ envelope: IosGeofenceCallbackJournalEnvelope,
        succeeded: Bool
    ) {
        releaseJournalDelivery(eventId: envelope.eventId)
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        if succeeded {
            eventDeduplicator.recordAccepted(
                id: envelope.geofence.id,
                transition: envelope.transition,
                eventAtMillis: envelope.eventAtMillis
            )
        }
        switch callbackJournal.complete(
            eventId: envelope.eventId,
            succeeded: succeeded,
            nowMillis: nowMillis
        ) {
        case .acknowledged:
            log.debug("Acknowledged completed iOS callback journal event.")
        case .failedWithoutRetry:
            NativeGeofenceDiagnostics.record(
                .worker,
                succeeded: false,
                outcome: "ios_journal_delivery_failed_not_retried"
            )
            log.error("Removed explicitly failed iOS callback journal event without retry.")
        case .storageFailure:
            NativeGeofenceDiagnostics.record(
                .worker,
                succeeded: false,
                outcome: "ios_journal_update_failed"
            )
            scheduleJournalDrain(afterMillis: 5_000)
        case .missing:
            log.debug("Ignoring completion for a missing callback journal event.")
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
        log.debug("didStartMonitoringFor geofence ID: \(region.identifier)")
        let committedRegistration = regionRegistrationCoordinator.didStartMonitoring(
            for: region
        )
        applyInitialStateContract(committedRegistration, using: manager)
    }
    
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: any Error) {
        log.error("monitoringDidFailFor: \(region?.identifier ?? "nil") withError: \(error)")
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
    }

    private func applyInitialStateContract(
        _ committedRegistration: CommittedRegionRegistration?,
        using manager: CLLocationManager
    ) {
        guard let committedRegistration else { return }
        if committedRegistration.isNewMonitoringRegistration {
            eventDeduplicator.remove(id: committedRegistration.region.identifier)
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
