import CoreLocation
import Flutter
import OSLog

// Singleton class
class LocationManagerDelegate: NSObject, CLLocationManagerDelegate {
    // Prevent multiple instances of CLLocationManager to avoid duplicate triggers.
    private static var sharedLocationManager: CLLocationManager?
    
    private let log = Logger(subsystem: Constants.PACKAGE_NAME, category: "LocationManagerDelegate")
    
    private let flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?
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
        },
        invalidateMatchingCommittedRegion: { [weak self] region in
            self?.initialStateRequestGate.remove(matching: region) ?? false
        }
    )
    private let initialStateRequestGate = InitialStateRequestGate()
    
    private var headlessFlutterEngine: FlutterEngine? = nil
    private var nativeGeofenceBackgroundApi: NativeGeofenceBackgroundApiImpl? = nil
    
    init(flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?) {
        self.flutterPluginRegistrantCallback = flutterPluginRegistrantCallback
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
    }

    func cancelAllMonitoringStarts() {
        initialStateRequestGate.removeAll()
        regionRegistrationCoordinator.cancelAll()
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
        
        guard let callbackHandle = NativeGeofencePersistence.getRegionCallbackHandle(id: activeGeofence.id) else {
            log.error("Callback handle for region \(activeGeofence.id) not found.")
            return
        }
        
        let params = GeofenceCallbackParamsWire(geofences: [activeGeofence], event: event, callbackHandle: callbackHandle)
        
        guard let backgroundApi = nativeGeofenceBackgroundApi ?? createFlutterEngine() else {
            return
        }
        
        // Shutdown the engine once the Geofence event is handled
        func cleanup() {
            nativeGeofenceBackgroundApi = nil
            headlessFlutterEngine?.destroyContext()
            headlessFlutterEngine = nil
            log.debug("Flutter engine cleanup complete.")
        }
        
        nativeGeofenceBackgroundApi!.geofenceTriggered(params: params, cleanup: cleanup)
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
        regionRegistrationCoordinator.didFailMonitoring(for: region, error: error)
    }

    private func applyInitialStateContract(
        _ committedRegistration: CommittedRegionRegistration?,
        using manager: CLLocationManager
    ) {
        guard let committedRegistration else { return }
        guard let probe = initialStateRequestGate.commit(
            region: committedRegistration.region,
            initialTrigger: committedRegistration.initialTrigger
        ) else { return }
        manager.requestState(for: probe)
    }
    
    private func createFlutterEngine() -> NativeGeofenceBackgroundApiImpl? {
        // Create a Flutter engine
        headlessFlutterEngine = FlutterEngine(name: Constants.HEADLESS_FLUTTER_ENGINE_NAME, project: nil, allowHeadlessExecution: true)
        log.debug("A new headless Flutter engine has been created.")
        
        guard let callbackDispatcherHandle = NativeGeofencePersistence.getCallbackDispatcherHandle() else {
            log.error("Callback dispatcher not found in UserDefaults.")
            return nil
        }
        
        guard let callbackDispatcherInfo = FlutterCallbackCache.lookupCallbackInformation(callbackDispatcherHandle) else {
            log.error("Callback dispatcher not found.")
            return nil
        }
        
        // Start the engine at the specified callback method.
        headlessFlutterEngine!.run(withEntrypoint: callbackDispatcherInfo.callbackName, libraryURI: callbackDispatcherInfo.callbackLibraryPath)
        // Once our headless runner has been started, we need to register the application's plugins
        // with the runner in order for them to work on the background isolate.
        // `flutterPluginRegistrantCallback` is a callback set from AppDelegate in the main application.
        // This callback should register all relevant plugins (excluding those which require UI).
        flutterPluginRegistrantCallback?(headlessFlutterEngine!)
        log.debug("Flutter engine started and plugins registered.")
        
        nativeGeofenceBackgroundApi = NativeGeofenceBackgroundApiImpl(binaryMessenger: headlessFlutterEngine!.binaryMessenger)
        NativeGeofenceBackgroundApiSetup.setUp(binaryMessenger: headlessFlutterEngine!.binaryMessenger, api: nativeGeofenceBackgroundApi)
        log.debug("NativeGeofenceBackgroundApi initialized.")

        return nativeGeofenceBackgroundApi
    }
}
