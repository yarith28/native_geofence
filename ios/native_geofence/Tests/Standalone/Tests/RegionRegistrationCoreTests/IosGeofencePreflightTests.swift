import CoreLocation
import XCTest
@testable import RegionRegistrationCore

final class IosGeofencePreflightTests: XCTestCase {
    private var authorizedWhenInUse: CLAuthorizationStatus {
#if os(macOS)
        // The case exists at runtime but is marked unavailable to macOS source.
        return CLAuthorizationStatus(rawValue: 4)!
#else
        return .authorizedWhenInUse
#endif
    }

    func testAlwaysAuthorizationPassesWhenLocationServicesAreEnabled() {
        XCTAssertNil(
            IosGeofencePreflight.failure(
                locationServicesEnabled: true,
                authorizationStatus: .authorizedAlways
            )
        )
    }

    func testWhenInUseAuthorizationRequiresBackgroundPermission() {
        XCTAssertEqual(
            IosGeofencePreflight.failure(
                locationServicesEnabled: true,
                authorizationStatus: authorizedWhenInUse
            ),
            .backgroundLocationPermissionMissing
        )
    }

    func testOtherAuthorizationStatesRequireLocationPermission() {
        for status: CLAuthorizationStatus in [.denied, .notDetermined, .restricted] {
            XCTAssertEqual(
                IosGeofencePreflight.failure(
                    locationServicesEnabled: true,
                    authorizationStatus: status
                ),
                .locationPermissionMissing
            )
        }
    }

    func testDisabledLocationServicesTakePrecedenceOverAuthorization() {
        for status: CLAuthorizationStatus in [.authorizedAlways, authorizedWhenInUse, .denied] {
            XCTAssertEqual(
                IosGeofencePreflight.failure(
                    locationServicesEnabled: false,
                    authorizationStatus: status
                ),
                .locationServicesDisabled
            )
        }
    }
}
