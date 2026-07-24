/// Orders headless Flutter engine startup so plugins and binary-messenger
/// handlers are installed only after the engine can accept them.
enum IosHeadlessEngineBootstrap {
    static func start(
        runEngine: () -> Bool,
        registerPlugins: () -> Void,
        installHostApis: () -> Void
    ) -> Bool {
        guard runEngine() else { return false }
        registerPlugins()
        installHostApis()
        return true
    }
}
