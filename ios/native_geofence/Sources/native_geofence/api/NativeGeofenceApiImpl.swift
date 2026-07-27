import CoreLocation
import Foundation
import Flutter
import OSLog
import UIKit

private struct IosSynchronizedRegionSnapshot {
    let region: CLCircularRegion
    let callbackHandle: Int64
    let callbackContext: Int64?
}

private struct IosSynchronizationTransactionSnapshot {
    let regions: [IosSynchronizedRegionSnapshot]
    let persistence: IosSynchronizationPersistenceSnapshot
}

private struct IosPreparedSynchronizationRegistration {
    let wire: GeofenceWire
    let region: CLCircularRegion
    let plannerRegistration: IosGeofenceSynchronizationRegistration
}

private struct IosSynchronizationEvaluation {
    let desired: [IosPreparedSynchronizationRegistration]
    let removeUnlisted: Bool
    let callbackIds: Set<String>
    let allMonitoredRegions: Set<CLRegion>
    let ownedRegions: [CLCircularRegion]
    let packageFingerprint: String
    let requiresRegistrationPreflight: Bool
    let decision: IosGeofenceSynchronizationDecision
}

public class NativeGeofenceApiImpl: NSObject, NativeGeofenceApi {
    private let log = Logger(subsystem: Constants.PACKAGE_NAME, category: "NativeGeofenceApiImpl")
    private let fileLog = IosNativeGeofenceFileLogger(
        category: "NativeGeofenceApiImpl"
    )
    private let locationServicesQueue = DispatchQueue(
        label: "\(Constants.PACKAGE_NAME).location-services",
        qos: .utility
    )
    private let createPreflightRegistry = GeofenceCreatePreflightRegistry { failure in
        nativeGeofenceError(
            .iosRegionMonitoringFailed,
            message: failure.message
        )
    }
    private let operationQueue = IosGeofenceOperationQueue()
    
    private let locationManagerDelegate: LocationManagerDelegate
    
    init(locationManagerDelegate: LocationManagerDelegate) {
        self.locationManagerDelegate = locationManagerDelegate
    }
    
    func initialize(callbackDispatcherHandle: Int64) throws {
        NativeGeofencePersistence.setCallbackDispatcherHandle(callbackDispatcherHandle)
    }
    
    func createGeofence(geofence: GeofenceWire, completion: @escaping (Result<Void, any Error>) -> Void) {
        operationQueue.enqueueConcurrent(id: geofence.id) { [weak self] finish in
            guard let self else {
                completion(
                    .failure(
                        nativeGeofenceError(
                            .pluginInternal,
                            message: "The iOS geofence runtime was released."
                        )
                    )
                )
                finish()
                return
            }
            performCreateGeofence(geofence: geofence) { result in
                completion(result)
                finish()
            }
        }
    }

    func restoreGeofence(
        geofence: GeofenceWire,
        expirationDeadlineMillis: Int64?,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        createGeofence(geofence: geofence, completion: completion)
    }

    private func performCreateGeofence(
        geofence: GeofenceWire,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        let diagnosticCompletion: (Result<Void, any Error>) -> Void = {
            [fileLog = self.fileLog] result in
            let succeeded: Bool
            switch result {
            case .success:
                succeeded = true
                fileLog.diagnostic(
                    "Geofence registration completed for ID=\(geofence.id)."
                )
            case .failure(let error):
                succeeded = false
                fileLog.error(
                    "Geofence registration failed for ID=\(geofence.id): \(error)"
                )
            }
            NativeGeofenceDiagnostics.record(
                .registration,
                succeeded: succeeded,
                outcome: succeeded ? "registered" : "registration_failed",
                geofenceCount: 1
            )
            completion(result)
        }
        guard let preflightToken = createPreflightRegistry.begin(
            id: geofence.id,
            completion: diagnosticCompletion
        ) else {
            return
        }

        locationServicesQueue.async { [self] in
            let locationServicesEnabled = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async { [self] in
                guard let completion = createPreflightRegistry.takeIfPending(
                    preflightToken
                ) else {
                    return
                }
                createGeofence(
                    geofence: geofence,
                    locationServicesEnabled: locationServicesEnabled,
                    completion: completion
                )
            }
        }
    }

    private func createGeofence(
        geofence: GeofenceWire,
        locationServicesEnabled: Bool,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            completion(
                .failure(
                    nativeGeofenceError(
                        .iosRegionMonitoringFailed,
                        message: "iOS region monitoring is not available on this device."
                    )
                )
            )
            return
        }

        if let failure = IosGeofencePreflight.failure(
            locationServicesEnabled: locationServicesEnabled,
            authorizationStatus: locationManagerDelegate.locationManager.authorizationStatus,
            accuracyAuthorization: locationManagerDelegate.locationManager.accuracyAuthorization
        ) {
            completion(.failure(nativeGeofenceError(failure)))
            return
        }

        let region: CLCircularRegion
        do {
            region = try monitoredRegion(for: geofence)
        } catch {
            completion(.failure(error))
            return
        }

