import CoreLocation
import Foundation
import XCTest
@testable import RegionRegistrationCore

final class PluginOwnershipTests: XCTestCase {
    private var previousMapping: Any?

    override func setUp() {
        super.setUp()
        previousMapping = UserDefaults.standard.object(
            forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
        )
        UserDefaults.standard.removeObject(
            forKey: Constants.GEOFENCE_CALLBACK_DICT_KEY
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
