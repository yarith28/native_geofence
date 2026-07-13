import Flutter
import Foundation
import OSLog
import UIKit

/// Owns the Flutter runtime surfaces for one shared Core Location authority.
/// Main and headless messengers install the same `NativeGeofenceApiImpl`, so a
/// callback cannot accidentally create a second delegate or transaction state.
final class IosGeofenceRuntimeHost {
    private struct MainDelivery {
        let token: UUID
        let completion: (Bool) -> Void
        let watchdog: DispatchWorkItem
    }

    private struct CallbackBackgroundTask {
        let sessionId: UUID
        let identifier: UIBackgroundTaskIdentifier
    }

    private let log = Logger(
        subsystem: Constants.PACKAGE_NAME,
        category: "IosGeofenceRuntimeHost"
    )
    private let callbackBackgroundTaskName = "native_geofence.geofence_callback"
    private let mainMessenger: FlutterBinaryMessenger
    private let registerPlugins: FlutterPluginRegistrantCallback
    private let stateLock = NSRecursiveLock()

    private var mainTriggerReady = false
    private var activeMainDelivery: MainDelivery?
    private var headlessFlutterEngine: FlutterEngine?
    private var headlessBackgroundApi: NativeGeofenceBackgroundApiImpl?
    private var headlessSessionId: UUID?
    private var callbackBackgroundTask: CallbackBackgroundTask?
    private var detached = false

    private lazy var mainTriggerApi = NativeGeofenceTriggerApi(
        binaryMessenger: mainMessenger
    )
    private lazy var deliveryRouter = IosCallbackDeliveryRouter<GeofenceCallbackParamsWire>(
        selectRoute: { [weak self] in
            self?.shouldUseMainEngine == true ? .main : .headless
        },
        deliver: { [weak self] route, params, completion in
            guard let self else { return false }
            switch route {
            case .main:
                return self.deliverOnMainEngine(params, completion: completion)
            case .headless:
                return self.deliverOnHeadlessEngine(params, completion: completion)
            }
        }
    )
    private(set) lazy var locationManagerDelegate = LocationManagerDelegate(
        deliverEvent: { [weak self] params, onAccepted in
            self?.deliveryRouter.enqueue(params, onAccepted: onAccepted)
        }
    )
    private(set) lazy var nativeApi = NativeGeofenceApiImpl(
        locationManagerDelegate: locationManagerDelegate
    )
    private lazy var mainBackgroundApi = NativeGeofenceMainBackgroundApiImpl(
        runtimeHost: self
    )

    init(
        mainMessenger: FlutterBinaryMessenger,
        registerPlugins: @escaping FlutterPluginRegistrantCallback
    ) {
        self.mainMessenger = mainMessenger
        self.registerPlugins = registerPlugins
    }

    func installMainHandlers() {
        NativeGeofenceApiSetup.setUp(binaryMessenger: mainMessenger, api: nativeApi)
        NativeGeofenceBackgroundApiSetup.setUp(
            binaryMessenger: mainMessenger,
            api: mainBackgroundApi
        )
    }

    func detachMainHandlers() {
        withStateLock {
            detached = true
            mainTriggerReady = false
        }
        deliveryRouter.close()
        cancelActiveMainDelivery()
        NativeGeofenceBackgroundApiSetup.setUp(binaryMessenger: mainMessenger, api: nil)
        NativeGeofenceApiSetup.setUp(binaryMessenger: mainMessenger, api: nil)
    }

    func setMainTriggerReady(_ ready: Bool) {
        withStateLock {
            mainTriggerReady = ready
        }
        log.debug("Main-engine trigger API ready=\(ready).")
    }

    func cleanupHeadlessRuntime() {
        let sessionId = withStateLock { headlessSessionId }
        if let sessionId {
            headlessBackgroundApi?.forceCleanup(
                reason: "The native geofence runtime host was detached."
            )
            cleanupHeadlessFlutterEngine(sessionId: sessionId)
        }
    }

    private var shouldUseMainEngine: Bool {
        let ready = withStateLock { !detached && mainTriggerReady }
        return ready && UIApplication.shared.applicationState == .active
    }

