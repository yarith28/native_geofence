import CoreLocation
import Foundation

protocol RegionMonitoring: AnyObject {
    var monitoredRegions: Set<CLRegion> { get }

    func startMonitoring(for region: CLRegion)
    func stopMonitoring(for region: CLRegion)
}

extension CLLocationManager: RegionMonitoring {}

enum RegionRegistrationFailure: Error, Equatable {
    case missingLocationPermission(String)
    case monitoringFailed(String)

    var message: String {
        switch self {
        case .missingLocationPermission(let message), .monitoringFailed(let message):
            return message
        }
    }

    func appending(_ message: String) -> RegionRegistrationFailure {
        switch self {
        case .missingLocationPermission(let existingMessage):
            return .missingLocationPermission("\(existingMessage) \(message)")
        case .monitoringFailed(let existingMessage):
            return .monitoringFailed("\(existingMessage) \(message)")
        }
    }
}

private final class PendingRegionRegistration {
    let requestedRegion: CLCircularRegion
    let requestedCallbackHandle: Int64
    let previousRegion: CLRegion?
    let previousCallbackHandle: Int64?
    let initialTrigger: Bool
    let completion: (Result<Void, RegionRegistrationFailure>) -> Void
    var timeoutWorkItem: DispatchWorkItem?

    init(
        requestedRegion: CLCircularRegion,
        requestedCallbackHandle: Int64,
        previousRegion: CLRegion?,
        previousCallbackHandle: Int64?,
        initialTrigger: Bool,
        completion: @escaping (Result<Void, RegionRegistrationFailure>) -> Void
    ) {
        self.requestedRegion = requestedRegion
        self.requestedCallbackHandle = requestedCallbackHandle
        self.previousRegion = previousRegion
        self.previousCallbackHandle = previousCallbackHandle
        self.initialTrigger = initialTrigger
        self.completion = completion
    }
}

private final class PendingRegionRestoration {
    let region: CLRegion
    let originalFailure: RegionRegistrationFailure
    let completion: (Result<Void, RegionRegistrationFailure>) -> Void
    var timeoutWorkItem: DispatchWorkItem?

    init(
        region: CLRegion,
        originalFailure: RegionRegistrationFailure,
        completion: @escaping (Result<Void, RegionRegistrationFailure>) -> Void
    ) {
        self.region = region
        self.originalFailure = originalFailure
        self.completion = completion
    }
}

private final class CancelledRegionRegistration {
    let region: CLRegion
    var timeoutWorkItem: DispatchWorkItem?

    init(region: CLRegion) {
        self.region = region
    }
}

final class RegionRegistrationCoordinator {
    typealias TimeoutScheduler = (TimeInterval, DispatchWorkItem) -> Void

    private static let coordinateTolerance = 0.0000001
    private static let radiusToleranceMeters = 0.01

    private let monitor: any RegionMonitoring
    private let timeoutSeconds: TimeInterval
    private let scheduleTimeout: TimeoutScheduler
    private let getCallbackHandle: (String) -> Int64?
    private let setCallbackHandle: (String, Int64) -> Void
    private let removeCallbackHandle: (String) -> Void
    private var pendingRegistrations: [String: PendingRegionRegistration] = [:]
    private var pendingRestorations: [String: PendingRegionRestoration] = [:]
    private var cancelledRegistrations: [String: CancelledRegionRegistration] = [:]

    init(
        monitor: any RegionMonitoring,
        timeoutSeconds: TimeInterval = 10,
        scheduleTimeout: @escaping TimeoutScheduler = { delay, workItem in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        },
        getCallbackHandle: @escaping (String) -> Int64?,
        setCallbackHandle: @escaping (String, Int64) -> Void,
        removeCallbackHandle: @escaping (String) -> Void
    ) {
        self.monitor = monitor
        self.timeoutSeconds = timeoutSeconds
        self.scheduleTimeout = scheduleTimeout
        self.getCallbackHandle = getCallbackHandle
        self.setCallbackHandle = setCallbackHandle
        self.removeCallbackHandle = removeCallbackHandle
    }

