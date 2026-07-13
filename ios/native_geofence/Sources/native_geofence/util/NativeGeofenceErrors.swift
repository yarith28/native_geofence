func nativeGeofenceError(
    _ code: NativeGeofenceErrorCode,
    message: String
) -> PigeonError {
    PigeonError(code: "\(code.rawValue)", message: message, details: nil)
}

func nativeGeofenceError(_ failure: RegionRegistrationFailure) -> PigeonError {
    let code: NativeGeofenceErrorCode = switch failure {
    case .missingLocationPermission:
        .missingLocationPermission
    case .monitoringFailed:
        .iosRegionMonitoringFailed
    }
    return nativeGeofenceError(code, message: failure.message)
}

func nativeGeofenceError(_ failure: IosGeofencePreflightFailure) -> PigeonError {
    switch failure {
    case .locationServicesDisabled:
        return nativeGeofenceError(
            .missingLocationPermission,
            message: "Location Services are disabled."
        )
    case .locationPermissionMissing:
        return nativeGeofenceError(
            .missingLocationPermission,
            message: "Location permission is not granted."
        )
    case .backgroundLocationPermissionMissing:
        return nativeGeofenceError(
            .missingBackgroundLocationPermission,
            message: "Always location authorization is required to monitor geofences on iOS."
        )
    }
}
