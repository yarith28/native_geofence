import CoreLocation
import XCTest
@testable import RegionRegistrationCore

final class InitialStateRequestGateTests: XCTestCase {
    func testUnsolicitedPublicStateResponseIsIgnored() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(id: "office")
        XCTAssertNil(gate.commit(region: publicRegion, initialTrigger: false))

        XCTAssertNil(gate.consumeInitialStateResponse(for: publicRegion))
    }

    func testExplicitProbeIsPrivateOneShotAndMapsBackToPublicRegion() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(
            id: "office",
            latitude: 11.56,
            radius: 125,
            notifyOnEntry: false,
            notifyOnExit: true
        )
        let probe = try! XCTUnwrap(
            gate.commit(region: publicRegion, initialTrigger: true)
        )

        XCTAssertNotEqual(probe.identifier, publicRegion.identifier)
        XCTAssertEqual(probe.center.latitude, publicRegion.center.latitude)
        XCTAssertEqual(probe.center.longitude, publicRegion.center.longitude)
        XCTAssertEqual(probe.radius, publicRegion.radius)
        XCTAssertEqual(probe.notifyOnEntry, publicRegion.notifyOnEntry)
        XCTAssertEqual(probe.notifyOnExit, publicRegion.notifyOnExit)
        XCTAssertTrue(gate.consumeInitialStateResponse(for: probe) === publicRegion)
        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
    }

    func testPublicStateDoesNotConsumePendingPrivateProbe() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(id: "office")
        let probe = try! XCTUnwrap(
            gate.commit(region: publicRegion, initialTrigger: true)
        )

        XCTAssertNil(gate.consumeInitialStateResponse(for: publicRegion))
        XCTAssertTrue(gate.consumeInitialStateResponse(for: probe) === publicRegion)
    }

    func testSameIdReplacementInvalidatesTheOlderProbe() {
        let gate = InitialStateRequestGate()
        let oldProbe = try! XCTUnwrap(
            gate.commit(
                region: region(id: "office", latitude: 1),
                initialTrigger: true
            )
        )
        let currentRegion = region(id: "office", latitude: 2)
        let currentProbe = try! XCTUnwrap(
            gate.commit(region: currentRegion, initialTrigger: true)
        )

        XCTAssertNil(gate.consumeInitialStateResponse(for: oldProbe))
        XCTAssertTrue(
            gate.consumeInitialStateResponse(for: currentProbe) === currentRegion
        )
    }

    func testReplacementWithoutInitialTriggerInvalidatesTheOlderProbe() {
        let gate = InitialStateRequestGate()
        let oldProbe = try! XCTUnwrap(
            gate.commit(
                region: region(id: "office", radius: 50),
                initialTrigger: true
            )
        )
        let replacementRegion = region(id: "office", radius: 100)

        XCTAssertNil(
            gate.commit(region: replacementRegion, initialTrigger: false)
        )

        XCTAssertNil(gate.consumeInitialStateResponse(for: oldProbe))
        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: replacementRegion) === replacementRegion
        )
    }

    func testBoundaryWithoutPendingProbePassesThrough() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(id: "office")
        _ = gate.commit(region: publicRegion, initialTrigger: false)

        XCTAssertTrue(gate.consumeBoundaryEvent(for: publicRegion) === publicRegion)
    }

    func testCurrentBoundaryCancelsPendingProbe() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(id: "office")
        let probe = try! XCTUnwrap(
            gate.commit(region: publicRegion, initialTrigger: true)
        )
        let callbackRegion = region(id: "office")

        XCTAssertTrue(gate.consumeBoundaryEvent(for: callbackRegion) === publicRegion)
        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
    }

    func testStaleSameIdBoundaryDoesNotCancelCurrentProbe() {
        let gate = InitialStateRequestGate()
        let currentRegion = region(id: "office", latitude: 2)
        let currentProbe = try! XCTUnwrap(
            gate.commit(region: currentRegion, initialTrigger: true)
        )
        let staleRegion = region(id: "office", latitude: 1)

        XCTAssertNil(gate.consumeBoundaryEvent(for: staleRegion))
        XCTAssertTrue(
            gate.consumeInitialStateResponse(for: currentProbe) === currentRegion
        )
    }

    func testCoreLocationNormalizationWithinToleranceMatchesCurrentBoundary() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(
            id: "office",
            latitude: 11.56,
            longitude: 104.93,
            radius: 100
        )
        let probe = try! XCTUnwrap(
            gate.commit(region: publicRegion, initialTrigger: true)
        )
        let normalizedRegion = region(
            id: "office",
            latitude: 11.56000005,
            longitude: 104.92999995,
            radius: 100.005
        )

        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: normalizedRegion) === publicRegion
        )
        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
    }

    func testPrivateProbeCannotBeRoutedAsBoundaryEvent() {
        let gate = InitialStateRequestGate()
        let probe = try! XCTUnwrap(
            gate.commit(region: region(id: "office"), initialTrigger: true)
        )

        XCTAssertNil(gate.consumeBoundaryEvent(for: probe))
    }

    func testRemovalAndRemoveAllInvalidateAuthority() {
        let gate = InitialStateRequestGate()
        let officeRegion = region(id: "office")
        let homeRegion = region(id: "home")
        let officeProbe = try! XCTUnwrap(
            gate.commit(region: officeRegion, initialTrigger: true)
        )
        let homeProbe = try! XCTUnwrap(
            gate.commit(region: homeRegion, initialTrigger: true)
        )

        gate.remove("office")
        XCTAssertNil(gate.consumeInitialStateResponse(for: officeProbe))
        XCTAssertNil(gate.consumeBoundaryEvent(for: officeRegion))

        gate.removeAll()
        XCTAssertNil(gate.consumeInitialStateResponse(for: homeProbe))
        XCTAssertNil(gate.consumeBoundaryEvent(for: homeRegion))
    }

    func testPendingReplacementBoundaryCannotUsePreviousCommit() {
        let gate = InitialStateRequestGate()
        let previousRegion = region(id: "office", radius: 50)
        let requestedRegion = region(id: "office", radius: 100)
        _ = gate.commit(region: previousRegion, initialTrigger: false)

        XCTAssertNil(gate.consumeBoundaryEvent(for: requestedRegion))
        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: previousRegion) === previousRegion
        )
    }

    func testLatePreviousBoundaryCannotUseReplacementCommit() {
        let gate = InitialStateRequestGate()
        let previousRegion = region(id: "office", radius: 50)
        let replacementRegion = region(id: "office", radius: 100)
        _ = gate.commit(region: previousRegion, initialTrigger: false)
        _ = gate.commit(region: replacementRegion, initialTrigger: false)

        XCTAssertNil(gate.consumeBoundaryEvent(for: previousRegion))
        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: replacementRegion) === replacementRegion
        )
    }

    func testRestoredCommitAuthorizesBoundaryWithoutInitialProbe() {
        let gate = InitialStateRequestGate()
        let restoredRegion = region(id: "office")
        gate.restoreCommittedRegions([restoredRegion])

        XCTAssertNil(gate.consumeInitialStateResponse(for: restoredRegion))
        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: restoredRegion) === restoredRegion
        )
    }

    func testRestoringChangedSemanticsInvalidatesStaleProbe() {
        let gate = InitialStateRequestGate()
        let probe = try! XCTUnwrap(
            gate.commit(
                region: region(id: "office", radius: 50),
                initialTrigger: true
            )
        )
        let restoredRegion = region(id: "office", radius: 100)

        gate.restoreCommittedRegions([restoredRegion])

        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: restoredRegion) === restoredRegion
        )
    }

    private func region(
        id: String,
        latitude: CLLocationDegrees = 0,
        longitude: CLLocationDegrees = 0,
        radius: CLLocationDistance = 100,
        notifyOnEntry: Bool = true,
        notifyOnExit: Bool = true
    ) -> CLCircularRegion {
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: longitude
            ),
            radius: radius,
            identifier: id
        )
        region.notifyOnEntry = notifyOnEntry
        region.notifyOnExit = notifyOnExit
        return region
    }
}