        locationManagerDelegate.startMonitoring(
            region: region,
            callbackHandle: geofence.callbackHandle,
            callbackContext: geofence.callbackContext,
            initialTrigger: geofence.iosSettings.initialTrigger,
            completion: completion
        )
    }
    
    func reCreateAfterReboot(completion: @escaping (Result<Void, Error>) -> Void) {
        log.info("Re-create after reboot called. iOS handles this automatically, nothing for us to do here.")
        fileLog.info("Re-create after reboot called. iOS handles this automatically, nothing for us to do here.")
        NativeGeofenceDiagnostics.record(
            .recovery,
            succeeded: true,
            outcome: "ios_managed",
            geofenceCount: NativeGeofencePersistence.getRegionCallbackIds().count
        )
        completion(.success(()))
    }

    func getStatus(
        completion: @escaping (Result<NativeGeofenceStatusWire, Error>) -> Void
    ) {
        let authorizationStatus = locationManagerDelegate.locationManager.authorizationStatus
        let accuracyAuthorization = locationManagerDelegate.locationManager.accuracyAuthorization
        let backgroundRefreshStatus: NativeGeofenceBackgroundRefreshStatus = switch UIApplication
            .shared.backgroundRefreshStatus {
        case .available: .available
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
        let monitoringAvailable = CLLocationManager.isMonitoringAvailable(
            for: CLCircularRegion.self
        )
        let persistedIds = NativeGeofencePersistence.getRegionCallbackIds().sorted()
        let monitoredCount = ownedMonitoredRegions().count
        let dispatcherRegistered = NativeGeofencePersistence.getCallbackDispatcherHandle() != nil
        let refreshDecision = IosCallbackRefreshPolicy.evaluate(
            registrationCount: persistedIds.count,
            storedPackageFingerprint: NativeGeofencePersistence
                .getSynchronizedPackageFingerprint(),
            registrationPackageFingerprints: persistedIds.map {
                NativeGeofencePersistence.getRegionCallbackPackageFingerprint(id: $0)
            },
            currentPackageFingerprint: currentPackageFingerprint()
        )
        let osVersion = UIDevice.current.systemVersion
        locationServicesQueue.async {
            let locationServicesEnabled = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async {
                let permission = IosLocationPermissionEvidence.from(
                    authorizationStatus,
                    accuracyAuthorization: accuracyAuthorization
                )
                let refreshState: NativeGeofenceCallbackRefreshState
                switch refreshDecision {
                case .notApplicable:
                    refreshState = .notApplicable
                case .refreshRequired:
                    refreshState = .refreshRequired
                case .unknown:
                    refreshState = .unknown
                }
                let health = IosNativeGeofenceStatusHealth.compute(
                    persistedCount: persistedIds.count,
                    locationPermission: permission.locationPermissionGranted,
                    backgroundPermission: permission.backgroundLocationPermissionGranted,
                    preciseLocationPermission:
                        permission.preciseLocationPermissionGranted,
                    backgroundRefreshAvailable: backgroundRefreshStatus == .available,
                    locationServicesEnabled: locationServicesEnabled,
                    monitoringAvailable: monitoringAvailable,
                    dispatcherRegistered: dispatcherRegistered,
                    refreshState: refreshState,
                    monitoredCount: monitoredCount
                )
                let deliveryTrace = IosNativeGeofenceDeliveryDiagnostics.shared.snapshot()
                completion(
                    .success(
                        NativeGeofenceStatusWire(
                            platform: .ios,
                            osVersion: osVersion,
                            persistedGeofenceCount: Int64(persistedIds.count),
                            locationPermissionGranted: permission.locationPermissionGranted,
                            backgroundLocationPermissionGranted:
                                permission.backgroundLocationPermissionGranted,
                            preciseLocationPermissionGranted:
                                permission.preciseLocationPermissionGranted,
                            backgroundRefreshStatus: backgroundRefreshStatus,
                            notificationPermissionGranted: nil,
                            locationServicesEnabled: locationServicesEnabled,
                            monitoringAvailable: monitoringAvailable,
                            playServicesAvailable: nil,
                            callbackPendingIntentAvailable: nil,
                            callbackReceiverAvailable: nil,
                            canEnumerateLivePlatformRegistrations: true,
                            pluginOwnedMonitoringCount: Int64(monitoredCount),
                            callbackDispatcherRegistered: dispatcherRegistered,
                            callbackRefreshState: refreshState,
                            registrationHealth: health,
                            lastRegistrationFact: NativeGeofenceDiagnostics.fact(.registration),
                            lastRemovalFact: NativeGeofenceDiagnostics.fact(.removal),
                            lastBroadcastFact: NativeGeofenceDiagnostics.fact(.broadcast),
                            lastEnqueueFact: NativeGeofenceDiagnostics.fact(.enqueue),
                            lastWorkerFact: NativeGeofenceDiagnostics.fact(.worker),
                            lastRecoveryFact: NativeGeofenceDiagnostics.fact(.recovery),
                            lastForegroundFact: NativeGeofenceDiagnostics.fact(.foreground),
                            deliveryTrace: deliveryTrace.entries.map { entry in
                                NativeGeofenceDeliveryTraceWire(
                                    sequence: entry.sequence,
                                    occurredAtMillis: entry.occurredAtMillis,
                                    elapsedRealtimeMillis: entry.elapsedRealtimeMillis,
                                    traceId: nil,
                                    stage: entry.stage,
                                    outcome: entry.outcome,
                                    event: entry.event,
                                    geofenceCount: entry.geofenceCount.map(Int64.init),
                                    attempt: nil,
                                    owner: entry.owner,
                                    reasonCode: entry.reasonCode,
                                    durationMillis: nil,
                                    queueAgeMillis: nil,
                                    hasLocation: nil,
                                    locationAgeMillis: nil,
                                    accuracyMeters: nil,
                                    processorSource: "ios_delegate",
                                    processorClass: "CLLocationManagerDelegate",
                                    errorType: nil
                                )
                            },
                            deliveryTraceDroppedCount: deliveryTrace.droppedCount
                        )
                    )
                )
            }
        }
    }

    func getSynchronizationState(
        desiredRegistrations: [GeofenceWire],
        completion: @escaping (
            Result<NativeGeofenceSynchronizationStateWire, Error>
        ) -> Void
    ) {
        operationQueue.enqueueExclusive { [weak self] finish in
            guard let self else {
                completion(
                    .failure(
                        nativeGeofenceError(
                            .pluginInternal,
                            message: "The iOS geofence runtime was released."
                        )
                    )
                )
                finish()
                return
            }
            do {
                let desired = try prepareSynchronizationRegistrations(
                    desiredRegistrations
                )
                let callbackIds = NativeGeofencePersistence.getRegionCallbackIds()
                let scopedCallbackIds = callbackIds.intersection(
                    desired.map { $0.wire.id }
                )
                let packageFingerprint = currentPackageFingerprint()
                let regions = ownedMonitoredRegions()
                let liveIds = Set(regions.map(\.identifier))
                let registrations = regions.compactMap(synchronizationWire).sorted {
                    $0.id < $1.id
                }
                let maximumDistance = locationManagerDelegate.locationManager
                    .maximumRegionMonitoringDistance
                let normalizedMaximumDistance = maximumDistance.isFinite
                    && maximumDistance > 0
                    ? maximumDistance
                    : nil
                completion(
                    .success(
                        NativeGeofenceSynchronizationStateWire(
                            platform: .ios,
                            pluginOwnedIds: callbackIds.sorted(),
                            registrations: registrations,
                            inactiveRegistrationIds: callbackIds
                                .subtracting(liveIds)
                                .sorted(),
                            registrationFingerprint: NativeGeofencePersistence
                                .getSynchronizationFingerprint(),
                            desiredRegistrationFingerprint:
                                IosGeofenceSynchronizationPlanner
                                    .desiredRegistrationFingerprint(
                                        desired.map(\.plannerRegistration)
                                    ),
                            callbackFingerprintCurrent: NativeGeofencePersistence
                                .callbackPackageFingerprintsCurrent(
                                    ids: scopedCallbackIds,
                                    currentFingerprint: packageFingerprint
                                ),
                            iosMaximumRegionMonitoringDistance:
                                normalizedMaximumDistance
                        )
                    )
                )
            } catch {
                completion(.failure(error))
            }
            finish()
        }
    }

    func synchronizeGeofences(
        desiredRegistrations: [GeofenceWire],
        removeUnlisted: Bool,
        completion: @escaping (
            Result<NativeGeofenceSynchronizationResultWire, Error>
        ) -> Void
    ) {
        operationQueue.enqueueExclusive { [weak self] finish in
            guard let self else {
                completion(
                    .failure(
                        nativeGeofenceError(
                            .pluginInternal,
                            message: "The iOS geofence runtime was released."
                        )
                    )
                )
                finish()
                return
            }

            var didResolve = false
            func resolve(
                _ result: Result<NativeGeofenceSynchronizationResultWire, Error>
            ) {
                guard !didResolve else { return }
                didResolve = true
                completion(result)
                finish()
            }

            let initialEvaluation: IosSynchronizationEvaluation
            do {
                initialEvaluation = try evaluateSynchronization(
                    desiredRegistrations: desiredRegistrations,
                    removeUnlisted: removeUnlisted
                )
            } catch {
                resolve(.failure(error))
                return
            }
            // Preserve the old public no-op contract: mutation-only permission,
            // availability, and Location Services checks are not consulted when
            // the fresh native state already matches the desired registrations.
            guard initialEvaluation.decision.requiresSynchronization else {
                resolve(
                    .success(
                        synchronizationResult(
                            evaluation: initialEvaluation,
                            didSynchronize: false
                        )
                    )
                )
                return
            }

            locationServicesQueue.async { [weak self] in
                let enabled = CLLocationManager.locationServicesEnabled()
                DispatchQueue.main.async {
                    guard let self else {
                        resolve(
                            .failure(
                                nativeGeofenceError(
                                    .pluginInternal,
                                    message: "The iOS geofence runtime was released."
                                )
                            )
                        )
                        return
                    }

                    let evaluation: IosSynchronizationEvaluation
                    do {
                        // Core Location delegate callbacks can change lifecycle
                        // evidence while the off-main services query is running.
                        // Re-evaluate immediately before the mutation snapshot.
                        evaluation = try self.evaluateSynchronization(
                            desiredRegistrations: desiredRegistrations,
                            removeUnlisted: removeUnlisted
                        )
                    } catch {
                        resolve(.failure(error))
                        return
                    }
                    guard evaluation.decision.requiresSynchronization else {
                        resolve(
                            .success(
                                self.synchronizationResult(
                                    evaluation: evaluation,
                                    didSynchronize: false
                                )
                            )
                        )
                        return
                    }

                    self.performSynchronization(
                        evaluation: evaluation,
                        locationServicesEnabled: enabled
                    ) { result in
                        switch result {
                        case .success:
                            resolve(
                                .success(
                                    self.synchronizationResult(
                                        evaluation: evaluation,
                                        didSynchronize: true
                                    )
                                )
                            )
                        case .failure(let error):
                            resolve(.failure(error))
                        }
                    }
                }
            }
        }
    }
    
    func getGeofenceIds() throws -> [String] {
        let geofenceIds = ownedMonitoredRegions()
            .map(\.identifier)
            .sorted()
        log.debug("getGeofenceIds() found \(geofenceIds.count) geofence(s).")
        fileLog.debug("getGeofenceIds() found \(geofenceIds.count) geofence(s).")
        return geofenceIds
    }
    
    func getGeofences() throws -> [ActiveGeofenceWire] {
        var geofences: [ActiveGeofenceWire] = []
        for region in ownedMonitoredRegions() {
            if let activeGeofence = ActiveGeofenceWires.fromRegion(region) {
                geofences.append(activeGeofence)
            } else {
                log.error("Unable to convert owned region: \(region)")
                fileLog.error("Unable to convert owned region: \(region)")
            }
        }
        log.debug("getGeofences() found \(geofences.count) geofence(s).")
        fileLog.debug("getGeofences() found \(geofences.count) geofence(s).")
        return geofences
    }

    private func prepareSynchronizationRegistrations(
        _ desiredRegistrations: [GeofenceWire]
    ) throws -> [IosPreparedSynchronizationRegistration] {
        let desiredIds = desiredRegistrations.map(\.id)
        guard Set(desiredIds).count == desiredIds.count else {
            throw nativeGeofenceError(
                .invalidArguments,
                message: "Synchronization registrations contain duplicate geofence IDs."
            )
        }
        return try desiredRegistrations.map { wire in
            let region = try monitoredRegion(for: wire)
            return IosPreparedSynchronizationRegistration(
                wire: wire,
                region: region,
                plannerRegistration: synchronizationPlannerRegistration(
                    region: region,
                    callbackHandle: wire.callbackHandle,
                    callbackContext: wire.callbackContext
                )
            )
        }.sorted { $0.wire.id < $1.wire.id }
    }

    private func evaluateSynchronization(
        desiredRegistrations: [GeofenceWire],
        removeUnlisted: Bool
    ) throws -> IosSynchronizationEvaluation {
        let desired = try prepareSynchronizationRegistrations(
            desiredRegistrations
        )
        let callbackIds = NativeGeofencePersistence.getRegionCallbackIds()
        let allMonitoredRegions = locationManagerDelegate.locationManager
            .monitoredRegions
        let ownedRegions = PluginOwnedRegions.select(
            from: allMonitoredRegions,
            callbackIds: callbackIds
        )
        let liveIds = Set(ownedRegions.map(\.identifier))
        let packageFingerprint = currentPackageFingerprint()
        let scopedCallbackIds = callbackIds.intersection(
            desired.map { $0.wire.id }
        )
        let packageFingerprintCurrent = NativeGeofencePersistence
            .callbackPackageFingerprintsCurrent(
                ids: scopedCallbackIds,
                currentFingerprint: packageFingerprint
            )
        let currentRegistrations: [IosGeofenceSynchronizationRegistration] =
            ownedRegions.compactMap { region in
                guard let callbackHandle = NativeGeofencePersistence
                    .getRegionCallbackHandle(id: region.identifier)
                else {
                    return nil
                }
                return synchronizationPlannerRegistration(
                    region: region,
                    callbackHandle: callbackHandle,
                    callbackContext: NativeGeofencePersistence
                        .getRegionCallbackContext(id: region.identifier)
                )
            }
        let decision = IosGeofenceSynchronizationPlanner.decide(
            current: IosGeofenceSynchronizationInventory(
                pluginOwnedIds: callbackIds,
                registrations: currentRegistrations,
                inactiveRegistrationIds: callbackIds.subtracting(liveIds),
                registrationFingerprint: NativeGeofencePersistence
                    .getSynchronizationFingerprint(),
                callbackFingerprintCurrent: packageFingerprintCurrent
            ),
            desired: desired.map(\.plannerRegistration),
            removeUnlisted: removeUnlisted
        )
        return IosSynchronizationEvaluation(
            desired: desired,
            removeUnlisted: removeUnlisted,
            callbackIds: callbackIds,
            allMonitoredRegions: allMonitoredRegions,
            ownedRegions: ownedRegions,
            packageFingerprint: packageFingerprint,
            requiresRegistrationPreflight: IosGeofenceSynchronizationPlanner
                .requiresRegistrationPreflight(
                    current: currentRegistrations,
                    desired: desired.map(\.plannerRegistration)
                ),
            decision: decision
        )
    }

    private func synchronizationPlannerRegistration(
        region: CLCircularRegion,
        callbackHandle: Int64,
        callbackContext: Int64?
    ) -> IosGeofenceSynchronizationRegistration {
        IosGeofenceSynchronizationRegistration(
            id: region.identifier,
            latitude: region.center.latitude,
            longitude: region.center.longitude,
            radiusMeters: region.radius,
            triggers: [
                region.notifyOnEntry ? "enter" : nil,
                region.notifyOnExit ? "exit" : nil,
            ].compactMap { $0 },
            callbackHandle: callbackHandle,
            callbackContext: callbackContext
        )
    }

    private func synchronizationResult(
        evaluation: IosSynchronizationEvaluation,
        didSynchronize: Bool
    ) -> NativeGeofenceSynchronizationResultWire {
        NativeGeofenceSynchronizationResultWire(
            didSynchronize: didSynchronize,
            reasons: evaluation.decision.reasons.map { reason in
                switch reason {
                case .firstRun: .firstRun
                case .callbackFingerprintChanged: .callbackFingerprintChanged
                case .registrationDrift: .registrationDrift
                }
            },
            desiredCount: Int64(evaluation.decision.desiredCount),
            previousCount: Int64(evaluation.decision.previousCount),
            registrationFingerprint: evaluation.decision
                .desiredRegistrationFingerprint
        )
    }

    private func performSynchronization(
        evaluation: IosSynchronizationEvaluation,
        locationServicesEnabled: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let desired = evaluation.desired
        let desiredIds = desired.map { $0.wire.id }
        let desiredIdSet = Set(desiredIds)
        let callbackIds = evaluation.callbackIds
        let allMonitoredRegions = evaluation.allMonitoredRegions
        for value in desired {
            guard let existing = allMonitoredRegions.first(where: {
                $0.identifier == value.wire.id
            }) else {
                continue
            }
            guard callbackIds.contains(value.wire.id), existing is CLCircularRegion else {
                completion(
                    .failure(
                        nativeGeofenceError(
                            .iosRegionMonitoringFailed,
                            message: "Geofence ID=\(value.wire.id) conflicts with a region not registered by this plugin."
                        )
                    )
                )
                return
            }
        }

        let ownedRegions = evaluation.ownedRegions
        let ownedLiveIds = Set(ownedRegions.map(\.identifier))
        if evaluation.requiresRegistrationPreflight {
            guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
                completion(
                    .failure(
                        nativeGeofenceError(
                            .iosRegionMonitoringFailed,
                            message: "iOS region monitoring is not available on this device."
                        )
                    )
                )
                return
            }
            if let failure = IosGeofenceSynchronizationPreflight.failure(
                requiresRegistrationPreflight:
                    evaluation.requiresRegistrationPreflight,
                locationServicesEnabled: locationServicesEnabled,
                authorizationStatus: locationManagerDelegate.locationManager
                    .authorizationStatus,
                accuracyAuthorization: locationManagerDelegate.locationManager
                    .accuracyAuthorization
            ) {
                completion(.failure(nativeGeofenceError(failure)))
                return
            }

            let finalOwnedLiveIds = evaluation.removeUnlisted
                ? desiredIdSet
                : ownedLiveIds.union(desiredIdSet)
            let foreignRegionCount = allMonitoredRegions.count - ownedRegions.count
            guard foreignRegionCount + finalOwnedLiveIds.count <= 20 else {
                completion(
                    .failure(
                        nativeGeofenceError(
                            .iosRegionMonitoringFailed,
                            message: "Synchronization would exceed iOS's 20 monitored-region limit."
                        )
                    )
                )
                return
            }
        }

        let regionSnapshots = ownedRegions.compactMap { region -> IosSynchronizedRegionSnapshot? in
            guard let handle = NativeGeofencePersistence.getRegionCallbackHandle(
                id: region.identifier
            ) else {
                return nil
            }
            return IosSynchronizedRegionSnapshot(
                region: region,
                callbackHandle: handle,
                callbackContext: NativeGeofencePersistence
                    .getRegionCallbackContext(id: region.identifier)
            )
        }
        let snapshot = IosSynchronizationTransactionSnapshot(
            regions: regionSnapshots,
            persistence: NativeGeofencePersistence.synchronizationSnapshot()
        )
        let boundaryDeferralIds = Set(desiredIds)
        var boundaryCandidatesByIdentifier:
            [String: [PendingBoundaryRegistrationCandidate]] = [:]
        for value in desired {
            var candidates: [PendingBoundaryRegistrationCandidate] = []
            if let previous = regionSnapshots.first(where: {
                $0.region.identifier == value.wire.id
            }) {
                candidates.append(
                    PendingBoundaryRegistrationCandidate(
                        region: previous.region,
                        callbackHandle: previous.callbackHandle,
                        callbackContext: previous.callbackContext
                    )
                )
            }
            candidates.append(
                PendingBoundaryRegistrationCandidate(
                    region: value.region,
                    callbackHandle: value.wire.callbackHandle,
                    callbackContext: value.wire.callbackContext
                )
            )
            boundaryCandidatesByIdentifier[value.wire.id] = candidates
            locationManagerDelegate
                .beginSynchronizationBoundaryEventDeferral(
                    identifier: value.wire.id,
                    candidates: candidates
                )
        }
        var platformTouchedIds = Set<String>()
        var authorityTouchedIds = Set<String>()

        if evaluation.removeUnlisted {
            let removalIds = callbackIds.subtracting(desiredIdSet).sorted()
            platformTouchedIds.formUnion(
                removalIds.filter(ownedLiveIds.contains)
            )
            authorityTouchedIds.formUnion(removalIds)
            for id in removalIds {
                guard performRemoveGeofenceById(
                    id: id,
                    recordDiagnostics: false
                ) else {
                    rollbackSynchronization(
                        snapshot: snapshot,
                        platformTouchedIds: platformTouchedIds,
                        authorityTouchedIds: authorityTouchedIds,
                        boundaryDeferralIds: boundaryDeferralIds,
                        boundaryCandidatesByIdentifier:
                            boundaryCandidatesByIdentifier,
                        originalError: nativeGeofenceError(
                            .pluginInternal,
                            message: "Failed to durably cancel deferred iOS callbacks for geofence ID=\(id)."
                        ),
                        completion: completion
                    )
                    return
                }
            }
        }

        let packageFingerprint = evaluation.packageFingerprint

        func fail(_ error: Error) {
            rollbackSynchronization(
                snapshot: snapshot,
                platformTouchedIds: platformTouchedIds,
                authorityTouchedIds: authorityTouchedIds,
                boundaryDeferralIds: boundaryDeferralIds,
                boundaryCandidatesByIdentifier:
                    boundaryCandidatesByIdentifier,
                originalError: error,
                completion: completion
            )
        }

        func synchronizeNext(_ index: Int) {
            guard index < desired.count else {
                let committed = evaluation.removeUnlisted
                    ? NativeGeofencePersistence.commitAuthoritativeSynchronization(
                        registrationFingerprint: evaluation.decision
                            .desiredRegistrationFingerprint,
                        packageFingerprint: packageFingerprint
                    )
                    : NativeGeofencePersistence.commitPartialSynchronization(
                        ids: desiredIdSet,
                        packageFingerprint: packageFingerprint
                    )
                guard committed else {
                    fail(
                        nativeGeofenceError(
                            .pluginInternal,
                            message: "Failed to durably commit iOS synchronization evidence."
                        )
                    )
                    return
                }
                locationManagerDelegate
                    .finishSynchronizationBoundaryEventDeferral(
                        identifiers: boundaryDeferralIds
                    ) {
                        completion(.success(()))
                    }
                return
            }

            let value = desired[index]
            let existing = ownedMonitoredRegions().first {
                $0.identifier == value.wire.id
            }
            let platformMatches = existing.map {
                RegionMonitoringSemantics.matches($0, value.region)
            } ?? false
            let metadataMatches = NativeGeofencePersistence
                .getRegionCallbackHandle(id: value.wire.id)
                == value.wire.callbackHandle
                && NativeGeofencePersistence
                    .getRegionCallbackContext(id: value.wire.id)
                    == value.wire.callbackContext
            let registrationPackageFingerprintCurrent =
                NativeGeofencePersistence.getRegionCallbackPackageFingerprint(
                    id: value.wire.id
                ) == packageFingerprint
            if platformMatches
                && metadataMatches
                && registrationPackageFingerprintCurrent
            {
                synchronizeNext(index + 1)
                return
            }

            if !platformMatches {
                platformTouchedIds.insert(value.wire.id)
                authorityTouchedIds.insert(value.wire.id)
            }
            locationManagerDelegate.clearSynchronizationRemovalTombstone(
                matching: value.region
            )
            let registrationCompletion: (Result<Void, any Error>) -> Void = { result in
                switch result {
                case .success:
                    synchronizeNext(index + 1)
                case .failure(let error):
                    fail(error)
                }
            }
            locationManagerDelegate.startMonitoringForSynchronization(
                region: value.region,
                callbackHandle: value.wire.callbackHandle,
                callbackContext: value.wire.callbackContext,
                completion: registrationCompletion
            )
        }

        synchronizeNext(0)
    }

    private func rollbackSynchronization(
        snapshot: IosSynchronizationTransactionSnapshot,
        platformTouchedIds: Set<String>,
        authorityTouchedIds: Set<String>,
        boundaryDeferralIds: Set<String>,
        boundaryCandidatesByIdentifier:
            [String: [PendingBoundaryRegistrationCandidate]],
        originalError: Error,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var rollbackFailures: [String] = []
        let currentTouchedRegions = locationManagerDelegate.locationManager
            .monitoredRegions
            .compactMap { $0 as? CLCircularRegion }
            .filter { platformTouchedIds.contains($0.identifier) }
        for region in currentTouchedRegions {
            locationManagerDelegate.recordRemoval(of: region)
            locationManagerDelegate.locationManager.stopMonitoring(for: region)
        }
        if !NativeGeofencePersistence.restoreSynchronizationSnapshot(
            snapshot.persistence
        ) {
            rollbackFailures.append("failed to restore persisted metadata")
        }

        let regionsToRestore = snapshot.regions
            .filter { platformTouchedIds.contains($0.region.identifier) }
            .sorted { $0.region.identifier < $1.region.identifier }

        func finishRollback() {
            if !NativeGeofencePersistence.restoreSynchronizationSnapshot(
                snapshot.persistence
            ) {
                rollbackFailures.append(
                    "failed to restore persisted metadata after platform restoration"
                )
            }
            let authorityRegions: [CLCircularRegion]
            if rollbackFailures.isEmpty {
                authorityRegions = snapshot.regions.map(\.region)
            } else {
                let plan = PendingBoundarySynchronizationRollbackPlanner
                    .makePlan(
                        monitoredRegions: ownedMonitoredRegions(),
                        authorityTouchedIdentifiers: authorityTouchedIds,
                        candidatesByIdentifier:
                            boundaryCandidatesByIdentifier,
                        getCallbackHandle:
                            NativeGeofencePersistence
                                .getRegionCallbackHandle,
                        getCallbackContext:
                            NativeGeofencePersistence
                                .getRegionCallbackContext
                    )
                for authority in plan.authorities {
                    locationManagerDelegate
                        .applySynchronizationBoundaryAuthority(authority)
                }
                for identifier in plan.incoherentIdentifiers {
                    NativeGeofencePersistence.removeRegionCallbackHandle(
                        id: identifier
                    )
                    NativeGeofencePersistence.setRegionCallbackContext(
                        id: identifier,
                        context: nil
                    )
                    rollbackFailures.append(
                        "geofence ID=\(identifier): no coherent monitored registration winner remained"
                    )
                }
                authorityRegions = plan.authorities.map(\.region)
            }
            locationManagerDelegate.restoreSynchronizationAuthority(
                regions: authorityRegions,
                transactionOwnedIds: authorityTouchedIds
            )
            locationManagerDelegate
                .finishSynchronizationBoundaryEventDeferral(
                    identifiers: boundaryDeferralIds
                ) {
                    guard !rollbackFailures.isEmpty else {
                        completion(.failure(originalError))
                        return
                    }
                    completion(
                        .failure(
                            nativeGeofenceError(
                                .pluginInternal,
                                message: "Synchronization failed: \(originalError.localizedDescription) Rollback failed: \(rollbackFailures.joined(separator: "; "))."
                            )
                        )
                    )
                }
        }

        func restoreNext(_ index: Int) {
            guard index < regionsToRestore.count else {
                finishRollback()
                return
            }
            let value = regionsToRestore[index]
            locationManagerDelegate.clearSynchronizationRemovalTombstone(
                matching: value.region,
                protectRetainedRegionsThroughConfirmationAttempts: true
            )
            locationManagerDelegate.startMonitoringForSynchronization(
                region: value.region,
                callbackHandle: value.callbackHandle,
                callbackContext: value.callbackContext,
                forceMonitoring: true
            ) { result in
                if case .failure(let error) = result {
                    rollbackFailures.append(
                        "geofence ID=\(value.region.identifier): \(error.localizedDescription)"
                    )
                }
                restoreNext(index + 1)
            }
        }

        restoreNext(0)
    }

    private func synchronizationWire(
        region: CLCircularRegion
    ) -> GeofenceWire? {
        guard let callbackHandle = NativeGeofencePersistence
            .getRegionCallbackHandle(id: region.identifier)
        else {
            return nil
        }
        return GeofenceWire(
            id: region.identifier,
            location: LocationWire(
                latitude: region.center.latitude,
                longitude: region.center.longitude,
                isMock: false
            ),
            radiusMeters: region.radius,
            triggers: [
                region.notifyOnEntry ? .enter : nil,
                region.notifyOnExit ? .exit : nil,
            ].compactMap { $0 },
            iosSettings: IosGeofenceSettingsWire(initialTrigger: false),
            androidSettings: AndroidGeofenceSettingsWire(
                initialTriggers: [],
                expirationDurationMillis: nil,
                loiteringDelayMillis: 0,
                notificationResponsivenessMillis: nil
            ),
            callbackHandle: callbackHandle,
            callbackContext: NativeGeofencePersistence
                .getRegionCallbackContext(id: region.identifier)
        )
    }

    private func monitoredRegion(for geofence: GeofenceWire) throws -> CLCircularRegion {
        guard geofence.location.latitude.isFinite,
              (-90.0 ... 90.0).contains(geofence.location.latitude),
              geofence.location.longitude.isFinite,
              (-180.0 ... 180.0).contains(geofence.location.longitude)
        else {
            throw nativeGeofenceError(
                .invalidArguments,
                message: "Geofence location is invalid."
            )
        }
        guard geofence.triggers.contains(.enter) || geofence.triggers.contains(.exit) else {
            throw nativeGeofenceError(
                .invalidArguments,
                message: "iOS geofences require an enter or exit trigger."
            )
        }
        let maximumRadius = locationManagerDelegate.locationManager
            .maximumRegionMonitoringDistance
        guard let radius = IosRegionRadius.normalized(
            requestedRadius: geofence.radiusMeters,
            maximumRadius: maximumRadius
        ) else {
            throw nativeGeofenceError(
                .invalidArguments,
                message: "Geofence radius must be finite and strictly positive."
            )
        }
        let region = CLCircularRegion(
            center: CLLocationCoordinate2DMake(
                geofence.location.latitude,
                geofence.location.longitude
            ),
            radius: radius,
            identifier: geofence.id
        )
        region.notifyOnEntry = geofence.triggers.contains(.enter)
        region.notifyOnExit = geofence.triggers.contains(.exit)
        if radius != geofence.radiusMeters {
            log.info(
                "Clamped geofence ID=\(geofence.id) radius from \(geofence.radiusMeters) to \(radius)."
            )
            fileLog.info(
                "Clamped geofence ID=\(geofence.id) radius from \(geofence.radiusMeters) to \(radius)."
            )
        }
        return region
    }

    private func currentPackageFingerprint() -> String {
        NativeGeofencePersistence.currentPackageFingerprint()
    }
    
    func removeGeofenceById(id: String, completion: @escaping (Result<Void, any Error>) -> Void) {
        operationQueue.enqueueCancellation(id: id) { [weak self] finish in
            guard let self else {
                completion(
                    .failure(
                        nativeGeofenceError(
                            .pluginInternal,
                            message: "The iOS geofence runtime was released."
                        )
                    )
                )
                finish()
                return
            }
            if performRemoveGeofenceById(
                id: id,
                recordDiagnostics: true
            ) {
                completion(.success(()))
            } else {
                completion(
                    .failure(
                        nativeGeofenceError(
                            .pluginInternal,
                            message: "Failed to durably cancel deferred iOS callbacks for geofence ID=\(id); the geofence was left registered."
                        )
                    )
                )
            }
            finish()
        }
    }

    private func performRemoveGeofenceById(
        id: String,
        recordDiagnostics: Bool
    ) -> Bool {
        createPreflightRegistry.cancel(id: id)
        // Snapshot ownership before cancellation removes callback metadata.
        let regions = ownedMonitoredRegions().filter { $0.identifier == id }
        guard locationManagerDelegate.cancelMonitoringStart(id: id) else {
            log.error(
                "Aborted removal for geofence ID=\(id) because deferred callback cancellation could not be persisted."
            )
            fileLog.error(
                "Aborted removal for geofence ID=\(id) because deferred callback cancellation could not be persisted."
            )
            return false
        }
        for region in regions {
            locationManagerDelegate.recordRemoval(of: region)
            locationManagerDelegate.locationManager.stopMonitoring(for: region)
        }
        NativeGeofencePersistence.removeRegionCallbackHandle(id: id)
        NativeGeofencePersistence.setRegionCallbackContext(id: id, context: nil)
        if recordDiagnostics {
            NativeGeofenceDiagnostics.record(
                .removal,
                succeeded: true,
                outcome: "removed_by_id",
                geofenceCount: regions.count
            )
        }
        log.debug("Removed \(regions.count) geofence(s) with ID=\(id).")
        fileLog.diagnostic("Removed \(regions.count) geofence(s) with ID=\(id).")
        return true
    }
    
    func removeAllGeofences(completion: @escaping (Result<Void, any Error>) -> Void) {
        operationQueue.enqueueCancellation(id: nil) { [weak self] finish in
            guard let self else {
                completion(
                    .failure(
                        nativeGeofenceError(
                            .pluginInternal,
                            message: "The iOS geofence runtime was released."
                        )
                    )
                )
                finish()
                return
            }
            if performRemoveAllGeofences() {
                completion(.success(()))
            } else {
                completion(
                    .failure(
                        nativeGeofenceError(
                            .pluginInternal,
                            message: "Failed to durably cancel deferred iOS callbacks; geofences were left registered."
                        )
                    )
                )
            }
            finish()
        }
    }

    private func performRemoveAllGeofences() -> Bool {
        createPreflightRegistry.cancelAll()
        // CLLocationManager.monitoredRegions is app-wide. Snapshot only regions
        // backed by plugin callback metadata before clearing that metadata.
        let regions = ownedMonitoredRegions()
        guard locationManagerDelegate.cancelAllMonitoringStarts() else {
            log.error(
                "Aborted remove-all because deferred callback cancellation could not be persisted."
            )
            fileLog.error(
                "Aborted remove-all because deferred callback cancellation could not be persisted."
            )
            return false
        }
        for region in regions {
            locationManagerDelegate.recordRemoval(of: region)
            locationManagerDelegate.locationManager.stopMonitoring(for: region)
        }
        NativeGeofencePersistence.removeAllRegionCallbackHandles()
        NativeGeofencePersistence.removeAllRegionCallbackContexts()
        NativeGeofenceDiagnostics.record(
            .removal,
            succeeded: true,
            outcome: "removed_all",
            geofenceCount: regions.count
        )
        log.debug("Removed \(regions.count) geofence(s).")
        fileLog.diagnostic("Removed \(regions.count) geofence(s).")
        return true
    }

    private func ownedMonitoredRegions() -> [CLCircularRegion] {
        PluginOwnedRegions.select(
            from: locationManagerDelegate.locationManager.monitoredRegions,
            callbackIds: NativeGeofencePersistence.getRegionCallbackIds()
        )
    }
}
