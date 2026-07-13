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
