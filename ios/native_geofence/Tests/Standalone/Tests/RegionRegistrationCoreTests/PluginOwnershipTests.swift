import CoreLocation
import Foundation
import XCTest
@testable import RegionRegistrationCore

final class PluginOwnershipTests: XCTestCase {
    private var previousMapping: Any?
    private var previousContextMapping: Any?
    private var previousDedupMapping: Any?
    private var previousRegistrationFingerprint: Any?
    private var previousPackageFingerprint: Any?

    override func setUp() {
        super.setUp()
        previousMapping = UserDefaults.standard.object(
            forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
        )
        previousContextMapping = UserDefaults.standard.object(
            forKey: Constants.GEOFENCE_CALLBACK_CONTEXT_DICT_KEY
        )
        previousDedupMapping = UserDefaults.standard.object(
            forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY
        )
        previousRegistrationFingerprint = UserDefaults.standard.object(
            forKey: Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY
        )
        previousPackageFingerprint = UserDefaults.standard.object(
            forKey: Constants.SYNCHRONIZED_PACKAGE_FINGERPRINT_KEY
        )
        UserDefaults.standard.removeObject(
            forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
        )
        UserDefaults.standard.removeObject(
            forKey: Constants.GEOFENCE_CALLBACK_CONTEXT_DICT_KEY
        )
        UserDefaults.standard.removeObject(
            forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY
        )
        UserDefaults.standard.removeObject(
            forKey: Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY
        )
        UserDefaults.standard.removeObject(
            forKey: Constants.SYNCHRONIZED_PACKAGE_FINGERPRINT_KEY
        )
    }

    override func tearDown() {
        if let previousMapping {
            UserDefaults.standard.set(
                previousMapping,
                forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
            )
        }
        if let previousContextMapping {
            UserDefaults.standard.set(
                previousContextMapping,
                forKey: Constants.GEOFENCE_CALLBACK_CONTEXT_DICT_KEY
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: Constants.GEOFENCE_CALLBACK_CONTEXT_DICT_KEY
            )
        }
        restore(previousDedupMapping, key: Constants.GEOFENCE_LAST_EVENT_DICT_KEY)
        restore(
            previousRegistrationFingerprint,
            key: Constants.SYNCHRONIZATION_REGISTRATION_FINGERPRINT_KEY
        )
        restore(
            previousPackageFingerprint,
            key: Constants.SYNCHRONIZED_PACKAGE_FINGERPRINT_KEY
        )
        super.tearDown()
    }

    func testCallbackIdsExcludeMalformedValues() {
        UserDefaults.standard.set(
            [
                "valid": NSNumber(value: 42),
                "malformed": "not-a-callback-handle",
            ],
            forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
        )

        XCTAssertEqual(NativeGeofencePersistence.getRegionCallbackIds(), ["valid"])
        XCTAssertTrue(NativeGeofencePersistence.hasRegionCallbackHandle(id: "valid"))
        XCTAssertFalse(NativeGeofencePersistence.hasRegionCallbackHandle(id: "malformed"))
    }

    func testRemoveAllCallbackHandlesClearsValidAndMalformedEntries() {
        UserDefaults.standard.set(
            [
                "valid": NSNumber(value: 42),
                "malformed": "not-a-callback-handle",
            ],
            forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
        )

        NativeGeofencePersistence.removeAllRegionCallbackHandles()

        XCTAssertTrue(NativeGeofencePersistence.getRegionCallbackIds().isEmpty)
        XCTAssertEqual(
            UserDefaults.standard.dictionary(
                forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
            )?.count,
            0
        )
    }

    func testCallbackContextRoundTripsAndTerminalClearRemovesIt() {
        NativeGeofencePersistence.setRegionCallbackContext(id: "office", context: 71)

        XCTAssertEqual(
            NativeGeofencePersistence.getRegionCallbackContext(id: "office"),
            71
        )
        NativeGeofencePersistence.setRegionCallbackContext(id: "office", context: nil)
        XCTAssertNil(NativeGeofencePersistence.getRegionCallbackContext(id: "office"))

        NativeGeofencePersistence.setRegionCallbackContext(id: "home", context: 72)
        NativeGeofencePersistence.removeAllRegionCallbackContexts()
        XCTAssertNil(NativeGeofencePersistence.getRegionCallbackContext(id: "home"))
    }

    func testSynchronizationSnapshotRestoresMetadataDedupAndFingerprints() {
        NativeGeofencePersistence.setRegionCallbackHandle(id: "office", handle: 41)
        NativeGeofencePersistence.setRegionCallbackContext(id: "office", context: 71)
        UserDefaults.standard.set(
            ["office": ["event": "enter", "atMillis": NSNumber(value: 1_000)]],
            forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY
        )
        XCTAssertTrue(NativeGeofencePersistence.setSynchronizationFingerprint("old-registration"))
        XCTAssertTrue(NativeGeofencePersistence.setSynchronizedPackageFingerprint("old-package"))
        let snapshot = NativeGeofencePersistence.synchronizationSnapshot()

        NativeGeofencePersistence.setRegionCallbackHandle(id: "office", handle: 99)
        NativeGeofencePersistence.setRegionCallbackContext(id: "office", context: 100)
        UserDefaults.standard.set([:], forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY)
        XCTAssertTrue(NativeGeofencePersistence.setSynchronizationFingerprint("new-registration"))
        XCTAssertTrue(NativeGeofencePersistence.setSynchronizedPackageFingerprint("new-package"))

        XCTAssertTrue(NativeGeofencePersistence.restoreSynchronizationSnapshot(snapshot))
        XCTAssertEqual(NativeGeofencePersistence.getRegionCallbackHandle(id: "office"), 41)
        XCTAssertEqual(NativeGeofencePersistence.getRegionCallbackContext(id: "office"), 71)
        XCTAssertEqual(NativeGeofencePersistence.getSynchronizationFingerprint(), "old-registration")
        XCTAssertEqual(NativeGeofencePersistence.getSynchronizedPackageFingerprint(), "old-package")
        let restoredDedup = UserDefaults.standard.dictionary(
            forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY
        )?["office"] as? [String: Any]
        XCTAssertEqual((restoredDedup?["atMillis"] as? NSNumber)?.int64Value, 1_000)
    }

    func testOwnedRegionsExcludeForeignAndNonCircularRegions() {
        let ownedCircle = circularRegion(id: "owned-circle")
        let foreignCircle = circularRegion(id: "foreign-circle")
        let mappedBeacon = CLBeaconRegion(
            uuid: UUID(),
            identifier: "mapped-beacon"
        )
        let monitoredRegions: Set<CLRegion> = [
            ownedCircle,
            foreignCircle,
            mappedBeacon,
        ]

        let selected = PluginOwnedRegions.select(
            from: monitoredRegions,
            callbackIds: ["owned-circle", "mapped-beacon"]
        )

        XCTAssertEqual(selected.count, 1)
        XCTAssertTrue(selected[0] === ownedCircle)
    }

    private func circularRegion(id: String) -> CLCircularRegion {
        CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: 11.56, longitude: 104.93),
            radius: 100,
            identifier: id
        )
    }

    private func restore(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
