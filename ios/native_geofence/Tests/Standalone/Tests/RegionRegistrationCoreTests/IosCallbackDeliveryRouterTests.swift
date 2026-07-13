import XCTest
@testable import RegionRegistrationCore

final class IosCallbackDeliveryRouterTests: XCTestCase {
    func testMainRouteOwnsDeliveryAndPreservesFifo() {
        var delivered: [String] = []
        var accepted: [String] = []
        var completions: [(Bool) -> Void] = []
        let router = IosCallbackDeliveryRouter<String>(
            selectRoute: { .main },
            deliver: { route, value, completion in
                XCTAssertEqual(route, .main)
                delivered.append(value)
                completions.append(completion)
                return true
            }
        )

        router.enqueue("first") { accepted.append("first") }
        router.enqueue("second") { accepted.append("second") }

        XCTAssertEqual(delivered, ["first"])
        XCTAssertEqual(accepted, ["first"])
        completions[0](true)
        XCTAssertEqual(delivered, ["first", "second"])
        XCTAssertEqual(accepted, ["first", "second"])
    }

    func testUnavailableMainRouteFallsBackToHeadless() {
        var routes: [IosCallbackDeliveryRouter<String>.Route] = []
        var didAccept = false
        let router = IosCallbackDeliveryRouter<String>(
            selectRoute: { .main },
            deliver: { route, _, _ in
                routes.append(route)
                return route == .headless
            }
        )

        router.enqueue("event") { didAccept = true }

        XCTAssertEqual(routes, [.main, .headless])
        XCTAssertTrue(didAccept)
    }

    func testRejectedDeliveryDoesNotPublishAcceptanceAndQueueContinues() {
        var delivered: [String] = []
        var accepted: [String] = []
        let router = IosCallbackDeliveryRouter<String>(
            selectRoute: { .headless },
            deliver: { _, value, completion in
                delivered.append(value)
                if value == "second" {
                    completion(true)
                    return true
                }
                return false
            }
        )

        router.enqueue("first") { accepted.append("first") }
        router.enqueue("second") { accepted.append("second") }

        XCTAssertEqual(delivered, ["first", "second"])
        XCTAssertEqual(accepted, ["second"])
    }

    func testLateCompletionCannotAdvanceNewerDelivery() {
        var delivered: [String] = []
        var completions: [(Bool) -> Void] = []
        let router = IosCallbackDeliveryRouter<String>(
            selectRoute: { .headless },
            deliver: { _, value, completion in
                delivered.append(value)
                completions.append(completion)
                return true
            }
        )

        router.enqueue("first") {}
        router.enqueue("second") {}
        router.enqueue("third") {}
        completions[0](false)
        XCTAssertEqual(delivered, ["first", "second"])
        completions[0](true)
        XCTAssertEqual(delivered, ["first", "second"])
        completions[1](true)
        XCTAssertEqual(delivered, ["first", "second", "third"])
    }

    func testCloseDropsQueuedWorkAndLateCompletionCannotRestartDelivery() {
        var delivered: [String] = []
        var accepted: [String] = []
        var completions: [(Bool) -> Void] = []
        let router = IosCallbackDeliveryRouter<String>(
            selectRoute: { .headless },
            deliver: { _, value, completion in
                delivered.append(value)
                completions.append(completion)
                return true
            }
        )

        router.enqueue("active") { accepted.append("active") }
        router.enqueue("queued") { accepted.append("queued") }
        router.close()
        completions[0](false)
        completions[0](true)

        XCTAssertEqual(delivered, ["active"])
        XCTAssertEqual(accepted, ["active"])
    }

    func testEnqueueAfterCloseIsRejected() {
        var delivered: [String] = []
        var accepted: [String] = []
        let router = IosCallbackDeliveryRouter<String>(
            selectRoute: { .headless },
            deliver: { _, value, _ in
                delivered.append(value)
                return true
            }
        )

        router.close()
        router.close()
        router.enqueue("late") { accepted.append("late") }

        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(accepted.isEmpty)
    }
}