    private func deliverOnMainEngine(
        _ params: GeofenceCallbackParamsWire,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard shouldUseMainEngine else { return false }
        let token = UUID()
        let watchdog = DispatchWorkItem { [weak self] in
            self?.finishMainDelivery(token: token, succeeded: false, timedOut: true)
        }
        let installed = withStateLock {
            guard activeMainDelivery == nil else { return false }
            activeMainDelivery = MainDelivery(
                token: token,
                completion: completion,
                watchdog: watchdog
            )
            return true
        }
        guard installed else { return false }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(30),
            execute: watchdog
        )
        mainTriggerApi.geofenceTriggered(params: params) { [weak self] result in
            let succeeded: Bool
            if case .success = result {
                succeeded = true
            } else {
                succeeded = false
            }
            self?.finishMainDelivery(
                token: token,
                succeeded: succeeded,
                timedOut: false
            )
        }
        NativeGeofenceDiagnostics.record(
            .enqueue,
            succeeded: true,
            outcome: "main_engine_enqueued",
            geofenceCount: params.geofences.count
        )
        return true
    }

    private func finishMainDelivery(
        token: UUID,
        succeeded: Bool,
        timedOut: Bool
    ) {
        let delivery: MainDelivery? = withStateLock {
            guard activeMainDelivery?.token == token else { return nil }
            defer { activeMainDelivery = nil }
            return activeMainDelivery
        }
        guard let delivery else {
            log.debug("Ignoring completion from an inactive main-engine delivery.")
            return
        }
        delivery.watchdog.cancel()
        NativeGeofenceDiagnostics.record(
            .worker,
            succeeded: succeeded,
            outcome: timedOut
                ? "main_callback_timeout"
                : (succeeded ? "main_callback_completed" : "main_callback_failed")
        )
        delivery.completion(succeeded)
    }

    private func cancelActiveMainDelivery() {
        let token = withStateLock { activeMainDelivery?.token }
        if let token {
            finishMainDelivery(token: token, succeeded: false, timedOut: false)
        }
    }

    private func deliverOnHeadlessEngine(
        _ params: GeofenceCallbackParamsWire,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard withStateLock({ !detached }) else { return false }
        if !Thread.isMainThread {
            var accepted = false
            DispatchQueue.main.sync {
                accepted = deliverOnHeadlessEngine(params, completion: completion)
            }
            return accepted
        }
        guard let backgroundApi = headlessBackgroundApi ?? createHeadlessFlutterEngine() else {
            NativeGeofenceDiagnostics.record(
                .enqueue,
                succeeded: false,
                outcome: "runtime_unavailable",
                geofenceCount: params.geofences.count
            )
            return false
        }
        let accepted = backgroundApi.geofenceTriggered(
            params: params,
            completion: completion
        )
        NativeGeofenceDiagnostics.record(
            .enqueue,
            succeeded: accepted,
            outcome: accepted ? "headless_enqueued" : "headless_rejected",
            geofenceCount: params.geofences.count
        )
        return accepted
    }

    private func createHeadlessFlutterEngine() -> NativeGeofenceBackgroundApiImpl? {
        guard withStateLock({ !detached }) else { return nil }
        guard let callbackDispatcherHandle = NativeGeofencePersistence.getCallbackDispatcherHandle() else {
            log.error("Callback dispatcher was not registered.")
            return nil
        }
        guard let callbackDispatcherInfo = FlutterCallbackCache.lookupCallbackInformation(
            callbackDispatcherHandle
        ) else {
            log.error("Callback dispatcher information was unavailable.")
            return nil
        }

        let sessionId = UUID()
        let engine = FlutterEngine(
            name: Constants.HEADLESS_FLUTTER_ENGINE_NAME,
            project: nil,
            allowHeadlessExecution: true
        )
        let backgroundApi = NativeGeofenceBackgroundApiImpl(
            binaryMessenger: engine.binaryMessenger,
            cleanup: { [weak self] in
                self?.cleanupHeadlessFlutterEngine(sessionId: sessionId)
            }
        )
        withStateLock {
            headlessSessionId = sessionId
            headlessFlutterEngine = engine
            headlessBackgroundApi = backgroundApi
        }
        beginCallbackBackgroundTask(sessionId: sessionId)

        let started = IosHeadlessEngineBootstrap.start(
            runEngine: {
                engine.run(
                    withEntrypoint: callbackDispatcherInfo.callbackName,
                    libraryURI: callbackDispatcherInfo.callbackLibraryPath
                )
            },
            registerPlugins: {
                registerPlugins(engine)
            },
            installHostApis: {
                // Flutter rejects binary-messenger handlers until the engine
                // is running. Install both host surfaces after callback-safe
                // plugins have registered with the running engine.
                NativeGeofenceApiSetup.setUp(
                    binaryMessenger: engine.binaryMessenger,
                    api: nativeApi
                )
                NativeGeofenceBackgroundApiSetup.setUp(
                    binaryMessenger: engine.binaryMessenger,
                    api: backgroundApi
                )
            }
        )
        guard started else {
            log.error("Failed to start the headless Flutter engine.")
            backgroundApi.forceCleanup(reason: "Failed to start the headless Flutter engine.")
            return nil
        }
        log.debug("Headless Flutter callback session started.")
        return backgroundApi
    }

    private func beginCallbackBackgroundTask(sessionId: UUID) {
        guard withStateLock({
            headlessSessionId == sessionId && callbackBackgroundTask == nil
        }) else { return }
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: callbackBackgroundTaskName
        ) { [weak self] in
            guard let self,
                  self.withStateLock({ self.headlessSessionId == sessionId })
            else { return }
            self.headlessBackgroundApi?.forceCleanup(
                reason: "iOS expired the geofence callback background task."
            )
        }
        guard identifier != .invalid else {
            log.error("Failed to begin iOS callback background task.")
            return
        }
        withStateLock {
            guard headlessSessionId == sessionId else {
                UIApplication.shared.endBackgroundTask(identifier)
                return
            }
            callbackBackgroundTask = CallbackBackgroundTask(
                sessionId: sessionId,
                identifier: identifier
            )
        }
    }

    private func cleanupHeadlessFlutterEngine(sessionId: UUID) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupHeadlessFlutterEngine(sessionId: sessionId)
            }
            return
        }
        let resources: (FlutterEngine, CallbackBackgroundTask?)? = withStateLock {
            guard headlessSessionId == sessionId,
                  let engine = headlessFlutterEngine
            else { return nil }
            let task = callbackBackgroundTask?.sessionId == sessionId
                ? callbackBackgroundTask
                : nil
            headlessBackgroundApi = nil
            headlessFlutterEngine = nil
            headlessSessionId = nil
            if task != nil {
                callbackBackgroundTask = nil
            }
            return (engine, task)
        }
        guard let (engine, task) = resources else {
            log.debug("Ignoring cleanup from an inactive headless session.")
            return
        }
        NativeGeofenceBackgroundApiSetup.setUp(
            binaryMessenger: engine.binaryMessenger,
            api: nil
        )
        NativeGeofenceApiSetup.setUp(binaryMessenger: engine.binaryMessenger, api: nil)
        engine.destroyContext()
        if let task {
            UIApplication.shared.endBackgroundTask(task.identifier)
        }
        log.debug("Headless Flutter callback session cleaned up.")
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

private final class NativeGeofenceMainBackgroundApiImpl: NativeGeofenceBackgroundApi {
    private weak var runtimeHost: IosGeofenceRuntimeHost?

    init(runtimeHost: IosGeofenceRuntimeHost) {
        self.runtimeHost = runtimeHost
    }

    func triggerApiInitialized() throws {
        runtimeHost?.setMainTriggerReady(true)
    }

    func promoteToForeground(completion: @escaping (Result<Void, Error>) -> Void) {
        NativeGeofenceDiagnostics.record(
            .foreground,
            succeeded: true,
            outcome: "ios_main_noop_promote"
        )
        completion(.success(()))
    }

    func demoteToBackground() throws {
        NativeGeofenceDiagnostics.record(
            .foreground,
            succeeded: true,
            outcome: "ios_main_noop_demote"
        )
    }
}
