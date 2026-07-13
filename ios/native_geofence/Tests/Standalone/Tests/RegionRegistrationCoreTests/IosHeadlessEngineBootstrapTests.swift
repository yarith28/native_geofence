import XCTest
@testable import RegionRegistrationCore

final class IosHeadlessEngineBootstrapTests: XCTestCase {
    func testRunsEngineBeforeRegisteringPluginsAndInstallingHostApis() {
        var actions: [String] = []

        let started = IosHeadlessEngineBootstrap.start(
            runEngine: {
                actions.append("runEngine")
                return true
            },
            registerPlugins: {
                actions.append("registerPlugins")
            },
            installHostApis: {
                actions.append("installHostApis")
            }
        )

        XCTAssertTrue(started)
        XCTAssertEqual(
            actions,
            ["runEngine", "registerPlugins", "installHostApis"]
        )
    }

    func testFailedEngineStartDoesNotTouchItsBinaryMessenger() {
        var actions: [String] = []

        let started = IosHeadlessEngineBootstrap.start(
            runEngine: {
                actions.append("runEngine")
                return false
            },
            registerPlugins: {
                actions.append("registerPlugins")
            },
            installHostApis: {
                actions.append("installHostApis")
            }
        )

        XCTAssertFalse(started)
        XCTAssertEqual(actions, ["runEngine"])
    }
}
