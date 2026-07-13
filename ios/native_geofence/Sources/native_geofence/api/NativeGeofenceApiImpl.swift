import CoreLocation
import Foundation
import Flutter
import OSLog
import UIKit

public class NativeGeofenceApiImpl: NSObject, NativeGeofenceApi {
    private let log = Logger(subsystem: Constants.PACKAGE_NAME, category: "NativeGeofenceApiImpl")
    private let locationServicesQueue = DispatchQueue(
        label: "\(Constants.PACKAGE_NAME).location-services",
        qos: .utility
    )
    private let createPreflightRegistry = GeofenceCreatePreflightRegistry { failure in
        nativeGeofenceError(
            .iosRegionMonitoringFailed,
            message: failure.message
        )
    }
    
    private let locationManagerDelegate: LocationManagerDelegate
    
    init(registerPlugins: FlutterPluginRegistrantCallback) {
        self.locationManagerDelegate = LocationManagerDelegate(flutterPluginRegistrantCallback: registerPlugins)
    }
    
    func initialize(callbackDispatcherHandle: Int64) throws {
        NativeGeofencePersistence.setCallbackDispatcherHandle(callbackDispatcherHandle)
    }
    
    func createGeofence(geofence: GeofenceWire, completion: @escaping (Result<Void, any Error>) -> Void) {
        guard let preflightToken = createPreflightRegistry.begin(
            id: geofence.id,
            completion: completion
        ) else {
            return
        }

        locationServicesQueue.async { [self] in
            let locationServicesEnabled = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async { [self] in
                guard let completion = createPreflightRegistry.takeIfPending(
                    preflightToken
                ) else {
                    return
                }
                createGeofence(
                    geofence: geofence,
                    locationServicesEnabled: locationServicesEnabled,
                    completion: completion
                )
            }
        }
    }

    private func createGeofence(
        geofence: GeofenceWire,
        locationServicesEnabled: Bool,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            completion(
                .failure(
                    nativeGeofenceError(
                        .iosRegionMonitoringFailed,
                        message: "iOS region monitoring is not available on this device."
                    )
                )
            )
            return
        }

        if let failure = IosGeofencePreflight.failure(
            locationServicesEnabled: locationServicesEnabled,
            authorizationStatus: locationManagerDelegate.locationManager.authorizationStatus
        ) {
            completion(.failure(nativeGeofenceError(failure)))
            return
        }

        let maximumRadius = locationManagerDelegate.locationManager.maximumRegionMonitoringDistance
        guard let radius = IosRegionRadius.normalized(
            requestedRadius: geofence.radiusMeters,
            maximumRadius: maximumRadius
        ) else {
            completion(
                .failure(
                    nativeGeofenceError(
                        .invalidArguments,
                        message: "Geofence radius must be finite and strictly positive."
                    )
                )
            )
            return
        }

        let region = CLCircularRegion(
            center: CLLocationCoordinate2DMake(geofence.location.latitude, geofence.location.longitude),
            radius: radius,
            identifier: geofence.id
        )
        region.notifyOnEntry = geofence.triggers.contains(.enter)
        region.notifyOnExit = geofence.triggers.contains(.exit)

        if radius != geofence.radiusMeters {
            log.info(
                "Clamped geofence ID=\(geofence.id) radius from \(geofence.radiusMeters) to \(radius)."
            )
        }

        locationManagerDelegate.startMonitoring(
            region: region,
            callbackHandle: geofence.callbackHandle,
            initialTrigger: geofence.iosSettings.initialTrigger,
            completion: completion
        )
    }
    
    func reCreateAfterReboot(completion: @escaping (Result<Void, Error>) -> Void) {
        log.info("Re-create after reboot called. iOS handles this automatically, nothing for us to do here.")
        completion(.success(()))
    }
    
    func getGeofenceIds() throws -> [String] {
        let geofenceIds = ownedMonitoredRegions()
            .map(\.identifier)
            .sorted()
        log.debug("getGeofenceIds() found \(geofenceIds.count) geofence(s).")
        return geofenceIds
    }
    
    func getGeofences() throws -> [ActiveGeofenceWire] {
        var geofences: [ActiveGeofenceWire] = []
        for region in ownedMonitoredRegions() {
            if let activeGeofence = ActiveGeofenceWires.fromRegion(region) {
                geofences.append(activeGeofence)
            } else {
                log.error("Unable to convert owned region: \(region)")
            }
        }
        log.debug("getGeofences() found \(geofences.count) geofence(s).")
        return geofences
    }
    
    func removeGeofenceById(id: String, completion: @escaping (Result<Void, any Error>) -> Void) {
        createPreflightRegistry.cancel(id: id)
        // Snapshot ownership before cancellation removes callback metadata.
        let regions = ownedMonitoredRegions().filter { $0.identifier == id }
        locationManagerDelegate.cancelMonitoringStart(id: id)
        for region in regions {
            locationManagerDelegate.recordRemoval(of: region)
            locationManagerDelegate.locationManager.stopMonitoring(for: region)
        }
        NativeGeofencePersistence.removeRegionCallbackHandle(id: id)
        log.debug("Removed \(regions.count) geofence(s) with ID=\(id).")
        completion(.success(()))
    }
    
    func removeAllGeofences(completion: @escaping (Result<Void, any Error>) -> Void) {
        createPreflightRegistry.cancelAll()
        // CLLocationManager.monitoredRegions is app-wide. Snapshot only regions
        // backed by plugin callback metadata before clearing that metadata.
        let regions = ownedMonitoredRegions()
        locationManagerDelegate.cancelAllMonitoringStarts()
        for region in regions {
            locationManagerDelegate.recordRemoval(of: region)
            locationManagerDelegate.locationManager.stopMonitoring(for: region)
        }
        NativeGeofencePersistence.removeAllRegionCallbackHandles()
        log.debug("Removed \(regions.count) geofence(s).")
        completion(.success(()))
    }

    private func ownedMonitoredRegions() -> [CLCircularRegion] {
        PluginOwnedRegions.select(
            from: locationManagerDelegate.locationManager.monitoredRegions,
            callbackIds: NativeGeofencePersistence.getRegionCallbackIds()
        )
    }
}
