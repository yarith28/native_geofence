import CoreLocation
import Flutter
import OSLog
import UIKit

public class NativeGeofenceApiImpl: NSObject, NativeGeofenceApi {
    private let log = Logger(subsystem: Constants.PACKAGE_NAME, category: "NativeGeofenceApiImpl")
    
    private let locationManagerDelegate: LocationManagerDelegate
    
    init(registerPlugins: FlutterPluginRegistrantCallback) {
        self.locationManagerDelegate = LocationManagerDelegate(flutterPluginRegistrantCallback: registerPlugins)
    }
    
    func initialize(callbackDispatcherHandle: Int64) throws {
        NativeGeofencePersistence.setCallbackDispatcherHandle(callbackDispatcherHandle)
    }
    
    func createGeofence(geofence: GeofenceWire, completion: @escaping (Result<Void, any Error>) -> Void) {
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
    
    func reCreateAfterReboot() throws {
        log.info("Re-create after reboot called. iOS handles this automatically, nothing for us to do here.")
    }
    
    func getGeofenceIds() throws -> [String] {
        var geofenceIds: [String] = []
        for region in locationManagerDelegate.locationManager.monitoredRegions {
            geofenceIds.append(region.identifier)
        }
        log.debug("getGeofenceIds() found \(geofenceIds.count) geofence(s).")
        return geofenceIds
    }
    
    func getGeofences() throws -> [ActiveGeofenceWire] {
        var geofences: [ActiveGeofenceWire] = []
        for region in locationManagerDelegate.locationManager.monitoredRegions {
            if let activeGeofence = ActiveGeofenceWires.fromRegion(region) {
                geofences.append(activeGeofence)
            } else {
                log.error("Unknown region type: \(region)")
            }
        }
        log.debug("getGeofences() found \(geofences.count) geofence(s).")
        return geofences
    }
    
    func removeGeofenceById(id: String, completion: @escaping (Result<Void, any Error>) -> Void) {
        locationManagerDelegate.cancelMonitoringStart(id: id)
        var removedCount = 0
        for region in locationManagerDelegate.locationManager.monitoredRegions {
            if region.identifier == id {
                locationManagerDelegate.locationManager.stopMonitoring(for: region)
                NativeGeofencePersistence.removeRegionCallbackHandle(id: region.identifier)
                removedCount += 1
            }
        }
        log.debug("Removed \(removedCount) geofence(s) with ID=\(id).")
        completion(.success(()))
    }
    
    func removeAllGeofences(completion: @escaping (Result<Void, any Error>) -> Void) {
        locationManagerDelegate.cancelAllMonitoringStarts()
        var removedCount = 0
        for region in locationManagerDelegate.locationManager.monitoredRegions {
            locationManagerDelegate.locationManager.stopMonitoring(for: region)
            NativeGeofencePersistence.removeRegionCallbackHandle(id: region.identifier)
            removedCount += 1
        }
        log.debug("Removed \(removedCount) geofence(s).")
        completion(.success(()))
    }
}
