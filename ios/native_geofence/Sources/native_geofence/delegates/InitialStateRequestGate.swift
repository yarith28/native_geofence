import CoreLocation
import Foundation

enum InitialStateBoundaryEventRejectionReason: String, Equatable {
    case unsupportedRegionType = "unsupported_region_type"
    case privateInitialStateProbe = "private_initial_state_probe"
    case unknownIdentifier = "unknown_identifier"
    case pendingMutationSemanticsMismatch =
        "pending_mutation_semantics_mismatch"
}

enum InitialStateBoundaryEventAcceptanceReason: String, Equatable {
    case monitoringSemanticsMatch = "committed_identifier_semantics_match"
    case monitoringSemanticsMismatch = "committed_identifier_semantics_mismatch"
}

enum InitialStateBoundaryEventDecision {
    case accepted(
        CLCircularRegion,
        reason: InitialStateBoundaryEventAcceptanceReason
    )
    case rejected(InitialStateBoundaryEventRejectionReason)
}

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

    /// Routes a real boundary callback using Core Location's documented
    /// identifier contract and invalidates its pending initial-state probe.
    ///
    /// The region supplied to `didEnterRegion` or `didExitRegion` is not
    /// guaranteed to preserve the registered region's geometry. Registration
    /// transactions decide which same-ID configuration is committed; callback
    /// admission must therefore use the current committed identifier rather
    /// than comparing callback coordinates, radius, or notification flags.
    /// During a same-ID registration transaction, however, the caller may
    /// require an exact semantics match so a newly replaced platform region
    /// cannot be delivered through metadata that has not committed yet.
    func decideBoundaryEvent(
        for responseRegion: CLRegion,
        requireMonitoringSemanticsMatch: Bool = false
    ) -> InitialStateBoundaryEventDecision {
        guard responseRegion is CLCircularRegion else {
            return .rejected(.unsupportedRegionType)
        }
        guard publicRegionsByProbeIdentifier[responseRegion.identifier] == nil else {
            return .rejected(.privateInitialStateProbe)
        }
        guard let committedRegion = committedRegionsByIdentifier[responseRegion.identifier]
        else {
            return .rejected(.unknownIdentifier)
        }

        let reason: InitialStateBoundaryEventAcceptanceReason =
            RegionMonitoringSemantics.matches(responseRegion, committedRegion)
                ? .monitoringSemanticsMatch
                : .monitoringSemanticsMismatch
        if requireMonitoringSemanticsMatch,
           reason == .monitoringSemanticsMismatch
        {
            return .rejected(.pendingMutationSemanticsMismatch)
        }
        cancelProbe(for: committedRegion.identifier)
        return .accepted(committedRegion, reason: reason)
    }

    func consumeBoundaryEvent(for responseRegion: CLRegion) -> CLCircularRegion? {
        guard case .accepted(let region, _) = decideBoundaryEvent(
            for: responseRegion
        ) else {
            return nil
        }
        return region
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
