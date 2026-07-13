import CoreLocation

enum PluginOwnedRegions {
    static func select(
        from monitoredRegions: Set<CLRegion>,
        callbackIds: Set<String>
    ) -> [CLCircularRegion] {
        monitoredRegions.compactMap { region in
            guard callbackIds.contains(region.identifier) else { return nil }
            return region as? CLCircularRegion
        }
    }
}
