import CoreLocation
import Foundation
import XCTest
@testable import RegionRegistrationCore

final class PluginOwnershipTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var previousPersistenceDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "\(Constants.PACKAGE_NAME).ownership.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        previousPersistenceDefaults = NativeGeofencePersistence
            .replacePersistentStateForTesting(defaults)
    }

    override func tearDown() {
        NativeGeofencePersistence.replacePersistentStateForTesting(
            previousPersistenceDefaults
        )
        defaults.removePersistentDomain(forName: suiteName)
        previousPersistenceDefaults = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testCallbackIdsExcludeMalformedValues() {
        defaults.set(
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
        defaults.set(
            [
                "valid": NSNumber(value: 42),
                "malformed": "not-a-callback-handle",
            ],
            forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
        )
        defaults.set(
            ["valid": "package"],
            forKey: Constants.GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_DICT_KEY
        )

        NativeGeofencePersistence.removeAllRegionCallbackHandles()

        XCTAssertTrue(NativeGeofencePersistence.getRegionCallbackIds().isEmpty)
        XCTAssertEqual(
            defaults.dictionary(
                forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
            )?.count,
            0
        )
        XCTAssertEqual(
            defaults.dictionary(
                forKey: Constants.GEOFENCE_CALLBACK_PACKAGE_FINGERPRINT_DICT_KEY
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
        NativeGeofencePersistence.setRegionCallbackPackageFingerprint(
            id: "office",
            fingerprint: "old-office-package"
        )
        defaults.set(
            ["office": ["event": "enter", "atMillis": NSNumber(value: 1_000)]],
            forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY
        )
        XCTAssertTrue(NativeGeofencePersistence.setSynchronizationFingerprint("old-registration"))
        XCTAssertTrue(NativeGeofencePersistence.setSynchronizedPackageFingerprint("old-package"))
        let snapshot = NativeGeofencePersistence.synchronizationSnapshot()

        NativeGeofencePersistence.setRegionCallbackHandle(id: "office", handle: 99)
        NativeGeofencePersistence.setRegionCallbackContext(id: "office", context: 100)
        NativeGeofencePersistence.setRegionCallbackPackageFingerprint(
            id: "office",
            fingerprint: "new-office-package"
        )
        defaults.set([:], forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY)
        XCTAssertTrue(NativeGeofencePersistence.setSynchronizationFingerprint("new-registration"))
        XCTAssertTrue(NativeGeofencePersistence.setSynchronizedPackageFingerprint("new-package"))

        XCTAssertTrue(NativeGeofencePersistence.restoreSynchronizationSnapshot(snapshot))
        XCTAssertEqual(NativeGeofencePersistence.getRegionCallbackHandle(id: "office"), 41)
        XCTAssertEqual(NativeGeofencePersistence.getRegionCallbackContext(id: "office"), 71)
        XCTAssertEqual(
            NativeGeofencePersistence.getRegionCallbackPackageFingerprint(id: "office"),
            "old-office-package"
        )
        XCTAssertEqual(NativeGeofencePersistence.getSynchronizationFingerprint(), "old-registration")
        XCTAssertEqual(NativeGeofencePersistence.getSynchronizedPackageFingerprint(), "old-package")
        let restoredDedup = defaults.dictionary(
            forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY
        )?["office"] as? [String: Any]
        XCTAssertEqual((restoredDedup?["atMillis"] as? NSNumber)?.int64Value, 1_000)
    }

    func testPartialSynchronizationPreservesAuthoritativeAndOutsideScopeEvidence() {
        NativeGeofencePersistence.setRegionCallbackHandle(id: "office", handle: 41)
        NativeGeofencePersistence.setRegionCallbackHandle(id: "warehouse", handle: 42)
        NativeGeofencePersistence.setRegionCallbackPackageFingerprint(
            id: "office",
            fingerprint: "old-office-package"
        )
        NativeGeofencePersistence.setRegionCallbackPackageFingerprint(
            id: "warehouse",
            fingerprint: "old-warehouse-package"
        )
        XCTAssertTrue(
            NativeGeofencePersistence.setSynchronizationFingerprint("authoritative")
        )
        XCTAssertTrue(
            NativeGeofencePersistence.setSynchronizedPackageFingerprint("global-old")
        )

        XCTAssertTrue(
            NativeGeofencePersistence.commitPartialSynchronization(
                ids: ["office"],
                packageFingerprint: "current"
            )
        )

        XCTAssertEqual(
            NativeGeofencePersistence.getSynchronizationFingerprint(),
            "authoritative"
        )
        XCTAssertEqual(
            NativeGeofencePersistence.getSynchronizedPackageFingerprint(),
            "global-old"
        )
        XCTAssertEqual(
            NativeGeofencePersistence.getRegionCallbackPackageFingerprint(id: "office"),
            "current"
        )
        XCTAssertEqual(
            NativeGeofencePersistence.getRegionCallbackPackageFingerprint(id: "warehouse"),
            "old-warehouse-package"
        )
        XCTAssertTrue(
            NativeGeofencePersistence.callbackPackageFingerprintsCurrent(
                ids: ["office"],
                currentFingerprint: "current"
            )
        )
        XCTAssertFalse(
            NativeGeofencePersistence.callbackPackageFingerprintsCurrent(
                ids: ["warehouse"],
                currentFingerprint: "current"
            )
        )
    }

    func testAuthoritativeSynchronizationPublishesGlobalAndPerRegistrationEvidence() {
        NativeGeofencePersistence.setRegionCallbackHandle(id: "office", handle: 41)
        NativeGeofencePersistence.setRegionCallbackHandle(id: "warehouse", handle: 42)

        XCTAssertTrue(
            NativeGeofencePersistence.commitAuthoritativeSynchronization(
                registrationFingerprint: "authoritative",
                packageFingerprint: "current"
            )
        )

        XCTAssertEqual(
            NativeGeofencePersistence.getSynchronizationFingerprint(),
            "authoritative"
        )
        XCTAssertEqual(
            NativeGeofencePersistence.getSynchronizedPackageFingerprint(),
            "current"
        )
        XCTAssertTrue(
            NativeGeofencePersistence.callbackPackageFingerprintsCurrent(
                ids: ["office", "warehouse"],
                currentFingerprint: "current"
            )
        )
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

}
