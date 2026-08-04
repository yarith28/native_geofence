import Flutter
import OSLog
import UIKit

public class NativeGeofencePlugin: NSObject, FlutterPlugin {
    private static let log = Logger(subsystem: Constants.PACKAGE_NAME, category: "NativeGeofencePlugin")
    private static let fileLog = IosNativeGeofenceFileLogger(
        category: "NativeGeofencePlugin"
    )
    
    private static var registerPlugins: FlutterPluginRegistrantCallback? = nil
    private static var instance: NativeGeofencePlugin? = nil
    
    private var runtimeHost: IosGeofenceRuntimeHost?
    private var logFileChannel: FlutterMethodChannel?
    
    init(registrar: FlutterPluginRegistrar, registerPlugins: FlutterPluginRegistrantCallback) {
        let host = IosGeofenceRuntimeHost(
            mainMessenger: registrar.messenger(),
            registerPlugins: registerPlugins
        )
        self.runtimeHost = host
        self.logFileChannel = nil

        super.init()

        host.installMainHandlers()
        installLogFileChannel(binaryMessenger: registrar.messenger())
        NativeGeofencePlugin.log.debug("NativeGeofenceApi initialized.")
        NativeGeofencePlugin.fileLog.diagnostic("NativeGeofenceApi initialized.")
    }
    
    /// Called from the Flutter plugins AppDelegate.swift.
    public static func setPluginRegistrantCallback(_ callback: FlutterPluginRegistrantCallback) {
        registerPlugins = callback
        log.debug("registerPlugins updated.")
        fileLog.diagnostic("registerPlugins updated.")
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        
        if instance != nil { return }
        
        guard let registerPlugins else {
            log.error("registerPlugins was nil at application launch.")
            fileLog.error("registerPlugins was nil at application launch.")
            fatalError("Please ensure you have updated your ios/Runner/AppDelegate to call setPluginRegistrantCallback. See the plugin documentation for more information.")
        }
        
        let plugin = NativeGeofencePlugin(registrar: registrar, registerPlugins: registerPlugins)
        registrar.addApplicationDelegate(plugin)
        instance = plugin
        
        log.debug("NativeGeofencePlugin registered.")
        fileLog.diagnostic("NativeGeofencePlugin registered.")
    }
    
    public func detachFromEngine(for registrar: any FlutterPluginRegistrar) {
        runtimeHost?.detachMainHandlers()
        runtimeHost?.cleanupHeadlessRuntime()
        runtimeHost = nil
        logFileChannel?.setMethodCallHandler(nil)
        logFileChannel = nil
        NativeGeofencePlugin.instance = nil
        NativeGeofencePlugin.log.debug("NativeGeofencePlugin detached.")
        NativeGeofencePlugin.fileLog.diagnostic("NativeGeofencePlugin detached.")
    }

    public func applicationDidBecomeActive(_ application: UIApplication) {
        runtimeHost?.resumePendingCallbackDelivery()
    }

    private func installLogFileChannel(
        binaryMessenger: FlutterBinaryMessenger
    ) {
        let channel = FlutterMethodChannel(
            name: Constants.LOG_FILE_CHANNEL_NAME,
            binaryMessenger: binaryMessenger
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "configureLogFile":
                let arguments = call.arguments as? [String: Any]
                let enabled = arguments?["enabled"] as? Bool ?? false
                let verbose = arguments?["verbose"] as? Bool
                    ?? Constants.DEFAULT_LOG_FILE_VERBOSE
                let maxBytes = (arguments?["maxBytes"] as? NSNumber)?.intValue
                    ?? Constants.DEFAULT_LOG_FILE_MAX_BYTES
                Self.performLogFileOperation(result: result) {
                    let configuredMaxBytes =
                        try IosNativeGeofenceLogFileStore.shared.configure(
                            enabled: enabled,
                            verbose: verbose,
                            maxBytes: maxBytes
                        )
                    Self.log.info(
                        "iOS native file logging configured enabled=\(enabled), verbose=\(verbose), maxBytes=\(configuredMaxBytes)."
                    )
                    Self.fileLog.info(
                        "iOS native file logging configured enabled=\(enabled), verbose=\(verbose), maxBytes=\(configuredMaxBytes)."
                    )
                    return nil
                }
            case "readLogFile":
                Self.performLogFileOperation(result: result) {
                    try IosNativeGeofenceLogFileStore.shared.read()
                }
            case "clearLogFile":
                Self.performLogFileOperation(result: result) {
                    try IosNativeGeofenceLogFileStore.shared.clear()
                    return nil
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        logFileChannel = channel
    }

    private static func performLogFileOperation(
        result: @escaping FlutterResult,
        operation: @escaping () throws -> Any?
    ) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let value = try operation()
                DispatchQueue.main.async {
                    result(value)
                }
            } catch {
                DispatchQueue.main.async {
                    result(
                        FlutterError(
                            code: "native_geofence_log_file_io_failed",
                            message: error.localizedDescription,
                            details: String(describing: error)
                        )
                    )
                }
            }
        }
    }
}
