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

    func testDartSuccessAcknowledgesAndDeletesJournalEntry() {
        let journal = makeJournal()
        let event = makeEnvelope(using: journal)
        XCTAssertEqual(journal.enqueue(event), .stored)
        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 1_000))

        XCTAssertEqual(
            journal.complete(eventId: event.eventId, succeeded: true, nowMillis: 1_100),
            .acknowledged
        )
        XCTAssertEqual(makeJournal().pendingCount(), 0)
    }

    func testExplicitDartFailureDeletesJournalEntryWithoutRetry() {
        let journal = makeJournal()
        let event = makeEnvelope(using: journal)
        XCTAssertEqual(journal.enqueue(event), .stored)
        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 1_000))

        XCTAssertEqual(
            journal.complete(eventId: event.eventId, succeeded: false, nowMillis: 1_100),
            .failedWithoutRetry
        )
        XCTAssertEqual(journal.pendingCount(), 0)
        let later = journal.drainBatch(nowMillis: 10_000)
        XCTAssertTrue(later.due.isEmpty)
        XCTAssertNil(later.nextDueAtMillis)
    }

    func testPendingSameDirectionBurstIsDurablyDeduplicated() {
        let journal = makeJournal()
        let first = makeEnvelope(using: journal, eventId: "first", eventAtMillis: 1_000)
        let duplicate = makeEnvelope(using: journal, eventId: "duplicate", eventAtMillis: 1_005)

        XCTAssertEqual(journal.enqueue(first), .stored)
        XCTAssertEqual(journal.enqueue(duplicate), .duplicate)
        XCTAssertEqual(journal.pendingCount(), 1)
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
        eventAtMillis: Int64 = 1_000
    ) -> IosGeofenceCallbackJournalEnvelope {
        journal.makeEnvelope(
            eventId: eventId,
            traceId: "trace-1",
            geofence: .init(
                id: "office",
                latitude: 11.5,
                longitude: 104.9,
                radiusMeters: 100,
                triggers: [.enter, .exit]
            ),
            transition: .enter,
            eventAtMillis: eventAtMillis,
            callbackHandle: 42,
            callbackContext: 71,
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
