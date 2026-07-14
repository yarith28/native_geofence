import XCTest
@testable import RegionRegistrationCore

final class IosCallbackRefreshPolicyTests: XCTestCase {
    func testNoRegistrationsAreNotApplicableRegardlessOfFingerprintEvidence() {
        for stored in [nil, "old", "current"] as [String?] {
            XCTAssertEqual(
                IosCallbackRefreshPolicy.evaluate(
                    registrationCount: 0,
                    storedPackageFingerprint: stored,
                    currentPackageFingerprint: "current"
                ),
                .notApplicable
            )
        }
    }

    func testKnownPackageMismatchRequiresRefresh() {
        XCTAssertEqual(
            IosCallbackRefreshPolicy.evaluate(
                registrationCount: 1,
                storedPackageFingerprint: "old",
                currentPackageFingerprint: "current"
            ),
            .refreshRequired
        )
    }

    func testMissingPackageEvidenceIsUnknown() {
        XCTAssertEqual(
            IosCallbackRefreshPolicy.evaluate(
                registrationCount: 1,
                storedPackageFingerprint: nil,
                currentPackageFingerprint: "current"
            ),
            .unknown
        )
    }

    func testEqualPackageFingerprintRemainsUnknownWithoutPerHandleProof() {
        XCTAssertEqual(
            IosCallbackRefreshPolicy.evaluate(
                registrationCount: 1,
                storedPackageFingerprint: "current",
                currentPackageFingerprint: "current"
            ),
            .unknown
        )
    }

    func testCurrentPerRegistrationEvidenceSupersedesStaleGlobalFingerprint() {
        XCTAssertEqual(
            IosCallbackRefreshPolicy.evaluate(
                registrationCount: 2,
                storedPackageFingerprint: "global-old",
                registrationPackageFingerprints: ["current", "current"],
                currentPackageFingerprint: "current"
            ),
            .unknown
        )
    }

    func testAnyStalePerRegistrationEvidenceRequiresRefresh() {
        XCTAssertEqual(
            IosCallbackRefreshPolicy.evaluate(
                registrationCount: 2,
                storedPackageFingerprint: "current",
                registrationPackageFingerprints: ["current", "old"],
                currentPackageFingerprint: "current"
            ),
            .refreshRequired
        )
    }

    func testMissingPerRegistrationEvidenceKeepsLegacyMismatchRelevant() {
        XCTAssertEqual(
            IosCallbackRefreshPolicy.evaluate(
                registrationCount: 2,
                storedPackageFingerprint: "global-old",
                registrationPackageFingerprints: ["current", nil],
                currentPackageFingerprint: "current"
            ),
            .refreshRequired
        )
    }
}