    /// Starts monitoring and returns a region whose state should be requested
    /// immediately when an identical registration is already active.
    func start(
        region: CLCircularRegion,
        callbackHandle: Int64,
        initialTrigger: Bool,
        completion: @escaping (Result<Void, RegionRegistrationFailure>) -> Void
    ) -> CLCircularRegion? {
        let id = region.identifier
        guard pendingRegistrations[id] == nil, pendingRestorations[id] == nil else {
            completion(
                .failure(
                    .monitoringFailed(
                        "A registration for geofence ID=\(id) is already pending."
                    )
                )
            )
            return nil
        }
        guard cancelledRegistrations[id] == nil else {
            completion(
                .failure(
                    .monitoringFailed(
                        "A recent removal for geofence ID=\(id) is still being processed by iOS."
                    )
                )
            )
            return nil
        }

        let previousRegion = monitor.monitoredRegions.first { $0.identifier == id }
        let storedCallbackHandle = getCallbackHandle(id)
        let previousCallbackHandle = previousRegion.flatMap { _ in storedCallbackHandle }
        // A callback handle is the plugin's ownership marker for legacy region
        // identifiers. Never replace or restore an unowned app region.
        if let previousRegion,
           previousCallbackHandle == nil || !(previousRegion is CLCircularRegion)
        {
            completion(
                .failure(
                    .monitoringFailed(
                        "Geofence ID=\(id) conflicts with a region not registered by this plugin."
                    )
                )
            )
            return nil
        }

        if let existingRegion = previousRegion as? CLCircularRegion,
           regionsMatch(existingRegion, region)
        {
            setCallbackHandle(id, callbackHandle)
            completion(.success(()))
            return initialTrigger ? existingRegion : nil
        }

        let pending = PendingRegionRegistration(
            requestedRegion: region,
            requestedCallbackHandle: callbackHandle,
            previousRegion: previousRegion,
            previousCallbackHandle: previousCallbackHandle,
            initialTrigger: initialTrigger,
            completion: completion
        )
        // Keep the previous handle active until Core Location confirms the new
        // registration, so events from the old region cannot reach a new callback.
        pendingRegistrations[id] = pending

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finishRegistrationWithFailure(
                id: id,
                matching: region,
                failure: .monitoringFailed(
                    "Timed out waiting for iOS to confirm region monitoring for geofence ID=\(id)."
                )
            )
        }
        pending.timeoutWorkItem = timeoutWorkItem
        scheduleTimeout(timeoutSeconds, timeoutWorkItem)

