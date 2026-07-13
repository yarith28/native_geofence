import XCTest
@testable import RegionRegistrationCore

final class IosRegionRadiusTests: XCTestCase {
    func testRejectsNonFiniteAndNonPositiveRadii() {
        for radius in [
            Double.nan,
            Double.infinity,
            -Double.infinity,
            0,
            -1,
        ] {
            XCTAssertNil(
                IosRegionRadius.normalized(
                    requestedRadius: radius,
                    maximumRadius: 1_000
                )
            )
        }
    }

    func testPreservesRadiusWithinDeviceMaximum() {
        XCTAssertEqual(
            IosRegionRadius.normalized(
                requestedRadius: 100,
                maximumRadius: 1_000
            ),
            100
        )
    }

    func testClampsRadiusToDeviceMaximum() {
        XCTAssertEqual(
            IosRegionRadius.normalized(
                requestedRadius: 2_000,
                maximumRadius: 1_000
            ),
            1_000
        )
    }

    func testPreservesRadiusWhenDeviceHasNoFiniteMaximum() {
        for maximumRadius in [0, -1, Double.nan, Double.infinity] {
            XCTAssertEqual(
                IosRegionRadius.normalized(
                    requestedRadius: 100,
                    maximumRadius: maximumRadius
                ),
                100
            )
        }
    }
}
