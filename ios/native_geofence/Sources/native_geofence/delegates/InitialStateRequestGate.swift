import CoreLocation
import Foundation

/// Correlates explicit initial-state checks using private, one-shot probes.
final class InitialStateRequestGate {
    private static let probeIdentifierPrefix = "native_geofence.initial-state."

    private var committedRegionsByIdentifier: [String: CLCircularRegion] = [:]
    private var publicRegionsByProbeIdentifier: [String: CLCircularRegion] = [:]
    private var probeIdentifierByPublicIdentifier: [String: String] = [:]

    /// Seeds registrations restored by Core Location when the plugin starts.
    func restoreCommittedRegions(_ regions: [CLCircularRegion]) {
        for region in regions {
            if let existingRegion = committedRegionsByIdentifier[region.identifier],
               !RegionMonitoringSemantics.matches(existingRegion, region)
            {
                cancelProbe(for: region.identifier)
            }
            committedRegionsByIdentifier[region.identifier] = region
        }
    }

    /// Replaces only authority owned by one failed synchronization transaction.
    /// Unrelated committed regions and their outstanding one-shot probes remain
    /// valid. Responses for touched pre-transaction probes are stale after a
    /// stop/restart and are deliberately invalidated.
    func replaceCommittedRegions(
        for identifiers: Set<String>,
        with regions: [CLCircularRegion]
    ) {
        for identifier in identifiers {
            remove(identifier)
        }
        restoreCommittedRegions(
            regions.filter { identifiers.contains($0.identifier) }
        )
    }

    /// Applies a successfully committed registration and returns its optional
    /// one-shot state probe.
    func commit(
        region publicRegion: CLCircularRegion,
        initialTrigger: Bool
    ) -> CLCircularRegion? {
        cancelProbe(for: publicRegion.identifier)
        committedRegionsByIdentifier[publicRegion.identifier] = publicRegion
        guard initialTrigger else { return nil }

        var probeIdentifier: String
        repeat {
            probeIdentifier = "\(Self.probeIdentifierPrefix)\(UUID().uuidString)"
        } while probeIdentifier == publicRegion.identifier
            || publicRegionsByProbeIdentifier[probeIdentifier] != nil

        let probe = CLCircularRegion(
            center: publicRegion.center,
            radius: publicRegion.radius,
            identifier: probeIdentifier
        )
        probe.notifyOnEntry = publicRegion.notifyOnEntry
        probe.notifyOnExit = publicRegion.notifyOnExit

        publicRegionsByProbeIdentifier[probeIdentifier] = publicRegion
        probeIdentifierByPublicIdentifier[publicRegion.identifier] = probeIdentifier
        return probe
    }

    /// Consumes only the response to a currently authorized private probe.
    func consumeInitialStateResponse(for responseRegion: CLRegion) -> CLCircularRegion? {
        guard let publicRegion = publicRegionsByProbeIdentifier.removeValue(
            forKey: responseRegion.identifier
        ) else {
            return nil
        }

        guard let committedRegion = committedRegionsByIdentifier[publicRegion.identifier],
              RegionMonitoringSemantics.matches(committedRegion, publicRegion)
        else {
            return nil
        }
        if probeIdentifierByPublicIdentifier[publicRegion.identifier]
            == responseRegion.identifier
        {
            probeIdentifierByPublicIdentifier.removeValue(forKey: publicRegion.identifier)
        }
        return committedRegion
    }

    /// Routes a real boundary callback and invalidates its pending state probe.
    /// A callback from a replaced same-ID configuration is ignored instead of
    /// consuming the current registration's probe.
    func consumeBoundaryEvent(for responseRegion: CLRegion) -> CLCircularRegion? {
        guard let responseRegion = responseRegion as? CLCircularRegion else {
            return nil
        }
        guard publicRegionsByProbeIdentifier[responseRegion.identifier] == nil else {
            return nil
        }
        guard let committedRegion = committedRegionsByIdentifier[responseRegion.identifier],
              RegionMonitoringSemantics.matches(responseRegion, committedRegion)
        else {
            return nil
        }

        cancelProbe(for: committedRegion.identifier)
        return committedRegion
    }

    func remove(_ publicRegionIdentifier: String) {
        committedRegionsByIdentifier.removeValue(forKey: publicRegionIdentifier)
        cancelProbe(for: publicRegionIdentifier)
    }

    /// Removes a committed registration only when the failure describes its
    /// current monitoring semantics, not a replaced same-ID configuration.
    @discardableResult
    func remove(matching region: CLRegion) -> Bool {
        guard let committedRegion = committedRegionsByIdentifier[region.identifier],
              RegionMonitoringSemantics.matches(region, committedRegion)
        else {
            return false
        }
        remove(committedRegion.identifier)
        return true
    }

    func removeAll() {
        committedRegionsByIdentifier.removeAll()
        publicRegionsByProbeIdentifier.removeAll()
        probeIdentifierByPublicIdentifier.removeAll()
    }

    private func cancelProbe(for publicRegionIdentifier: String) {
        guard let probeIdentifier = probeIdentifierByPublicIdentifier.removeValue(
            forKey: publicRegionIdentifier
        ) else {
            return
        }
        publicRegionsByProbeIdentifier.removeValue(forKey: probeIdentifier)
    }
}
