enum IosNativeGeofenceStatusHealth {
    static func compute(
        persistedCount: Int,
        locationPermission: Bool,
        backgroundPermission: Bool,
        locationServicesEnabled: Bool,
        monitoringAvailable: Bool,
        dispatcherRegistered: Bool,
        refreshState: NativeGeofenceCallbackRefreshState,
        monitoredCount: Int
    ) -> NativeGeofenceRegistrationHealth {
        guard persistedCount > 0 else { return .noRegistrations }
        guard locationPermission,
              backgroundPermission,
              locationServicesEnabled,
              monitoringAvailable,
              dispatcherRegistered
        else {
            return .unavailable
        }
        if refreshState == .refreshRequired || monitoredCount != persistedCount {
            return .degraded
        }
        if refreshState == .unknown {
            return .unknown
        }
        return .healthy
    }
}
