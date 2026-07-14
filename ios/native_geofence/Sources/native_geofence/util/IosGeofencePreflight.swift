import CoreLocation

enum IosGeofencePreflightFailure: Equatable {
    case locationServicesDisabled
    case locationPermissionMissing
    case backgroundLocationPermissionMissing
}

struct IosLocationPermissionEvidence: Equatable {
    let locationPermissionGranted: Bool
    let backgroundLocationPermissionGranted: Bool

    static func from(_ authorizationStatus: CLAuthorizationStatus) -> Self {
        switch authorizationStatus {
        case .authorizedAlways:
            return Self(
                locationPermissionGranted: true,
                backgroundLocationPermissionGranted: true
            )
        case .authorizedWhenInUse:
            return Self(
                locationPermissionGranted: true,
                backgroundLocationPermissionGranted: false
            )
        case .denied, .notDetermined, .restricted:
            return Self(
                locationPermissionGranted: false,
                backgroundLocationPermissionGranted: false
            )
        @unknown default:
            return Self(
                locationPermissionGranted: false,
                backgroundLocationPermissionGranted: false
            )
        }
    }
}

enum IosGeofencePreflight {
    static func failure(
        locationServicesEnabled: Bool,
        authorizationStatus: CLAuthorizationStatus
    ) -> IosGeofencePreflightFailure? {
        guard locationServicesEnabled else {
            return .locationServicesDisabled
        }

        let permission = IosLocationPermissionEvidence.from(authorizationStatus)
        guard permission.locationPermissionGranted else {
            return .locationPermissionMissing
        }
        guard permission.backgroundLocationPermissionGranted else {
            return .backgroundLocationPermissionMissing
        }
        return nil
    }
}
