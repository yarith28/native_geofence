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
