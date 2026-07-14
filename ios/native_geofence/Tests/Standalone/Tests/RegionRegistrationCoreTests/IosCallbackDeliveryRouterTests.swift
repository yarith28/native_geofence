import XCTest
@testable import RegionRegistrationCore

final class IosCallbackDeliveryRouterTests: XCTestCase {
    func testReattachableDeliveryRoutesEventsToReplacementAttachment() {
        let subject = IosReattachableDelivery<(String) -> Void>()
        var deliveries: [String] = []

        subject.attach { deliveries.append("old:\($0)") }
        XCTAssertNotNil(subject.withCurrent { $0("first") })

        subject.attach { deliveries.append("new:\($0)") }
        XCTAssertNotNil(subject.withCurrent { $0("second") })

        XCTAssertEqual(deliveries, ["old:first", "new:second"])
    }

    func testStaleDetachCannotClearReplacementDelivery() {
        let subject = IosReattachableDelivery<(String) -> Void>()
        var deliveries: [String] = []
        let oldAttachment = subject.attach { deliveries.append("old:\($0)") }
        let newAttachment = subject.attach { deliveries.append("new:\($0)") }

        subject.detach(oldAttachment)
        XCTAssertNotNil(subject.withCurrent { $0("event") })
        subject.detach(newAttachment)

        XCTAssertEqual(deliveries, ["new:event"])
        XCTAssertNil(subject.withCurrent { $0("unavailable") })
    }

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
        var rejected: [String] = []
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

        router.enqueue(
            "first",
            onAccepted: { accepted.append("first") },
            onRejected: { rejected.append("first") }
        )
        router.enqueue(
            "second",
            onAccepted: { accepted.append("second") },
            onRejected: { rejected.append("second") }
        )

        XCTAssertEqual(delivered, ["first", "second"])
        XCTAssertEqual(accepted, ["second"])
        XCTAssertEqual(rejected, ["first"])
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

    func testSynchronousCompletionPublishesAcceptanceBeforeAdvancingFifo() {
        var events: [String] = []
        var blockerCompletion: ((Bool) -> Void)?
        let router = IosCallbackDeliveryRouter<String>(
            selectRoute: { .headless },
            deliver: { _, value, completion in
                events.append("deliver:\(value)")
                if value == "blocker" {
                    blockerCompletion = completion
                } else {
                    completion(true)
                }
                return true
            }
        )

        router.enqueue("blocker") { events.append("accepted:blocker") }
        router.enqueue("first") { events.append("accepted:first") }
        router.enqueue("second") { events.append("accepted:second") }
        blockerCompletion?(true)

        XCTAssertEqual(
            events,
            [
                "deliver:blocker",
                "accepted:blocker",
                "deliver:first",
                "accepted:first",
                "deliver:second",
                "accepted:second",
            ]
        )
    }

    func testCloseDropsQueuedWorkAndLateCompletionCannotRestartDelivery() {
        var delivered: [String] = []
        var accepted: [String] = []
        var rejected: [String] = []
        var completions: [(Bool) -> Void] = []
        let router = IosCallbackDeliveryRouter<String>(
            selectRoute: { .headless },
            deliver: { _, value, completion in
                delivered.append(value)
                completions.append(completion)
                return true
            }
        )

        router.enqueue(
            "active",
            onAccepted: { accepted.append("active") },
            onRejected: { rejected.append("active") }
        )
        router.enqueue(
            "queued",
            onAccepted: { accepted.append("queued") },
            onRejected: { rejected.append("queued") }
        )
        router.close()
        completions[0](false)
        completions[0](true)

        XCTAssertEqual(delivered, ["active"])
        XCTAssertEqual(accepted, ["active"])
        XCTAssertEqual(rejected, ["queued"])
    }

    func testQueuedDedupReservationBlocksBurstAndCommitsOnAcceptance() {
        let suiteName = "\(Constants.PACKAGE_NAME).router-dedup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deduplicator = IosGeofenceEventDeduplicator(userDefaults: defaults)
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

        router.enqueue("blocker") {}
        let first = deduplicator.admission(
            id: "office",
            transition: .enter,
            eventAtMillis: 1_000
        )
        let duplicate = deduplicator.admission(
            id: "office",
            transition: .enter,
            eventAtMillis: 1_001
        )
        var suppressedAges: [Int64] = []
        router.enqueue(
            "geofence",
            shouldAttempt: {
                guard case .admitted = first.attempt() else { return false }
                return true
            },
            onAccepted: { first.commit() },
            onRejected: { first.cancel() }
        )
        router.enqueue(
            "duplicate",
            shouldAttempt: {
                switch duplicate.attempt() {
                case .admitted:
                    return true
                case .suppressed(let ageMillis):
                    suppressedAges.append(ageMillis)
                    return false
                case .unavailable:
                    return false
                }
            },
            onAccepted: { duplicate.commit() },
            onRejected: { duplicate.cancel() }
        )
        XCTAssertEqual(delivered, ["blocker"])

        completions[0](true)
        XCTAssertEqual(delivered, ["blocker", "geofence"])
        completions[1](true)

        XCTAssertEqual(delivered, ["blocker", "geofence"])
        XCTAssertEqual(suppressedAges, [1])
        XCTAssertEqual(
            deduplicator.suppressedAgeMillis(
                id: "office",
                transition: .enter,
                eventAtMillis: 1_002
            ),
            2
        )
    }

    func testRejectedQueuedCandidateReleasesDedupForNextEvent() {
        let suiteName = "\(Constants.PACKAGE_NAME).router-retry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deduplicator = IosGeofenceEventDeduplicator(userDefaults: defaults)
        var delivered: [String] = []
        var completions: [(Bool) -> Void] = []
        let router = IosCallbackDeliveryRouter<String>(
            selectRoute: { .headless },
            deliver: { _, value, completion in
                delivered.append(value)
                if value == "first" {
                    return false
                }
                completions.append(completion)
                return true
            }
        )
        let first = deduplicator.admission(
            id: "office",
            transition: .enter,
            eventAtMillis: 1_000
        )
        let retry = deduplicator.admission(
            id: "office",
            transition: .enter,
            eventAtMillis: 1_001
        )

        router.enqueue("blocker") {}
        router.enqueue(
            "first",
            shouldAttempt: {
                guard case .admitted = first.attempt() else { return false }
                return true
            },
            onAccepted: { first.commit() },
            onRejected: { first.cancel() }
        )
        router.enqueue(
            "retry",
            shouldAttempt: {
                guard case .admitted = retry.attempt() else { return false }
                return true
            },
            onAccepted: { retry.commit() },
            onRejected: { retry.cancel() }
        )

        completions[0](true)

        XCTAssertEqual(delivered, ["blocker", "first", "retry"])
        XCTAssertEqual(
            deduplicator.suppressedAgeMillis(
                id: "office",
                transition: .enter,
                eventAtMillis: 1_002
            ),
            1
        )
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
