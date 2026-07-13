import XCTest
@testable import RegionRegistrationCore

private final class ManualScheduler {
    struct Job {
        let delayMillis: Int
        let work: () -> Void
    }

    private(set) var jobs: [Job] = []
    var onSchedule: ((Int) -> Void)?

    func schedule(delayMillis: Int, work: @escaping () -> Void) {
        jobs.append(Job(delayMillis: delayMillis, work: work))
        onSchedule?(delayMillis)
    }
}

final class SerialCallbackSessionTests: XCTestCase {
    func testPreReadyEventsDispatchFifoOneAtATime() {
        let harness = Harness()

        XCTAssertTrue(harness.subject.enqueue(1))
        XCTAssertTrue(harness.subject.enqueue(2))
        XCTAssertTrue(harness.sent.isEmpty)

        harness.markReady()
        XCTAssertEqual(harness.sent, [1])

        harness.complete(0)
        XCTAssertEqual(harness.sent, [1, 2])
        harness.complete(1)
    }

    func testNewWorkInvalidatesAStaleIdleTimer() {
        let harness = Harness()
        harness.markReady()
        XCTAssertTrue(harness.subject.enqueue(1))
        harness.complete(0)
        let staleIdle = harness.scheduler.jobs.last { $0.delayMillis == 2_000 }!

        XCTAssertTrue(harness.subject.enqueue(2))
        staleIdle.work()

        XCTAssertTrue(harness.closes.isEmpty)
        XCTAssertEqual(harness.sent, [1, 2])
    }

    func testReadinessInvalidatesAStaleStartupTimer() {
        let harness = Harness()
        XCTAssertTrue(harness.subject.enqueue(1))
        let staleStartup = harness.scheduler.jobs.last { $0.delayMillis == 30_000 }!

        harness.markReady()
        staleStartup.work()

        XCTAssertTrue(harness.closes.isEmpty)
        XCTAssertEqual(harness.sent, [1])
    }

    func testPreviousCallbackTimerCannotCloseTheNextDispatch() {
        let harness = Harness()
        harness.markReady()
        XCTAssertTrue(harness.subject.enqueue(1))
        let staleFirstTimeout = harness.scheduler.jobs.last { $0.delayMillis == 30_000 }!
        XCTAssertTrue(harness.subject.enqueue(2))

        harness.complete(0)
        staleFirstTimeout.work()

        XCTAssertTrue(harness.closes.isEmpty)
        XCTAssertEqual(harness.sent, [1, 2])
    }

    func testActiveStartupTimeoutClosesOnceAndRejectsLaterWork() {
        let harness = Harness()
        XCTAssertTrue(harness.subject.enqueue(1))
        let startupTimeout = harness.scheduler.jobs.last { $0.delayMillis == 30_000 }!

        startupTimeout.work()
        startupTimeout.work()

        XCTAssertEqual(harness.closes, [.startupTimeout("1")])
        XCTAssertFalse(harness.subject.enqueue(2))
    }

    func testActiveCallbackTimeoutClosesOnceAndIgnoresLateCompletion() {
        let harness = Harness()
        harness.markReady()
        XCTAssertTrue(harness.subject.enqueue(1))
        let callbackTimeout = harness.scheduler.jobs.last { $0.delayMillis == 30_000 }!

        callbackTimeout.work()
        harness.complete(0)
        callbackTimeout.work()

        XCTAssertEqual(harness.closes, [.callbackTimeout("1")])
        XCTAssertFalse(harness.subject.enqueue(2))
    }

    func testSynchronousSenderCompletionDoesNotDeadlockOrReorder() {
        let scheduler = ManualScheduler()
        var sent: [Int] = []
        var closes: [SerialCallbackSession<Int>.CloseReason] = []
        let subject = makeSubject(
            scheduler: scheduler,
            closes: { closes.append($0) }
        )
        subject.markReady { element, completion in
            sent.append(element)
            _ = completion()
        }

        XCTAssertTrue(subject.enqueue(1))
        XCTAssertTrue(subject.enqueue(2))

        XCTAssertEqual(sent, [1, 2])
        XCTAssertTrue(closes.isEmpty)
    }

    func testCloseWhileInstallingCallbackTimerPreventsSenderInvocation() {
        let harness = Harness()
        harness.markReady()
        harness.scheduler.onSchedule = { [weak harness] delayMillis in
            guard delayMillis == 30_000 else { return }
            harness?.subject.forceClose(reason: "expired")
        }

        XCTAssertTrue(harness.subject.enqueue(1))

        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertEqual(harness.closes, [.forced("expired")])
    }

    func testDuplicateCompletionCannotAdvanceTheQueueTwice() {
        let harness = Harness()
        harness.markReady()
        XCTAssertTrue(harness.subject.enqueue(1))
        XCTAssertTrue(harness.subject.enqueue(2))
        let firstCompletion = harness.completions[0]

        XCTAssertTrue(firstCompletion())
        XCTAssertFalse(firstCompletion())

        XCTAssertEqual(harness.sent, [1, 2])
        XCTAssertEqual(harness.completions.count, 2)
    }

    func testForceCloseExecutesCleanupExactlyOnce() {
        let harness = Harness()

        harness.subject.forceClose(reason: "expired")
        harness.subject.forceClose(reason: "again")

        XCTAssertEqual(harness.closes, [.forced("expired")])
        XCTAssertFalse(harness.subject.enqueue(1))
    }

    func testCurrentIdleTimerClosesExactlyOnce() {
        let harness = Harness()
        harness.markReady()
        let idleTimer = harness.scheduler.jobs.last { $0.delayMillis == 2_000 }!

        idleTimer.work()
        idleTimer.work()

        XCTAssertEqual(harness.closes, [.idle])
    }

    private func makeSubject(
        scheduler: ManualScheduler,
        closes: @escaping (SerialCallbackSession<Int>.CloseReason) -> Void
    ) -> SerialCallbackSession<Int> {
        SerialCallbackSession(
            startupTimeoutMillis: 30_000,
            callbackTimeoutMillis: 30_000,
            idleGraceMillis: 2_000,
            describe: String.init,
            schedule: scheduler.schedule,
            onClose: closes
        )
    }

    private final class Harness {
        let scheduler = ManualScheduler()
        private(set) var sent: [Int] = []
        private(set) var completions: [() -> Bool] = []
        private(set) var closes: [SerialCallbackSession<Int>.CloseReason] = []
        lazy var subject = SerialCallbackSession<Int>(
            startupTimeoutMillis: 30_000,
            callbackTimeoutMillis: 30_000,
            idleGraceMillis: 2_000,
            describe: String.init,
            schedule: scheduler.schedule,
            onClose: { [weak self] in self?.closes.append($0) }
        )

        func markReady() {
            subject.markReady { [weak self] element, completion in
                self?.sent.append(element)
                self?.completions.append(completion)
            }
        }

        func complete(_ index: Int) {
            _ = completions[index]()
        }
    }
}
