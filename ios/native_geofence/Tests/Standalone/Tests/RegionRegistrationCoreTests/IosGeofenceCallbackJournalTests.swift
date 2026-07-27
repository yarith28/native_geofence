import Foundation
import XCTest
@testable import RegionRegistrationCore

final class IosGeofenceCallbackJournalTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storageKey: String!

    override func setUp() {
        super.setUp()
        suiteName = "\(Constants.PACKAGE_NAME).callback-journal.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        storageKey = "journal"
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        storageKey = nil
        super.tearDown()
    }

    func testInterruptedAttemptSurvivesNewJournalAndResumesWithStableIdentity() {
        let first = makeJournal()
        let event = makeEnvelope(using: first)
        XCTAssertEqual(first.enqueue(event), .stored)
        XCTAssertEqual(first.beginAttempt(eventId: event.eventId, nowMillis: 1_000)?.attemptCount, 1)

        let restored = makeJournal()
        let waiting = restored.drainBatch(nowMillis: 1_999)
        XCTAssertTrue(waiting.due.isEmpty)
        XCTAssertEqual(waiting.nextDueAtMillis, 2_000)
        let resumed = restored.drainBatch(nowMillis: 2_000).due.single

        XCTAssertEqual(resumed.eventId, event.eventId)
        XCTAssertEqual(resumed.traceId, event.traceId)
        XCTAssertEqual(resumed.attemptCount, 1)
        XCTAssertEqual(resumed.callbackHandle, 42)
        XCTAssertEqual(resumed.callbackContext, 71)
    }

    func testLegacyEnvelopeArrayMigratesWithoutLosingPendingIdentityOrDedupCursor() {
        let journal = makeJournal()
        let legacy = makeEnvelope(
            using: journal,
            eventId: "legacy",
            eventAtMillis: 1_000
        )
        defaults.set(
            try! JSONEncoder().encode([legacy]),
            forKey: storageKey
        )

        let restored = makeJournal()
        XCTAssertEqual(
            restored.drainBatch(nowMillis: 1_000).due.map(\.eventId),
            ["legacy"]
        )
        XCTAssertEqual(
            restored.enqueue(
                makeEnvelope(
                    using: restored,
                    eventId: "legacy-duplicate",
                    eventAtMillis: 1_005
                )
            ),
            .duplicate
        )
        XCTAssertNotNil(
            restored.beginAttempt(eventId: "legacy", nowMillis: 1_000)
        )
        XCTAssertEqual(makeJournal().pendingCount(), 1)
    }

    func testDartSuccessAcknowledgesAndDeletesJournalEntry() {
        let journal = makeJournal()
        let event = makeEnvelope(using: journal)
        XCTAssertEqual(journal.enqueue(event), .stored)
        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 1_000))

        XCTAssertEqual(
            journal.complete(
                eventId: event.eventId,
                outcome: .succeeded,
                nowMillis: 1_100
            ),
            .acknowledged
        )
        XCTAssertEqual(makeJournal().pendingCount(), 0)
    }

    func testRetryableFailureRetainsJournalEntryAndSchedulesBackoff() {
        let journal = makeJournal()
        let event = makeEnvelope(using: journal)
        XCTAssertEqual(journal.enqueue(event), .stored)
        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 1_000))

        XCTAssertEqual(
            journal.complete(
                eventId: event.eventId,
                outcome: .retryableFailure,
                nowMillis: 1_100
            ),
            .retryScheduled(nextAttemptAtMillis: 2_100)
        )
        XCTAssertEqual(journal.pendingCount(), 1)
        let restored = makeJournal()
        XCTAssertTrue(restored.drainBatch(nowMillis: 2_099).due.isEmpty)
        XCTAssertEqual(
            restored.drainBatch(nowMillis: 2_100).due.map(\.eventId),
            [event.eventId]
        )
    }

    func testProvenInvalidCallbacksAreTerminalAndDeleted() {
        let journal = makeJournal()
        let failures: [
            (String, IosGeofenceCallbackDeliveryOutcome.TerminalFailure)
        ] = [
            ("missing", .callbackNotFound),
            ("invalid", .callbackInvalid),
        ]

        for (eventId, failure) in failures {
            let event = makeEnvelope(using: journal, eventId: eventId)
            XCTAssertEqual(journal.enqueue(event), .stored)
            XCTAssertNotNil(
                journal.beginAttempt(eventId: event.eventId, nowMillis: 1_000)
            )

            XCTAssertEqual(
                journal.complete(
                    eventId: event.eventId,
                    outcome: .terminalFailure(failure),
                    nowMillis: 1_100
                ),
                .terminallyDiscarded(failure)
            )
            XCTAssertEqual(journal.pendingCount(), 0)
        }
    }

    func testTerminalClassificationRequiresOwnedMarkerAndMatchingCode() {
        typealias TerminalFailure =
            IosGeofenceCallbackDeliveryOutcome.TerminalFailure
        let marker = Constants.CALLBACK_LOOKUP_TERMINAL_ERROR_MARKER
        XCTAssertEqual(
            marker,
            "com.chunkytofustudios.native_geofence.callback_lookup_terminal.v1"
        )

        XCTAssertEqual(
            TerminalFailure.classify(
                errorCode: "8",
                details: marker,
                callbackNotFoundCode: "8",
                callbackInvalidCode: "9"
            ),
            .callbackNotFound
        )
        XCTAssertEqual(
            TerminalFailure.classify(
                errorCode: "9",
                details: marker,
                callbackNotFoundCode: "8",
                callbackInvalidCode: "9"
            ),
            .callbackInvalid
        )
        XCTAssertNil(
            TerminalFailure.classify(
                errorCode: "8",
                details: nil,
                callbackNotFoundCode: "8",
                callbackInvalidCode: "9"
            )
        )
        XCTAssertNil(
            TerminalFailure.classify(
                errorCode: "9",
                details: "application-owned-error",
                callbackNotFoundCode: "8",
                callbackInvalidCode: "9"
            )
        )
        XCTAssertNil(
            TerminalFailure.classify(
                errorCode: "application-error",
                details: marker,
                callbackNotFoundCode: "8",
                callbackInvalidCode: "9"
            )
        )
    }

    func testControlledRetryableFailuresReachTerminalDisposition() {
        let journal = makeJournal(maximumAttempts: 2)
        let event = makeEnvelope(using: journal)
        XCTAssertEqual(journal.enqueue(event), .stored)

        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 1_000))
        XCTAssertEqual(
            journal.complete(
                eventId: event.eventId,
                outcome: .retryableFailure,
                nowMillis: 1_100
            ),
            .retryScheduled(nextAttemptAtMillis: 2_100)
        )
        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 2_100))
        XCTAssertEqual(
            journal.complete(
                eventId: event.eventId,
                outcome: .retryableFailure,
                nowMillis: 2_200
            ),
            .retryExhausted
        )
        XCTAssertEqual(journal.pendingCount(), 0)
    }

    func testPendingSameDirectionBurstIsDurablyDeduplicated() {
        let journal = makeJournal()
        let first = makeEnvelope(using: journal, eventId: "first", eventAtMillis: 1_000)
        let duplicate = makeEnvelope(using: journal, eventId: "duplicate", eventAtMillis: 1_005)

        XCTAssertEqual(journal.enqueue(first), .stored)
        XCTAssertEqual(journal.enqueue(duplicate), .duplicate)
        XCTAssertEqual(journal.pendingCount(), 1)
    }

    func testAlternatingPendingTransitionsBreakSameDirectionDeduplication() {
        let journal = makeJournal()
        let firstEnter = makeEnvelope(
            using: journal,
            eventId: "enter-1",
            eventAtMillis: 1_000,
            transition: .enter
        )
        let exit = makeEnvelope(
            using: journal,
            eventId: "exit",
            eventAtMillis: 1_001,
            transition: .exit
        )
        let secondEnter = makeEnvelope(
            using: journal,
            eventId: "enter-2",
            eventAtMillis: 1_002,
            transition: .enter
        )

        XCTAssertEqual(journal.enqueue(firstEnter), .stored)
        XCTAssertEqual(journal.enqueue(exit), .stored)
        XCTAssertEqual(journal.enqueue(secondEnter), .stored)
        XCTAssertEqual(
            journal.drainBatch(nowMillis: 1_002).due.map(\.eventId),
            ["enter-1", "exit", "enter-2"]
        )
    }

    func testCompletedOppositeTransitionStillBreaksPendingSameDirectionDeduplication() {
        let journal = makeJournal()
        let firstEnter = makeEnvelope(
            using: journal,
            eventId: "enter-1",
            eventAtMillis: 1_000,
            transition: .enter
        )
        let exit = makeEnvelope(
            using: journal,
            eventId: "exit",
            eventAtMillis: 1_001,
            transition: .exit
        )
        let secondEnter = makeEnvelope(
            using: journal,
            eventId: "enter-2",
            eventAtMillis: 1_002,
            transition: .enter
        )

        XCTAssertEqual(journal.enqueue(firstEnter), .stored)
        XCTAssertEqual(journal.enqueue(exit), .stored)
        XCTAssertEqual(
            journal.complete(
                eventId: exit.eventId,
                outcome: .succeeded,
                nowMillis: 1_002
            ),
            .acknowledged
        )

        XCTAssertEqual(journal.enqueue(secondEnter), .stored)
        XCTAssertEqual(
            journal.drainBatch(nowMillis: 1_002).due.map(\.eventId),
            ["enter-1", "enter-2"]
        )
    }

    func testAlternatingDeferredEventsOverrideAnOlderCompletedBaseline() {
        let journal = makeJournal()
        let completedEnter = makeEnvelope(
            using: journal,
            eventId: "completed-enter",
            eventAtMillis: 1_000,
            transition: .enter
        )
        XCTAssertEqual(journal.enqueue(completedEnter), .stored)
        XCTAssertEqual(
            journal.complete(
                eventId: completedEnter.eventId,
                outcome: .succeeded,
                nowMillis: 1_001
            ),
            .acknowledged
        )

        let deferredExit = makeEnvelope(
            using: journal,
            eventId: "deferred-exit",
            eventAtMillis: 1_002,
            transition: .exit
        )
        let deferredEnter = makeEnvelope(
            using: journal,
            eventId: "deferred-enter",
            eventAtMillis: 1_003,
            transition: .enter
        )

        XCTAssertEqual(journal.enqueue(deferredExit), .stored)
        XCTAssertEqual(journal.enqueue(deferredEnter), .stored)
        XCTAssertEqual(
            journal.drainBatch(nowMillis: 1_003).due.map(\.eventId),
            ["deferred-exit", "deferred-enter"]
        )
    }

    func testChangedRegistrationIsNotDeduplicatedAgainstPendingOldGeneration() {
        let journal = makeJournal()
        let previous = makeEnvelope(
            using: journal,
            eventId: "previous",
            eventAtMillis: 1_000
        )
        XCTAssertEqual(journal.enqueue(previous), .stored)

        let changedHandle = makeEnvelope(
            using: journal,
            eventId: "changed-handle",
            eventAtMillis: 1_001,
            callbackHandle: 43
        )
        XCTAssertEqual(journal.enqueue(changedHandle), .stored)

        let changedContext = makeEnvelope(
            using: journal,
            eventId: "changed-context",
            eventAtMillis: 1_002,
            callbackHandle: 43,
            callbackContext: 72
        )
        XCTAssertEqual(journal.enqueue(changedContext), .stored)

        let changedGeometryAndTriggers = makeEnvelope(
            using: journal,
            eventId: "changed-region",
            eventAtMillis: 1_003,
            latitude: 12.5,
            triggers: [.enter],
            callbackHandle: 43,
            callbackContext: 72
        )
        XCTAssertEqual(
            journal.enqueue(changedGeometryAndTriggers),
            .stored
        )
        XCTAssertEqual(journal.pendingCount(), 4)
    }

    func testDeduplicationResetPreservesPendingEnvelopeAndStartsNewGeneration() {
        let journal = makeJournal()
        let previousGeneration = makeEnvelope(
            using: journal,
            eventId: "previous-generation",
            eventAtMillis: 1_000
        )
        let recreatedGeneration = makeEnvelope(
            using: journal,
            eventId: "recreated-generation",
            eventAtMillis: 1_001
        )

        XCTAssertEqual(journal.enqueue(previousGeneration), .stored)
        XCTAssertTrue(journal.resetDeduplication(identifier: "office"))
        XCTAssertEqual(journal.enqueue(recreatedGeneration), .stored)
        XCTAssertEqual(
            journal.drainBatch(nowMillis: 1_001).due.map(\.eventId),
            ["previous-generation", "recreated-generation"]
        )
    }

    func testEqualTimestampReplayPreservesInsertionFifo() {
        let journal = makeJournal()
        for eventId in ["z-first", "a-second", "m-third"] {
            XCTAssertEqual(
                journal.enqueue(
                    makeEnvelope(
                        using: journal,
                        eventId: eventId,
                        eventAtMillis: 1_000,
                        transition: eventId == "a-second" ? .exit : .enter
                    )
                ),
                .stored
            )
        }

        XCTAssertEqual(
            journal.drainBatch(nowMillis: 1_000).due.map(\.eventId),
            ["z-first", "a-second", "m-third"]
        )
    }

    func testClockRollbackDoesNotReorderInsertionFifo() {
        let journal = makeJournal()
        let events = [
            makeEnvelope(
                using: journal,
                eventId: "first",
                eventAtMillis: 1_000,
                transition: .enter
            ),
            makeEnvelope(
                using: journal,
                eventId: "second",
                eventAtMillis: 900,
                transition: .exit
            ),
            makeEnvelope(
                using: journal,
                eventId: "third",
                eventAtMillis: 800,
                transition: .enter
            ),
        ]
        for event in events {
            XCTAssertEqual(journal.enqueue(event), .stored)
        }

        XCTAssertEqual(
            journal.drainBatch(nowMillis: 1_000).due.map(\.eventId),
            ["first", "second", "third"]
        )
    }

    func testRepeatedInterruptedAttemptsReachTerminalDisposition() {
        let journal = makeJournal(maximumAttempts: 2)
        let event = makeEnvelope(using: journal)
        XCTAssertEqual(journal.enqueue(event), .stored)

        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 1_000))
        XCTAssertTrue(journal.drainBatch(nowMillis: 1_999).due.isEmpty)
        XCTAssertEqual(journal.drainBatch(nowMillis: 2_000).due.map(\.eventId), [event.eventId])
        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 2_000))
        XCTAssertEqual(
            journal.drainBatch(nowMillis: 3_000).terminallyDiscardedEventIds,
            [event.eventId]
        )
        XCTAssertEqual(journal.pendingCount(), 0)
    }

    func testExpiredAndCorruptJournalsFailSafely() {
        let journal = makeJournal(timeToLiveMillis: 100)
        let event = makeEnvelope(using: journal)
        XCTAssertEqual(journal.enqueue(event), .stored)

        let expired = journal.drainBatch(nowMillis: 1_100)
        XCTAssertEqual(expired.terminallyDiscardedEventIds, [event.eventId])
        XCTAssertEqual(journal.pendingCount(), 0)

        defaults.set(Data("not-json".utf8), forKey: storageKey)
        XCTAssertFalse(journal.drainBatch(nowMillis: 2_000).storageReadable)
        XCTAssertEqual(journal.enqueue(event), .storageFailure)
        XCTAssertEqual(defaults.data(forKey: storageKey), Data("not-json".utf8))
    }

    private func makeJournal(
        timeToLiveMillis: Int64 = 10_000,
        maximumAttempts: Int = 8
    ) -> IosGeofenceCallbackJournal {
        IosGeofenceCallbackJournal(
            userDefaults: defaults,
            storageKey: storageKey,
            eventTimeToLiveMillis: timeToLiveMillis,
            pendingDuplicateWindowMillis: 10,
            maximumAttempts: maximumAttempts,
            retryDelaysMillis: [1_000]
        )
    }

    private func makeEnvelope(
        using journal: IosGeofenceCallbackJournal,
        eventId: String = "event-1",
        eventAtMillis: Int64 = 1_000,
        transition: IosGeofenceTransition = .enter,
        latitude: Double = 11.5,
        triggers: [IosGeofenceTransition] = [.enter, .exit],
        callbackHandle: Int64 = 42,
        callbackContext: Int64? = 71
    ) -> IosGeofenceCallbackJournalEnvelope {
        journal.makeEnvelope(
            eventId: eventId,
            traceId: "trace-1",
            geofence: .init(
                id: "office",
                latitude: latitude,
                longitude: 104.9,
                radiusMeters: 100,
                triggers: triggers
            ),
            transition: transition,
            eventAtMillis: eventAtMillis,
            callbackHandle: callbackHandle,
            callbackContext: callbackContext,
            nowMillis: 1_000
        )
    }
}

private extension Array {
    var single: Element {
        XCTAssertEqual(count, 1)
        return self[0]
    }
}
