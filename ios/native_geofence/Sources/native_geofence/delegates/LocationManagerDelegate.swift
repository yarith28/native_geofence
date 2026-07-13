import CoreLocation
import Foundation
import OSLog

// Singleton class
class LocationManagerDelegate: NSObject, CLLocationManagerDelegate {
    // Prevent multiple instances of CLLocationManager to avoid duplicate triggers.
    private static var sharedLocationManager: CLLocationManager?
    
    private let log = Logger(subsystem: Constants.PACKAGE_NAME, category: "LocationManagerDelegate")
    private let deliverEvent: (
        GeofenceCallbackParamsWire,
        @escaping () -> Void
    ) -> Void
    private let eventDeduplicator: IosGeofenceEventDeduplicator
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
            @escaping () -> Void
        ) -> Void,
        eventDeduplicator: IosGeofenceEventDeduplicator = IosGeofenceEventDeduplicator()
    ) {
        self.deliverEvent = deliverEvent
        self.eventDeduplicator = eventDeduplicator
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
        log.debug("didDetermineState: \(String(describing: state)) for geofence ID: \(region.identifier)")
        
        guard let publicRegion = initialStateRequestGate.consumeInitialStateResponse(
            for: region
        ) else {
            log.debug("Ignoring unrequested state for geofence ID: \(region.identifier)")
            return
        }

        guard let event: GeofenceEvent = switch state {
        case .unknown: nil
        case .inside: .enter
        case .outside: .exit
        } else {
            log.error("Unknown CLRegionState: \(String(describing: state))")
            return
        }
        
        handleRegionEvent(event: event, region: publicRegion)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
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
        case .accepted(let publicRegion, _):
            return publicRegion
        case .rejected(let reason):
            log.debug(
                "Ignoring \(event) for geofence ID=\(region.identifier), reason=\(reason.rawValue)"
            )
            return nil
        }
    }

    private func handleRegionEvent(event: GeofenceEvent, region: CLRegion) {
        guard let activeGeofence = ActiveGeofenceWires.fromRegion(region) else {
            log.error("Unknown CLRegion type: \(String(describing: type(of: region)))")
            return
        }

        if !activeGeofence.triggers.contains(event) {
            return
        }
        NativeGeofenceDiagnostics.record(
            .broadcast,
            succeeded: true,
            outcome: "resolved",
            geofenceCount: 1
        )
        
        guard let callbackHandle = NativeGeofencePersistence.getRegionCallbackHandle(id: activeGeofence.id) else {
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
            log.info(
                "Suppressed repeat \(String(describing: event)) for geofence ID=\(activeGeofence.id); same direction accepted \(ageMillis)ms ago."
            )
            return
        }

        let params = GeofenceCallbackParamsWire(
            geofences: [activeGeofence],
            event: event,
            eventAtMillis: eventAtMillis,
            callbackHandle: callbackHandle,
            eventId: UUID().uuidString,
            callbackContextsByGeofenceId: NativeGeofencePersistence
                .getRegionCallbackContext(id: activeGeofence.id)
                .map { [activeGeofence.id: $0] }
        )

        deliverEvent(params) { [weak self] in
            self?.eventDeduplicator.recordAccepted(
                id: activeGeofence.id,
                transition: transition,
                eventAtMillis: eventAtMillis
            )
        }
        log.debug("Geofence trigger event handed to the shared delivery router.")
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
}
