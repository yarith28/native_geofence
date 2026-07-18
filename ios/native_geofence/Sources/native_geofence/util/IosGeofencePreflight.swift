import CoreLocation

enum IosGeofencePreflightFailure: Equatable {
    case locationServicesDisabled
    case locationPermissionMissing
    case backgroundLocationPermissionMissing
    case preciseLocationPermissionMissing
}

struct IosLocationPermissionEvidence: Equatable {
    let locationPermissionGranted: Bool
    let backgroundLocationPermissionGranted: Bool
    let preciseLocationPermissionGranted: Bool

    static func from(
        _ authorizationStatus: CLAuthorizationStatus,
        accuracyAuthorization: CLAccuracyAuthorization
    ) -> Self {
        let preciseLocationPermissionGranted = accuracyAuthorization == .fullAccuracy
        switch authorizationStatus {
        case .authorizedAlways:
            return Self(
                locationPermissionGranted: true,
                backgroundLocationPermissionGranted: true,
                preciseLocationPermissionGranted: preciseLocationPermissionGranted
            )
        case .authorizedWhenInUse:
            return Self(
                locationPermissionGranted: true,
                backgroundLocationPermissionGranted: false,
                preciseLocationPermissionGranted: preciseLocationPermissionGranted
            )
        case .denied, .notDetermined, .restricted:
            return Self(
                locationPermissionGranted: false,
                backgroundLocationPermissionGranted: false,
                preciseLocationPermissionGranted: preciseLocationPermissionGranted
            )
        @unknown default:
            return Self(
                locationPermissionGranted: false,
                backgroundLocationPermissionGranted: false,
                preciseLocationPermissionGranted: preciseLocationPermissionGranted
            )
        }
    }
}

enum IosGeofencePreflight {
    static func failure(
        locationServicesEnabled: Bool,
        authorizationStatus: CLAuthorizationStatus,
        accuracyAuthorization: CLAccuracyAuthorization
    ) -> IosGeofencePreflightFailure? {
        guard locationServicesEnabled else {
            return .locationServicesDisabled
        }

        let permission = IosLocationPermissionEvidence.from(
            authorizationStatus,
            accuracyAuthorization: accuracyAuthorization
        )
        guard permission.locationPermissionGranted else {
            return .locationPermissionMissing
        }
        guard permission.backgroundLocationPermissionGranted else {
            return .backgroundLocationPermissionMissing
        }
        guard permission.preciseLocationPermissionGranted else {
            return .preciseLocationPermissionMissing
        }
        return nil
    }
}

enum IosGeofenceSynchronizationPreflight {
    static func failure(
        requiresRegistrationPreflight: Bool,
        locationServicesEnabled: Bool,
        authorizationStatus: CLAuthorizationStatus,
        accuracyAuthorization: CLAccuracyAuthorization
    ) -> IosGeofencePreflightFailure? {
        guard requiresRegistrationPreflight else { return nil }
        return IosGeofencePreflight.failure(
            locationServicesEnabled: locationServicesEnabled,
            authorizationStatus: authorizationStatus,
            accuracyAuthorization: accuracyAuthorization
        )
    }
}

enum IosGeofenceStatusHealth: Equatable {
    case noRegistrations
    case unavailable
    case degraded
    case unknown
    case healthy
}

enum IosGeofenceCallbackRefreshHealth: Equatable {
    case current
    case notApplicable
    case refreshRequired
    case unknown
}

enum IosGeofenceStatusHealthPolicy {
    static func compute(
        persistedCount: Int,
        locationPermission: Bool,
        backgroundPermission: Bool,
        preciseLocationPermission: Bool,
        backgroundRefreshAvailable: Bool,
        locationServicesEnabled: Bool,
        monitoringAvailable: Bool,
        dispatcherRegistered: Bool,
        refreshState: IosGeofenceCallbackRefreshHealth,
        monitoredCount: Int
    ) -> IosGeofenceStatusHealth {
        guard persistedCount > 0 else { return .noRegistrations }
        guard locationPermission,
              backgroundPermission,
              preciseLocationPermission,
              locationServicesEnabled,
              monitoringAvailable,
              dispatcherRegistered
        else {
            return .unavailable
        }
        if refreshState == .refreshRequired || monitoredCount != persistedCount {
            return .degraded
        }
        if !backgroundRefreshAvailable {
            return .degraded
        }
        if refreshState == .unknown {
            return .unknown
        }
        return .healthy
    }
}
