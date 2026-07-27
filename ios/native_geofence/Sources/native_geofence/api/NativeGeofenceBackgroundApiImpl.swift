import Flutter
import Foundation
import OSLog

class NativeGeofenceBackgroundApiImpl: NativeGeofenceBackgroundApi {
    private let log = Logger(
        subsystem: Constants.PACKAGE_NAME,
        category: "NativeGeofenceBackgroundApiImpl"
    )
    private let binaryMessenger: FlutterBinaryMessenger
    private let stateLock = NSLock()
    private var cleanup: (() -> Void)?
    private var deliveryCompletions:
        [String: (IosGeofenceCallbackDeliveryOutcome) -> Void] = [:]
    private var closed = false

    private lazy var session = SerialCallbackSession<GeofenceCallbackParamsWire>(
        startupTimeoutMillis: 30_000,
        callbackTimeoutMillis: 30_000,
        idleGraceMillis: 2_000,
        describe: Self.geofenceIds,
        schedule: { delayMillis, work in
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(delayMillis),
                execute: work
            )
        },
        onClose: { [weak self] reason in
            self?.close(reason: reason)
        }
    )

    init(
        binaryMessenger: FlutterBinaryMessenger,
        cleanup: @escaping () -> Void
    ) {
        self.binaryMessenger = binaryMessenger
        self.cleanup = cleanup
    }

    /// Returns true once this open native session owns the delivery attempt.
    @discardableResult
    func geofenceTriggered(
        params: GeofenceCallbackParamsWire,
        completion deliveryCompletion:
            @escaping (IosGeofenceCallbackDeliveryOutcome) -> Void
    ) -> Bool {
        guard let eventId = params.eventId else {
            log.error("Background callback had no delivery-attempt ID; rejecting event.")
            return false
        }
        let canEnqueue = withStateLock {
            guard !closed else { return false }
            guard deliveryCompletions[eventId] == nil else { return false }
            deliveryCompletions[eventId] = deliveryCompletion
            return true
        }
        guard canEnqueue, session.enqueue(params) else {
            _ = takeDeliveryCompletion(eventId: eventId)
            log.error("Background callback session is closed; rejecting event.")
            return false
        }
        log.debug(
            "Accepted geofence callback for IDs=[\(Self.geofenceIds(params))]."
        )
        return true
    }

    func triggerApiInitialized() throws {
        guard withStateLock({ !closed }) else {
            log.debug("Ignoring trigger API initialization for a closed session.")
            return
        }
        let triggerApi = NativeGeofenceTriggerApi(binaryMessenger: binaryMessenger)
        session.markReady { [weak self] params, completion in
            guard let self else {
                _ = completion()
                return
            }
            self.log.debug(
                "Calling Dart callback for geofence IDs=[\(Self.geofenceIds(params))] event=\(String(describing: params.event))."
            )
            triggerApi.geofenceTriggered(params: params) { result in
                guard completion() else {
                    self.log.debug(
                        "Ignoring late Dart callback completion for geofence IDs=[\(Self.geofenceIds(params))]."
                    )
                    return
                }
                let outcome = iosGeofenceCallbackDeliveryOutcome(result)
                if outcome.didSucceed {
                    NativeGeofenceDiagnostics.record(
                        .worker,
                        succeeded: true,
                        outcome: "completed",
                        geofenceCount: params.geofences.count
                    )
                    self.log.debug(
                        "Dart callback for geofence IDs=[\(Self.geofenceIds(params))] completed."
                    )
                } else {
                    NativeGeofenceDiagnostics.record(
                        .worker,
                        succeeded: false,
                        outcome: Self.diagnosticOutcome(outcome),
                        geofenceCount: params.geofences.count
                    )
                    self.log.error(
                        "Dart callback for geofence IDs=[\(Self.geofenceIds(params))] failed."
                    )
                }
                if let eventId = params.eventId {
                    self.takeDeliveryCompletion(eventId: eventId)?(outcome)
                }
            }
        }
    }

    func promoteToForeground(completion: @escaping (Result<Void, Error>) -> Void) {
        log.info("promoteToForeground called. iOS does not distinguish between foreground and background, nothing to do here.")
        NativeGeofenceDiagnostics.record(
            .foreground,
            succeeded: true,
            outcome: "ios_noop_promote"
        )
        completion(.success(()))
    }

    func demoteToBackground() throws {
        log.info("demoteToBackground called. iOS does not distinguish between foreground and background, nothing to do here.")
        NativeGeofenceDiagnostics.record(
            .foreground,
            succeeded: true,
            outcome: "ios_noop_demote"
        )
    }

    func forceCleanup(reason: String) {
        session.forceClose(reason: reason)
    }

    private func close(
        reason: SerialCallbackSession<GeofenceCallbackParamsWire>.CloseReason
    ) {
        let closeActions: (() -> (
            cleanup: (() -> Void)?,
            completions: [(IosGeofenceCallbackDeliveryOutcome) -> Void]
        ))? = withStateLock {
            guard !closed else { return nil }
            closed = true
            defer { cleanup = nil }
            let completions = Array(deliveryCompletions.values)
            deliveryCompletions.removeAll()
            let cleanupToRun = cleanup
            return { (cleanupToRun, completions) }
        }
        guard let closeActions else { return }
        let actions = closeActions()
        switch reason {
        case .idle:
            log.debug("Background callback session is idle; cleaning up.")
        case .startupTimeout(let ids):
            NativeGeofenceDiagnostics.record(
                .worker,
                succeeded: false,
                outcome: "startup_timeout"
            )
            log.error(
                "Timed out waiting for Dart geofence API initialization; IDs=[\(ids)]."
            )
        case .callbackTimeout(let ids):
            NativeGeofenceDiagnostics.record(
                .worker,
                succeeded: false,
                outcome: "callback_timeout"
            )
            log.error(
                "Timed out waiting for Dart geofence callback; IDs=[\(ids)]."
            )
        case .forced(let message):
            NativeGeofenceDiagnostics.record(
                .worker,
                succeeded: false,
                outcome: "forced_cleanup"
            )
            log.error("\(message)")
        }
        if let cleanupToRun = actions.cleanup {
            runCleanupOnMain(cleanupToRun)
        }
        actions.completions.forEach { $0(.retryableFailure) }
    }

    private func takeDeliveryCompletion(
        eventId: String
    ) -> ((IosGeofenceCallbackDeliveryOutcome) -> Void)? {
        withStateLock {
            deliveryCompletions.removeValue(forKey: eventId)
        }
    }

    private static func diagnosticOutcome(
        _ outcome: IosGeofenceCallbackDeliveryOutcome
    ) -> String {
        switch outcome {
        case .succeeded:
            return "completed"
        case .retryableFailure:
            return "dart_delivery_retryable_failure"
        case .terminalFailure(let reason):
            return "dart_delivery_terminal_\(reason.rawValue)"
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func runCleanupOnMain(_ cleanup: @escaping () -> Void) {
        if Thread.isMainThread {
            cleanup()
        } else {
            DispatchQueue.main.sync(execute: cleanup)
        }
    }

    private static func geofenceIds(
        _ params: GeofenceCallbackParamsWire
    ) -> String {
        params.geofences.map(\.id).joined(separator: ",")
    }
}
