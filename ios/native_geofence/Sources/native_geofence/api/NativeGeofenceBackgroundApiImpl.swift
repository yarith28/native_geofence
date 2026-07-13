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
        params: GeofenceCallbackParamsWire
    ) -> Bool {
        let canEnqueue = withStateLock {
            guard !closed else { return false }
            return true
        }
        guard canEnqueue, session.enqueue(params) else {
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
                if case .success = result {
                    self.log.debug(
                        "Dart callback for geofence IDs=[\(Self.geofenceIds(params))] completed."
                    )
                } else {
                    self.log.error(
                        "Dart callback for geofence IDs=[\(Self.geofenceIds(params))] failed."
                    )
                }
            }
        }
    }

    func promoteToForeground() throws {
        log.info("promoteToForeground called. iOS does not distinguish between foreground and background, nothing to do here.")
    }

    func demoteToBackground() throws {
        log.info("demoteToBackground called. iOS does not distinguish between foreground and background, nothing to do here.")
    }

    func forceCleanup(reason: String) {
        session.forceClose(reason: reason)
    }

    private func close(
        reason: SerialCallbackSession<GeofenceCallbackParamsWire>.CloseReason
    ) {
        let cleanupToRun: (() -> Void)? = withStateLock {
            guard !closed else { return nil }
            closed = true
            defer { cleanup = nil }
            return cleanup
        }
        guard let cleanupToRun else { return }

        switch reason {
        case .idle:
            log.debug("Background callback session is idle; cleaning up.")
        case .startupTimeout(let ids):
            log.error(
                "Timed out waiting for Dart geofence API initialization; IDs=[\(ids)]."
            )
        case .callbackTimeout(let ids):
            log.error(
                "Timed out waiting for Dart geofence callback; IDs=[\(ids)]."
            )
        case .forced(let message):
            log.error("\(message)")
        }
        runCleanupOnMain(cleanupToRun)
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
            DispatchQueue.main.async(execute: cleanup)
        }
    }

    private static func geofenceIds(
        _ params: GeofenceCallbackParamsWire
    ) -> String {
        params.geofences.map(\.id).joined(separator: ",")
    }
}
