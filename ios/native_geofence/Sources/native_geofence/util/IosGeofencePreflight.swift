import CoreLocation

enum IosGeofencePreflightFailure: Equatable {
    case locationServicesDisabled
    case locationPermissionMissing
    case backgroundLocationPermissionMissing
}

enum IosGeofencePreflight {
    static func failure(
        locationServicesEnabled: Bool,
        authorizationStatus: CLAuthorizationStatus
    ) -> IosGeofencePreflightFailure? {
        guard locationServicesEnabled else {
            return .locationServicesDisabled
        }

        switch authorizationStatus {
        case .authorizedAlways:
            return nil
        case .authorizedWhenInUse:
            return .backgroundLocationPermissionMissing
        case .denied, .notDetermined, .restricted:
            return .locationPermissionMissing
        @unknown default:
            return .locationPermissionMissing
        }
    }
}
