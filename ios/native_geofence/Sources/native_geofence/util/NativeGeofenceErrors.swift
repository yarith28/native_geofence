func nativeGeofenceError(
    _ code: NativeGeofenceErrorCode,
    message: String
) -> PigeonError {
    PigeonError(code: "\(code.rawValue)", message: message, details: nil)
}

func iosGeofenceCallbackDeliveryOutcome(
    _ result: Result<Void, PigeonError>
) -> IosGeofenceCallbackDeliveryOutcome {
    switch result {
    case .success:
        return .succeeded
    case .failure(let error):
        let terminalFailure =
            IosGeofenceCallbackDeliveryOutcome.TerminalFailure.classify(
                errorCode: error.code,
                details: error.details as? String,
                callbackNotFoundCode:
                    String(NativeGeofenceErrorCode.callbackNotFound.rawValue),
                callbackInvalidCode:
                    String(NativeGeofenceErrorCode.callbackInvalid.rawValue)
            )
        if let terminalFailure {
            return .terminalFailure(terminalFailure)
        }
        return .retryableFailure
    }
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
    case .preciseLocationPermissionMissing:
        return nativeGeofenceError(
            .missingPreciseLocationPermission,
            message: "Precise Location access is required to monitor geofences on iOS."
        )
    }
}
