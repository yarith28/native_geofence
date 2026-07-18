enum IosNativeGeofenceStatusHealth {
    static func compute(
        persistedCount: Int,
        locationPermission: Bool,
        backgroundPermission: Bool,
        preciseLocationPermission: Bool,
        backgroundRefreshAvailable: Bool,
        locationServicesEnabled: Bool,
        monitoringAvailable: Bool,
        dispatcherRegistered: Bool,
        refreshState: NativeGeofenceCallbackRefreshState,
        monitoredCount: Int
    ) -> NativeGeofenceRegistrationHealth {
        let policyRefreshState: IosGeofenceCallbackRefreshHealth = switch refreshState {
        case .current: .current
        case .notApplicable: .notApplicable
        case .refreshRequired: .refreshRequired
        case .unknown: .unknown
        }
        return switch IosGeofenceStatusHealthPolicy.compute(
            persistedCount: persistedCount,
            locationPermission: locationPermission,
            backgroundPermission: backgroundPermission,
            preciseLocationPermission: preciseLocationPermission,
            backgroundRefreshAvailable: backgroundRefreshAvailable,
            locationServicesEnabled: locationServicesEnabled,
            monitoringAvailable: monitoringAvailable,
            dispatcherRegistered: dispatcherRegistered,
            refreshState: policyRefreshState,
            monitoredCount: monitoredCount
        ) {
        case .noRegistrations: .noRegistrations
        case .unavailable: .unavailable
        case .degraded: .degraded
        case .unknown: .unknown
        case .healthy: .healthy
        }
    }
}
