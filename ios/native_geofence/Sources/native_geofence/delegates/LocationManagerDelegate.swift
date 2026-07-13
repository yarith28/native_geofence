import CoreLocation
import Flutter
import OSLog
import UIKit

// Singleton class
class LocationManagerDelegate: NSObject, CLLocationManagerDelegate {
    // Prevent multiple instances of CLLocationManager to avoid duplicate triggers.
    private static var sharedLocationManager: CLLocationManager?
    
    private let log = Logger(subsystem: Constants.PACKAGE_NAME, category: "LocationManagerDelegate")
    private let callbackBackgroundTaskName = "native_geofence.geofence_callback"
    
    private let flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?
    private let eventDeduplicator: IosGeofenceEventDeduplicator
    let locationManager: CLLocationManager
    private lazy var regionRegistrationCoordinator = RegionRegistrationCoordinator(
        monitor: locationManager,
        getCallbackHandle: NativeGeofencePersistence.getRegionCallbackHandle,
        setCallbackHandle: NativeGeofencePersistence.setRegionCallbackHandle,
        removeCallbackHandle: NativeGeofencePersistence.removeRegionCallbackHandle,
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
    
    private var headlessFlutterEngine: FlutterEngine? = nil
    private var nativeGeofenceBackgroundApi: NativeGeofenceBackgroundApiImpl? = nil
    private var headlessSessionId: UUID? = nil
    private var callbackBackgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    
    init(
        flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?,
        eventDeduplicator: IosGeofenceEventDeduplicator = IosGeofenceEventDeduplicator()
    ) {
        self.flutterPluginRegistrantCallback = flutterPluginRegistrantCallback
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
        initialTrigger: Bool,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        let committedRegistration = regionRegistrationCoordinator.start(
            region: region,
            callbackHandle: callbackHandle,
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
        guard let publicRegion = initialStateRequestGate.consumeBoundaryEvent(
            for: region
        ) else {
            log.debug("Ignoring stale enter for geofence ID: \(region.identifier)")
            return
        }
        handleRegionEvent(event: .enter, region: publicRegion)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        log.debug("didExitRegion for geofence ID: \(region.identifier)")
        guard let publicRegion = initialStateRequestGate.consumeBoundaryEvent(
            for: region
        ) else {
            log.debug("Ignoring stale exit for geofence ID: \(region.identifier)")
            return
        }
        handleRegionEvent(event: .exit, region: publicRegion)
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

        guard let backgroundApi = nativeGeofenceBackgroundApi ?? createFlutterEngine() else {
            NativeGeofenceDiagnostics.record(
                .enqueue,
                succeeded: false,
                outcome: "runtime_unavailable",
                geofenceCount: 1
            )
            return
        }
        guard headlessSessionId != nil else {
            backgroundApi.forceCleanup(
                reason: "Headless Flutter session identifier was unavailable."
            )
            return
        }

        let params = GeofenceCallbackParamsWire(
            geofences: [activeGeofence],
            event: event,
            eventAtMillis: eventAtMillis,
            callbackHandle: callbackHandle,
            eventId: UUID().uuidString
        )

        guard backgroundApi.geofenceTriggered(params: params) else {
            NativeGeofenceDiagnostics.record(
                .enqueue,
                succeeded: false,
                outcome: "session_rejected",
                geofenceCount: 1
            )
            log.error("Background callback queue rejected geofence ID=\(activeGeofence.id).")
            backgroundApi.forceCleanup(
                reason: "Rejected geofence callback from an inactive session."
            )
            return
        }
        NativeGeofenceDiagnostics.record(
            .enqueue,
            succeeded: true,
            outcome: "session_enqueued",
            geofenceCount: 1
        )
        eventDeduplicator.recordAccepted(
            id: activeGeofence.id,
            transition: transition,
            eventAtMillis: eventAtMillis
        )
        log.debug("Geofence trigger event sent.")
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

    private func beginCallbackBackgroundTask(sessionId: UUID) {
        guard headlessSessionId == sessionId,
              callbackBackgroundTaskIdentifier == .invalid
        else { return }
        callbackBackgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: callbackBackgroundTaskName
        ) { [weak self] in
            guard let self, self.headlessSessionId == sessionId else { return }
            let reason = "iOS expired the geofence callback background task."
            if let backgroundApi = self.nativeGeofenceBackgroundApi {
                backgroundApi.forceCleanup(reason: reason)
            } else {
                self.log.error("\(reason)")
                self.cleanupHeadlessFlutterEngine(sessionId: sessionId)
            }
        }
        if callbackBackgroundTaskIdentifier == .invalid {
            log.error("Failed to begin iOS background task for geofence callback.")
        } else {
            log.debug("Began iOS background task for geofence callback.")
        }
    }

    private func cleanupHeadlessFlutterEngine(sessionId: UUID) {
        guard headlessSessionId == sessionId else {
            log.debug("Ignoring cleanup from an inactive headless Flutter session.")
            return
        }
        if let engine = headlessFlutterEngine {
            NativeGeofenceBackgroundApiSetup.setUp(
                binaryMessenger: engine.binaryMessenger,
                api: nil
            )
        }
        nativeGeofenceBackgroundApi = nil
        headlessFlutterEngine?.destroyContext()
        headlessFlutterEngine = nil
        headlessSessionId = nil
        endCallbackBackgroundTaskIfNeeded()
        log.debug("Flutter engine cleanup complete.")
    }

    private func endCallbackBackgroundTaskIfNeeded() {
        guard callbackBackgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(callbackBackgroundTaskIdentifier)
        callbackBackgroundTaskIdentifier = .invalid
        log.debug("Ended iOS background task for geofence callback.")
    }

    private func createFlutterEngine() -> NativeGeofenceBackgroundApiImpl? {
        guard let callbackDispatcherHandle = NativeGeofencePersistence.getCallbackDispatcherHandle() else {
            log.error("Callback dispatcher not found in UserDefaults.")
            return nil
        }
        
        guard let callbackDispatcherInfo = FlutterCallbackCache.lookupCallbackInformation(callbackDispatcherHandle) else {
            log.error("Callback dispatcher not found.")
            return nil
        }

        let sessionId = UUID()
        let engine = FlutterEngine(
            name: Constants.HEADLESS_FLUTTER_ENGINE_NAME,
            project: nil,
            allowHeadlessExecution: true
        )
        let backgroundApi = NativeGeofenceBackgroundApiImpl(
            binaryMessenger: engine.binaryMessenger,
            cleanup: { [weak self] in
                self?.cleanupHeadlessFlutterEngine(sessionId: sessionId)
            }
        )
        headlessSessionId = sessionId
        headlessFlutterEngine = engine
        nativeGeofenceBackgroundApi = backgroundApi
        beginCallbackBackgroundTask(sessionId: sessionId)
        guard headlessSessionId == sessionId else { return nil }
        NativeGeofenceBackgroundApiSetup.setUp(
            binaryMessenger: engine.binaryMessenger,
            api: backgroundApi
        )
        log.debug("A new headless Flutter callback session has been created.")

        // Start the engine at the specified callback method.
        guard engine.run(
            withEntrypoint: callbackDispatcherInfo.callbackName,
            libraryURI: callbackDispatcherInfo.callbackLibraryPath
        ) else {
            log.error("Failed to start the headless Flutter engine.")
            backgroundApi.forceCleanup(
                reason: "Failed to start the headless Flutter engine."
            )
            return nil
        }
        // Once our headless runner has been started, we need to register the application's plugins
        // with the runner in order for them to work on the background isolate.
        // `flutterPluginRegistrantCallback` is a callback set from AppDelegate in the main application.
        // This callback should register all relevant plugins (excluding those which require UI).
        flutterPluginRegistrantCallback?(engine)
        log.debug("Flutter engine started and plugins registered.")

        return backgroundApi
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
