import XCTest
@testable import RegionRegistrationCore

final class IosGeofenceSynchronizationPlannerTests: XCTestCase {
    func testFingerprintPreservesV1FieldOrderAndCanonicalSorting() {
        let fingerprint = IosGeofenceSynchronizationPlanner
            .desiredRegistrationFingerprint([
                registration(id: "office", triggers: ["exit", "enter"]),
                registration(id: "home", callbackContext: 9),
            ])

        XCTAssertEqual(
            fingerprint,
            "{\"version\":1,\"platform\":\"ios\",\"registrations\":["
                + "{\"id\":\"home\",\"latitude\":11.56,\"longitude\":104.93,"
                + "\"radiusMeters\":100.0,\"triggers\":[\"enter\"],"
                + "\"callbackHandle\":7,\"callbackContext\":9},"
                + "{\"id\":\"office\",\"latitude\":11.56,\"longitude\":104.93,"
                + "\"radiusMeters\":100.0,\"triggers\":[\"enter\",\"exit\"],"
                + "\"callbackHandle\":7,\"callbackContext\":null}]}"
        )
    }

    func testExactCurrentStateIsAuthoritativeNoOp() {
        let desired = [registration(id: "office")]
        let fingerprint = IosGeofenceSynchronizationPlanner
            .desiredRegistrationFingerprint(desired)

        let decision = IosGeofenceSynchronizationPlanner.decide(
            current: inventory(
                registrations: desired,
                registrationFingerprint: fingerprint
            ),
            desired: desired,
            removeUnlisted: true
        )

        XCTAssertFalse(decision.requiresSynchronization)
        XCTAssertTrue(decision.reasons.isEmpty)
        XCTAssertEqual(decision.previousCount, 1)
    }

    func testPartialDecisionIgnoresTheUnrelatedAuthoritativeFingerprint() {
        let desired = [registration(id: "office")]
        let decision = IosGeofenceSynchronizationPlanner.decide(
            current: IosGeofenceSynchronizationInventory(
                pluginOwnedIds: ["office", "outside-scope"],
                registrations: desired,
                inactiveRegistrationIds: [],
                registrationFingerprint: "authoritative-other-state",
                callbackFingerprintCurrent: true
            ),
            desired: desired,
            removeUnlisted: false
        )

        XCTAssertFalse(decision.requiresSynchronization)
        XCTAssertTrue(decision.reasons.isEmpty)
    }

    func testFreshDecisionReportsEveryAuthoritativeReason() {
        let desired = [registration(id: "office")]
        let decision = IosGeofenceSynchronizationPlanner.decide(
            current: IosGeofenceSynchronizationInventory(
                pluginOwnedIds: [],
                registrations: [],
                inactiveRegistrationIds: [],
                registrationFingerprint: nil,
                callbackFingerprintCurrent: false
            ),
            desired: desired,
            removeUnlisted: true
        )

        XCTAssertEqual(
            decision.reasons,
            [.firstRun, .callbackFingerprintChanged, .registrationDrift]
        )
        XCTAssertTrue(decision.requiresSynchronization)
        XCTAssertEqual(decision.desiredCount, 1)
        XCTAssertEqual(decision.previousCount, 0)
    }

    func testMetadataChangeIsDetectedFromFreshNativeInventory() {
        let desired = [registration(id: "office", callbackHandle: 8)]
        let fingerprint = IosGeofenceSynchronizationPlanner
            .desiredRegistrationFingerprint(desired)
        let current = [registration(id: "office", callbackHandle: 7)]

        let decision = IosGeofenceSynchronizationPlanner.decide(
            current: inventory(
                registrations: current,
                registrationFingerprint: fingerprint
            ),
            desired: desired,
            removeUnlisted: true
        )

        XCTAssertEqual(decision.reasons, [.callbackFingerprintChanged])
    }

    func testInactiveDesiredRegistrationForcesDrift() {
        let desired = [registration(id: "office")]
        let fingerprint = IosGeofenceSynchronizationPlanner
            .desiredRegistrationFingerprint(desired)
        let decision = IosGeofenceSynchronizationPlanner.decide(
            current: IosGeofenceSynchronizationInventory(
                pluginOwnedIds: ["office"],
                registrations: [],
                inactiveRegistrationIds: ["office"],
                registrationFingerprint: fingerprint,
                callbackFingerprintCurrent: true
            ),
            desired: desired,
            removeUnlisted: true
        )

        XCTAssertEqual(decision.reasons, [.registrationDrift])
    }

    private func inventory(
        registrations: [IosGeofenceSynchronizationRegistration],
        registrationFingerprint: String
    ) -> IosGeofenceSynchronizationInventory {
        IosGeofenceSynchronizationInventory(
            pluginOwnedIds: Set(registrations.map(\.id)),
            registrations: registrations,
            inactiveRegistrationIds: [],
            registrationFingerprint: registrationFingerprint,
            callbackFingerprintCurrent: true
        )
    }

    private func registration(
        id: String,
        triggers: [String] = ["enter"],
        callbackHandle: Int64 = 7,
        callbackContext: Int64? = nil
    ) -> IosGeofenceSynchronizationRegistration {
        IosGeofenceSynchronizationRegistration(
            id: id,
            latitude: 11.56,
            longitude: 104.93,
            radiusMeters: 100,
            triggers: triggers,
            callbackHandle: callbackHandle,
            callbackContext: callbackContext
        )
    }
}
