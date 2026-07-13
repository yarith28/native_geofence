import CoreLocation

enum RegionMonitoringSemantics {
    private static let coordinateTolerance = 0.0000001
    private static let radiusToleranceMeters = 0.01

    static func matches(_ lhs: CLRegion, _ rhs: CLRegion) -> Bool {
        guard lhs.identifier == rhs.identifier else { return false }
        guard let lhs = lhs as? CLCircularRegion,
              let rhs = rhs as? CLCircularRegion
        else {
            return type(of: lhs) == type(of: rhs)
        }
        return abs(lhs.center.latitude - rhs.center.latitude) <= coordinateTolerance
            && abs(lhs.center.longitude - rhs.center.longitude) <= coordinateTolerance
            && abs(lhs.radius - rhs.radius) <= radiusToleranceMeters
            && lhs.notifyOnEntry == rhs.notifyOnEntry
            && lhs.notifyOnExit == rhs.notifyOnExit
    }
}
