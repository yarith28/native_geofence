enum IosRegionRadius {
    static func normalized(
        requestedRadius: Double,
        maximumRadius: Double
    ) -> Double? {
        guard requestedRadius.isFinite, requestedRadius > 0 else {
            return nil
        }
        guard maximumRadius.isFinite, maximumRadius > 0 else {
            return requestedRadius
        }
        return min(requestedRadius, maximumRadius)
    }
}
