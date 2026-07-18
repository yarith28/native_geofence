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
                authorizationStatus: .authorizedAlways,
                accuracyAuthorization: .fullAccuracy
            )
        )
    }

    func testWhenInUseAuthorizationRequiresBackgroundPermission() {
        XCTAssertEqual(
            IosGeofencePreflight.failure(
                locationServicesEnabled: true,
                authorizationStatus: authorizedWhenInUse,
                accuracyAuthorization: .fullAccuracy
            ),
            .backgroundLocationPermissionMissing
        )
    }

    func testPermissionEvidenceSeparatesLocationFromBackgroundAuthorization() {
        XCTAssertEqual(
            IosLocationPermissionEvidence.from(
                .authorizedAlways,
                accuracyAuthorization: .fullAccuracy
            ),
            IosLocationPermissionEvidence(
                locationPermissionGranted: true,
                backgroundLocationPermissionGranted: true,
                preciseLocationPermissionGranted: true
            )
        )
        XCTAssertEqual(
            IosLocationPermissionEvidence.from(
                authorizedWhenInUse,
                accuracyAuthorization: .fullAccuracy
            ),
            IosLocationPermissionEvidence(
                locationPermissionGranted: true,
                backgroundLocationPermissionGranted: false,
                preciseLocationPermissionGranted: true
            )
        )
        XCTAssertEqual(
            IosLocationPermissionEvidence.from(
                .denied,
                accuracyAuthorization: .reducedAccuracy
            ),
            IosLocationPermissionEvidence(
                locationPermissionGranted: false,
                backgroundLocationPermissionGranted: false,
                preciseLocationPermissionGranted: false
            )
        )
    }

    func testReducedAccuracyIsRejectedForRegionMonitoring() {
        XCTAssertEqual(
            IosGeofencePreflight.failure(
                locationServicesEnabled: true,
                authorizationStatus: .authorizedAlways,
                accuracyAuthorization: .reducedAccuracy
            ),
            .preciseLocationPermissionMissing
        )
    }

    func testRemovalOnlySynchronizationAllowsRevokedPermissionAndDisabledServices() {
        XCTAssertNil(
            IosGeofenceSynchronizationPreflight.failure(
                requiresRegistrationPreflight: false,
                locationServicesEnabled: false,
                authorizationStatus: .denied,
                accuracyAuthorization: .reducedAccuracy
            )
        )
    }

    func testSynchronizationRegistrationStillRequiresFullAccuracy() {
        XCTAssertEqual(
            IosGeofenceSynchronizationPreflight.failure(
                requiresRegistrationPreflight: true,
                locationServicesEnabled: true,
                authorizationStatus: .authorizedAlways,
                accuracyAuthorization: .reducedAccuracy
            ),
            .preciseLocationPermissionMissing
        )
    }

    func testReducedAccuracyMakesPersistedRegistrationUnavailable() {
        XCTAssertEqual(
            statusHealth(preciseLocationPermission: false),
            .unavailable
        )
    }

    func testFullAccuracyRetainsHealthyRegistrationStatus() {
        XCTAssertEqual(
            statusHealth(preciseLocationPermission: true),
            .healthy
        )
    }

    func testOtherAuthorizationStatesRequireLocationPermission() {
        for status: CLAuthorizationStatus in [.denied, .notDetermined, .restricted] {
            XCTAssertEqual(
                IosGeofencePreflight.failure(
                    locationServicesEnabled: true,
                    authorizationStatus: status,
                    accuracyAuthorization: .fullAccuracy
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
                    authorizationStatus: status,
                    accuracyAuthorization: .fullAccuracy
                ),
                .locationServicesDisabled
            )
        }
    }

    private func statusHealth(
        preciseLocationPermission: Bool
    ) -> IosGeofenceStatusHealth {
        IosGeofenceStatusHealthPolicy.compute(
            persistedCount: 1,
            locationPermission: true,
            backgroundPermission: true,
            preciseLocationPermission: preciseLocationPermission,
            backgroundRefreshAvailable: true,
            locationServicesEnabled: true,
            monitoringAvailable: true,
            dispatcherRegistered: true,
            refreshState: .current,
            monitoredCount: 1
        )
    }
}
