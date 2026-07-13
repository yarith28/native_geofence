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

        guard case .accepted(let acceptedRegion, let reason) =
            gate.decideBoundaryEvent(for: callbackRegion)
        else {
            return XCTFail("Expected the committed boundary to be accepted.")
        }
        XCTAssertTrue(acceptedRegion === publicRegion)
        XCTAssertEqual(reason, .monitoringSemanticsMatch)
        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
    }

    func testBoundaryUsesCommittedIdentifierWhenCallbackGeometryDiffers() {
        let gate = InitialStateRequestGate()
        let currentRegion = region(id: "office", latitude: 2)
        let currentProbe = try! XCTUnwrap(
            gate.commit(region: currentRegion, initialTrigger: true)
        )
        let staleRegion = region(id: "office", latitude: 1)

        guard case .accepted(let acceptedRegion, let reason) =
            gate.decideBoundaryEvent(for: staleRegion)
        else {
            return XCTFail("Expected the committed identifier to be accepted.")
        }
        XCTAssertTrue(acceptedRegion === currentRegion)
        XCTAssertEqual(reason, .monitoringSemanticsMismatch)
        XCTAssertNil(gate.consumeInitialStateResponse(for: currentProbe))
    }

    func testPendingMutationRejectsMismatchedSemanticsWithoutConsumingProbe() {
        let gate = InitialStateRequestGate()
        let currentRegion = region(id: "office", radius: 50)
        let probe = try! XCTUnwrap(
            gate.commit(region: currentRegion, initialTrigger: true)
        )

        guard case .rejected(let reason) = gate.decideBoundaryEvent(
            for: region(id: "office", radius: 100),
            requireMonitoringSemanticsMatch: true
        ) else {
            return XCTFail("Expected pending replacement ambiguity to be rejected.")
        }
        XCTAssertEqual(reason, .pendingMutationSemanticsMismatch)
        XCTAssertTrue(
            gate.consumeInitialStateResponse(for: probe) === currentRegion
        )
    }

    func testCallbackGeometryAndFlagsAreNotBoundaryAdmissionAuthority() {
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
            latitude: 11.57,
            longitude: 104.94,
            radius: 250,
            notifyOnEntry: false,
            notifyOnExit: false
        )

        guard case .accepted(let acceptedRegion, let reason) =
            gate.decideBoundaryEvent(for: normalizedRegion)
        else {
            return XCTFail("Expected the committed identifier to be accepted.")
        }
        XCTAssertTrue(acceptedRegion === publicRegion)
        XCTAssertEqual(reason, .monitoringSemanticsMismatch)
        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
    }

    func testPrivateProbeCannotBeRoutedAsBoundaryEvent() {
        let gate = InitialStateRequestGate()
        let probe = try! XCTUnwrap(
            gate.commit(region: region(id: "office"), initialTrigger: true)
        )

        XCTAssertNil(gate.consumeBoundaryEvent(for: probe))
        guard case .rejected(let reason) = gate.decideBoundaryEvent(for: probe) else {
            return XCTFail("Expected the private probe to be rejected.")
        }
        XCTAssertEqual(reason, .privateInitialStateProbe)
    }

    func testUnknownBoundaryIdentifierReportsAStableReason() {
        let gate = InitialStateRequestGate()
        _ = gate.commit(region: region(id: "office"), initialTrigger: false)

        guard case .rejected(let reason) = gate.decideBoundaryEvent(
            for: region(id: "home")
        ) else {
            return XCTFail("Expected the unknown identifier to be rejected.")
        }
        XCTAssertEqual(reason, .unknownIdentifier)
    }

    func testNonCircularBoundaryReportsAStableReason() {
        let gate = InitialStateRequestGate()
        _ = gate.commit(region: region(id: "office"), initialTrigger: false)

        guard case .rejected(let reason) = gate.decideBoundaryEvent(
            for: CLBeaconRegion(uuid: UUID(), identifier: "office")
        ) else {
            return XCTFail("Expected the non-circular region to be rejected.")
        }
        XCTAssertEqual(reason, .unsupportedRegionType)
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

    func testBoundaryUsesPreviousCommitUntilReplacementCommits() {
        let gate = InitialStateRequestGate()
        let previousRegion = region(id: "office", radius: 50)
        let requestedRegion = region(id: "office", radius: 100)
        _ = gate.commit(region: previousRegion, initialTrigger: false)

        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: requestedRegion) === previousRegion
        )
    }

    func testBoundaryUsesCurrentCommitAfterReplacement() {
        let gate = InitialStateRequestGate()
        let previousRegion = region(id: "office", radius: 50)
        let replacementRegion = region(id: "office", radius: 100)
        _ = gate.commit(region: previousRegion, initialTrigger: false)
        _ = gate.commit(region: replacementRegion, initialTrigger: false)

        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: previousRegion) === replacementRegion
        )
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