        // A custom scheduler may execute synchronously in a test. Do not start
        // monitoring after that scheduler has already timed out this request.
        guard pendingRegistrations[id] === pending else { return nil }
        // A callback handle without a live region is stale. Do not publish it
        // while a genuinely new registration is awaiting confirmation.
        if previousRegion == nil, storedCallbackHandle != nil {
            removeCallbackHandle(id)
        }
        monitor.startMonitoring(for: region)
        return nil
    }

    /// Completes a matching pending registration and returns the region whose
    /// initial state should be requested.
    func didStartMonitoring(for region: CLRegion) -> CLCircularRegion? {
        let id = region.identifier
        if let pending = pendingRegistrations[id],
           regionsMatch(region, pending.requestedRegion)
        {
            pendingRegistrations.removeValue(forKey: id)
            pending.timeoutWorkItem?.cancel()
            setCallbackHandle(id, pending.requestedCallbackHandle)
            pending.completion(.success(()))
            return pending.initialTrigger ? pending.requestedRegion : nil
        }

        if let restoration = pendingRestorations[id],
           regionsMatch(region, restoration.region)
        {
            pendingRestorations.removeValue(forKey: id)
            restoration.timeoutWorkItem?.cancel()
            restoration.completion(.failure(restoration.originalFailure))
            return nil
        }

        if let cancelled = cancelledRegistrations[id],
           regionsMatch(region, cancelled.region)
        {
            cancelledRegistrations.removeValue(forKey: id)
            cancelled.timeoutWorkItem?.cancel()
            monitor.stopMonitoring(for: region)
        }
        return nil
    }

    func didFailMonitoring(for region: CLRegion?, error: any Error) {
        // Core Location occasionally reports a nil region. That error cannot be
        // attributed safely, so let each token-owned operation resolve through
        // its matching callback or timeout instead of cancelling unrelated work.
        guard let region else { return }
        let failure = registrationFailure(from: error, regionId: region.identifier)
        if let pending = pendingRegistrations[region.identifier],
           regionsMatch(region, pending.requestedRegion)
        {
            finishRegistrationWithFailure(
                id: region.identifier,
                matching: region,
                failure: failure
            )
            return
        }
        if let restoration = pendingRestorations[region.identifier],
           regionsMatch(region, restoration.region)
        {
            finishRestorationWithFailure(
                id: region.identifier,
                matching: region,
                failure: restoration.originalFailure.appending(
                    "Restoring the previous registration also failed: \(failure.message)"
                )
            )
            return
        }
        if let cancelled = cancelledRegistrations[region.identifier],
           regionsMatch(region, cancelled.region)
        {
            cancelledRegistrations.removeValue(forKey: region.identifier)
            cancelled.timeoutWorkItem?.cancel()
        }
    }

    @discardableResult
    func cancel(id: String) -> Bool {
        if let pending = pendingRegistrations.removeValue(forKey: id) {
            pending.timeoutWorkItem?.cancel()
            monitor.stopMonitoring(for: pending.requestedRegion)
            removeCallbackHandle(id)
            addCancellationTombstone(for: pending.requestedRegion)
            pending.completion(.failure(cancellationFailure(id: id)))
            return true
        }

        if let restoration = pendingRestorations.removeValue(forKey: id) {
            restoration.timeoutWorkItem?.cancel()
            monitor.stopMonitoring(for: restoration.region)
            removeCallbackHandle(id)
            addCancellationTombstone(for: restoration.region)
            restoration.completion(.failure(cancellationFailure(id: id)))
            return true
        }

        guard let activeRegion = monitor.monitoredRegions.first(where: { $0.identifier == id }) else {
            return false
        }
        monitor.stopMonitoring(for: activeRegion)
        removeCallbackHandle(id)
        addCancellationTombstone(for: activeRegion)
        return true
    }

    func cancelAll() {
        let ids = Set(
            Array(pendingRegistrations.keys)
                + Array(pendingRestorations.keys)
                + monitor.monitoredRegions.map(\.identifier)
        )
        for id in ids {
            cancel(id: id)
        }
    }

    private func finishRegistrationWithFailure(
        id: String,
        matching region: CLRegion?,
        failure: RegionRegistrationFailure
    ) {
        guard let pending = pendingRegistrations[id],
              region.map({ regionsMatch($0, pending.requestedRegion) }) ?? true
        else {
            return
        }

        pendingRegistrations.removeValue(forKey: id)
        pending.timeoutWorkItem?.cancel()
        monitor.stopMonitoring(for: pending.requestedRegion)

        if let previousRegion = pending.previousRegion,
           pending.previousCallbackHandle != nil
        {
            beginRestoration(
                region: previousRegion,
                originalFailure: failure,
                completion: pending.completion
            )
        } else {
            removeCallbackHandle(id)
            pending.completion(.failure(failure))
        }
    }

    private func beginRestoration(
        region: CLRegion,
        originalFailure: RegionRegistrationFailure,
        completion: @escaping (Result<Void, RegionRegistrationFailure>) -> Void
    ) {
        let id = region.identifier
        let restoration = PendingRegionRestoration(
            region: region,
            originalFailure: originalFailure,
            completion: completion
        )
        pendingRestorations[id] = restoration

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finishRestorationWithFailure(
                id: id,
                matching: region,
                failure: originalFailure.appending(
                    "Timed out while restoring the previous registration."
                )
            )
        }
        restoration.timeoutWorkItem = timeoutWorkItem
        scheduleTimeout(timeoutSeconds, timeoutWorkItem)

        guard pendingRestorations[id] === restoration else { return }
        monitor.startMonitoring(for: region)
    }

    private func finishRestorationWithFailure(
        id: String,
        matching region: CLRegion?,
        failure: RegionRegistrationFailure
    ) {
        guard let restoration = pendingRestorations[id],
              region.map({ regionsMatch($0, restoration.region) }) ?? true
        else {
            return
        }

        pendingRestorations.removeValue(forKey: id)
        restoration.timeoutWorkItem?.cancel()
        monitor.stopMonitoring(for: restoration.region)
        removeCallbackHandle(id)
        restoration.completion(.failure(failure))
    }

    private func addCancellationTombstone(for region: CLRegion) {
        let id = region.identifier
        cancelledRegistrations[id]?.timeoutWorkItem?.cancel()
        let cancelled = CancelledRegionRegistration(region: region)
        cancelledRegistrations[id] = cancelled

        let timeoutWorkItem = DispatchWorkItem { [weak self, weak cancelled] in
            guard let self, let cancelled,
                  self.cancelledRegistrations[id] === cancelled
            else {
                return
            }
            self.cancelledRegistrations.removeValue(forKey: id)
        }
        cancelled.timeoutWorkItem = timeoutWorkItem
        scheduleTimeout(timeoutSeconds, timeoutWorkItem)
    }

    private func cancellationFailure(id: String) -> RegionRegistrationFailure {
        .monitoringFailed(
            "Registration for geofence ID=\(id) was cancelled because the geofence was removed."
        )
    }

    private func registrationFailure(
        from error: any Error,
        regionId: String?
    ) -> RegionRegistrationFailure {
        let idDescription = regionId.map { " for geofence ID=\($0)" } ?? ""
        let message = "iOS region monitoring failed\(idDescription): \(error.localizedDescription)"
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain,
           let code = CLError.Code(rawValue: nsError.code),
           code == .denied || code == .regionMonitoringDenied
        {
            return .missingLocationPermission(message)
        }
        return .monitoringFailed(message)
    }

    private func regionsMatch(_ lhs: CLRegion, _ rhs: CLRegion) -> Bool {
        guard lhs.identifier == rhs.identifier else { return false }
        guard let lhs = lhs as? CLCircularRegion,
              let rhs = rhs as? CLCircularRegion
        else {
            return type(of: lhs) == type(of: rhs)
        }
        return abs(lhs.center.latitude - rhs.center.latitude) <= Self.coordinateTolerance
            && abs(lhs.center.longitude - rhs.center.longitude) <= Self.coordinateTolerance
            && abs(lhs.radius - rhs.radius) <= Self.radiusToleranceMeters
            && lhs.notifyOnEntry == rhs.notifyOnEntry
            && lhs.notifyOnExit == rhs.notifyOnExit
    }
}
