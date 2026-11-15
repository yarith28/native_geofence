import Foundation
import XCTest
@testable import RegionRegistrationCore

final class IosGeofenceCallbackJournalTests: XCTestCase {
    private var suiteName: String!
    private var defaults: JournalTestUserDefaults!
    private var storageKey: String!

    override func setUp() {
        super.setUp()
        suiteName = "\(Constants.PACKAGE_NAME).callback-journal.\(UUID().uuidString)"
        defaults = JournalTestUserDefaults(suiteName: suiteName)
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
        for scoped in [false, true] {
            defaults.removePersistentDomain(forName: suiteName)
            let journal = makeJournal()
            let event = makeEnvelope(using: journal)
            if scoped {
                let registration = IosGeofenceCallbackJournal.RecoveryRegistration(
                    geofence: event.geofence, scope: "owner", callbackHandle: 42, callbackContext: 71)
                XCTAssertTrue(journal.reconcileRecovery(registrations: [registration], managedIds: ["office"], authoritative: true, nowMillis: 1_000))
            }
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
            // Ordinary backoff must not delay a later transition, including on a
            // registration that opted into callback-lookup recovery.
            XCTAssertEqual(restored.enqueue(makeEnvelope(using: restored, eventId: "exit", eventAtMillis: 1_150, transition: .exit)), .stored)
            let duringBackoff = restored.drainBatch(nowMillis: 1_150)
            XCTAssertEqual(duringBackoff.due.map(\.eventId), ["exit"])
            XCTAssertEqual(duringBackoff.nextDueAtMillis, 2_100)
            XCTAssertEqual(restored.complete(eventId: "exit", outcome: .succeeded, nowMillis: 1_151), .acknowledged)
            XCTAssertEqual(
                restored.drainBatch(nowMillis: 2_100).due.map(\.eventId),
                [event.eventId]
            )
        }
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
        // Untouched legacy registrations do not depend on recovery storage.
        XCTAssertTrue(journal.cancelRecovery(identifier: "office"))
        XCTAssertTrue(journal.cancelRecovery(identifier: nil))
        for authoritative in [false, true] {
            XCTAssertTrue(journal.reconcileRecovery(registrations: [], managedIds: ["office"], authoritative: authoritative, nowMillis: 2_000))
        }
        XCTAssertEqual(defaults.data(forKey: storageKey), Data("not-json".utf8))

        // Stop must revoke recovery even when the main journal cannot be read
        // or rewritten. Preserve legacy events and apply the cancellation
        // before delivery resumes, including after a process restart.
        for identifier: String? in ["office", nil] {
            for corrupt in [true, false] {
                defaults.removePersistentDomain(forName: suiteName)
                let journal = makeJournal()
                let legacy = makeEnvelope(using: journal, eventId: "legacy")
                XCTAssertEqual(journal.enqueue(legacy), .stored)
                XCTAssertEqual(journal.enqueue(makeEnvelope(using: journal, eventId: "legacy-only", geofenceId: "legacy-only")), .stored)
                let registration = IosGeofenceCallbackJournal.RecoveryRegistration(
                    geofence: legacy.geofence, scope: "owner-a", callbackHandle: 42, callbackContext: 71)
                let other = makeEnvelope(using: journal, eventId: "other", geofenceId: "other")
                let otherRegistration = IosGeofenceCallbackJournal.RecoveryRegistration(
                    geofence: other.geofence, scope: "owner-b", callbackHandle: 42, callbackContext: 71)
                XCTAssertTrue(journal.reconcileRecovery(registrations: [registration, otherRegistration], managedIds: ["office", "other"], authoritative: true, nowMillis: 1_000))
                XCTAssertEqual(journal.enqueue(makeEnvelope(using: journal, eventId: "scoped")), .stored)
                XCTAssertEqual(journal.enqueue(other), .stored)
                let saved = defaults.data(forKey: storageKey)
                if corrupt {
                    defaults.set(Data("not-json".utf8), forKey: storageKey)
                } else {
                    defaults.rejectedKeys = [storageKey]
                }
                XCTAssertTrue(journal.cancelRecovery(identifier: "never-enabled"))
                XCTAssertTrue(journal.reconcileRecovery(registrations: [], managedIds: ["never-enabled"], authoritative: false, nowMillis: 1_000))
                XCTAssertFalse(journal.reconcileRecovery(registrations: [], managedIds: ["office"], authoritative: true, nowMillis: 1_000))
                XCTAssertFalse(journal.cancelRecovery(identifier: identifier))
                defaults.rejectedKeys = []
                defaults.set(saved, forKey: storageKey)
                // Direct create/replacement still aborts on cleanup failure;
                // it must not revoke the old registration in that case.
                XCTAssertEqual(makeJournal().pendingCount(), 4)
                XCTAssertEqual(makeJournal().recoveryOrigin(identifier: "office").scope, "owner-a")
                if corrupt {
                    defaults.set(Data("not-json".utf8), forKey: storageKey)
                } else {
                    defaults.rejectedKeys = [storageKey]
                }
                XCTAssertFalse(journal.cancelRecovery(identifier: identifier, deferCleanupOnFailure: true))
                XCTAssertFalse(journal.drainBatch(nowMillis: 1_001).storageReadable)
                let restored = makeJournal()
                XCTAssertFalse(restored.drainBatch(nowMillis: 1_001).storageReadable)

                defaults.rejectedKeys = []
                defaults.set(saved, forKey: storageKey)
                let retained = identifier == nil ? ["legacy", "legacy-only"] : ["legacy", "legacy-only", "other"]
                XCTAssertEqual(restored.drainBatch(nowMillis: 1_001).due.map(\.eventId), retained)
                XCTAssertNil(restored.recoveryOrigin(identifier: "office").scope)
                XCTAssertEqual(restored.recoveryOrigin(identifier: "other").scope, identifier == nil ? nil : "owner-b")
                XCTAssertEqual(makeJournal().pendingCount(), retained.count)
                XCTAssertEqual(restored.enqueue(makeEnvelope(using: restored, eventId: "legacy-duplicate", geofenceId: "legacy-only", eventAtMillis: 1_002)), .duplicate)
                if identifier != nil {
                    XCTAssertEqual(restored.enqueue(makeEnvelope(using: restored, eventId: "other-duplicate", geofenceId: "other", eventAtMillis: 1_002)), .duplicate)
                }

                // Successful cleanup releases the marker for a later start.
                XCTAssertTrue(restored.reconcileRecovery(registrations: [registration], managedIds: ["office"], authoritative: false, nowMillis: 1_002))
                XCTAssertEqual(restored.enqueue(makeEnvelope(using: restored, eventId: "new", eventAtMillis: 1_002)), .stored)
                XCTAssertEqual(makeJournal().drainBatch(nowMillis: 1_002).due.map(\.eventId), retained + ["new"])
            }
        }
    }

    func testRecoveryWaitsAcrossRestartThenRebindsBothHandlesWithoutChangingEvidence() {
        let journal = makeJournal()
        let event = makeEnvelope(using: journal)
        let registration = IosGeofenceCallbackJournal.RecoveryRegistration(
            geofence: event.geofence, scope: "owner-a", callbackHandle: 42, callbackContext: 71)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [registration], managedIds: ["office"], authoritative: true, nowMillis: 1_000))
        XCTAssertEqual(journal.enqueue(event), .stored)
        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 1_000))
        XCTAssertEqual(journal.complete(eventId: event.eventId, outcome: .terminalFailure(.callbackNotFound), nowMillis: 1_001), .awaitingCallbackRefresh)
        let restored = makeJournal()
        XCTAssertEqual(restored.pendingCount(), 1)
        XCTAssertTrue(restored.drainBatch(nowMillis: 5_000).due.isEmpty)
        XCTAssertNil(restored.beginAttempt(eventId: event.eventId, nowMillis: 5_000))
        let fresh = IosGeofenceCallbackJournal.RecoveryRegistration(
            geofence: event.geofence, scope: "owner-a", callbackHandle: 100, callbackContext: 200)
        XCTAssertTrue(restored.reconcileRecovery(registrations: [fresh], managedIds: ["office"], authoritative: true, nowMillis: 5_000))
        let replay = restored.drainBatch(nowMillis: 5_000).due.single
        XCTAssertEqual(replay.callbackHandle, 100)
        XCTAssertEqual(replay.callbackContext, 200)
        XCTAssertEqual(replay.eventId, event.eventId)
        XCTAssertEqual(replay.traceId, event.traceId)
        XCTAssertEqual(replay.eventAtMillis, event.eventAtMillis)
        XCTAssertEqual(replay.recoveryScope, "owner-a")
    }

    func testRecoveryOwnerChangeAndExplicitRemovalCancelPendingEvents() {
        for removal in [false, true] {
            let journal = makeJournal()
            let event = makeEnvelope(using: journal)
            let first = IosGeofenceCallbackJournal.RecoveryRegistration(
                geofence: event.geofence, scope: "owner-a", callbackHandle: 42, callbackContext: 71)
            XCTAssertTrue(journal.reconcileRecovery(registrations: [first], managedIds: ["office"], authoritative: true, nowMillis: 1_000))
            XCTAssertEqual(journal.enqueue(event), .stored)
            if removal {
                XCTAssertTrue(journal.cancelRecovery(identifier: "office"))
            } else {
                let other = IosGeofenceCallbackJournal.RecoveryRegistration(
                    geofence: event.geofence, scope: "owner-b", callbackHandle: 42, callbackContext: 71)
                XCTAssertTrue(journal.reconcileRecovery(registrations: [other], managedIds: ["office"], authoritative: true, nowMillis: 1_001))
            }
            XCTAssertEqual(makeJournal().pendingCount(), 0)
            if removal {
                // Once recovery was fully revoked, this identifier has the
                // same storage independence as a legacy registration again.
                defaults.set(Data("not-json".utf8), forKey: storageKey)
                XCTAssertTrue(makeJournal().cancelRecovery(identifier: "office"))
                XCTAssertTrue(makeJournal().reconcileRecovery(registrations: [], managedIds: ["office"], authoritative: true, nowMillis: 1_002))
            }
            defaults.removeObject(forKey: storageKey)
        }
    }

    func testRecoveryExitCannotOvertakeRetriedEnter() {
        for outcome: IosGeofenceCallbackDeliveryOutcome in [.succeeded, .retryableFailure] {
            defaults.removePersistentDomain(forName: suiteName)
            let journal = makeJournal()
            let enter = makeEnvelope(using: journal)
            let registration = IosGeofenceCallbackJournal.RecoveryRegistration(
                geofence: enter.geofence, scope: "owner-a", callbackHandle: 42, callbackContext: 71)
            XCTAssertTrue(journal.reconcileRecovery(registrations: [registration], managedIds: ["office"], authoritative: true, nowMillis: 1_000))
            XCTAssertEqual(journal.enqueue(enter), .stored)
            XCTAssertNotNil(journal.beginAttempt(eventId: enter.eventId, nowMillis: 1_000))
            XCTAssertEqual(journal.complete(eventId: enter.eventId, outcome: .terminalFailure(.callbackNotFound), nowMillis: 1_001), .awaitingCallbackRefresh)
            XCTAssertEqual(journal.enqueue(makeEnvelope(using: journal, eventId: "exit", eventAtMillis: 1_001, transition: .exit)), .stored)
            XCTAssertTrue(journal.drainBatch(nowMillis: 1_001).due.isEmpty)
            XCTAssertTrue(journal.reconcileRecovery(registrations: [registration], managedIds: ["office"], authoritative: true, nowMillis: 1_002))
            XCTAssertEqual(journal.drainBatch(nowMillis: 1_002).due.map(\.eventId), [enter.eventId])
            XCTAssertNotNil(journal.beginAttempt(eventId: enter.eventId, nowMillis: 1_002))
            XCTAssertTrue(journal.drainBatch(nowMillis: 1_003, inFlightEventIds: [enter.eventId]).due.isEmpty)
            let result = journal.complete(eventId: enter.eventId, outcome: outcome, nowMillis: 1_004)
            XCTAssertEqual(result, outcome == .succeeded ? .acknowledged : .retryScheduled(nextAttemptAtMillis: 2_004))
            // Once lookup works, an ordinary callback failure uses the original
            // retry policy instead of continuing to hold back the exit.
            XCTAssertEqual(makeJournal().drainBatch(nowMillis: 1_004).due.map(\.eventId), ["exit"])
        }
    }

    func testWaitingRecoveryStillExpiresAndNeverAdoptsUnscopedLegacyEvents() {
        let journal = makeJournal(timeToLiveMillis: 100)
        let legacy = makeEnvelope(using: journal)
        XCTAssertEqual(journal.enqueue(legacy), .stored)
        let registration = IosGeofenceCallbackJournal.RecoveryRegistration(
            geofence: legacy.geofence, scope: "owner-a", callbackHandle: 100, callbackContext: 200)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [registration], managedIds: ["office"], authoritative: true, nowMillis: 1_000))
        XCTAssertNil(journal.drainBatch(nowMillis: 1_000).due.single.recoveryScope)
        XCTAssertEqual(journal.complete(eventId: legacy.eventId, outcome: .succeeded, nowMillis: 1_001), .acknowledged)
        let scoped = makeEnvelope(using: journal, eventId: "scoped", transition: .exit, callbackHandle: 100, callbackContext: 200)
        XCTAssertEqual(journal.enqueue(scoped), .stored)
        XCTAssertEqual(journal.complete(eventId: scoped.eventId, outcome: .terminalFailure(.callbackInvalid), nowMillis: 1_002), .awaitingCallbackRefresh)
        XCTAssertEqual(journal.drainBatch(nowMillis: 1_100).terminallyDiscardedEventIds, ["scoped"])
    }

    func testRefreshOvertakingFailureDoesNotStrandEventOnOldHandles() {
        let journal = makeJournal()
        let event = makeEnvelope(using: journal)
        func registration(_ handle: Int64) -> IosGeofenceCallbackJournal.RecoveryRegistration {
            .init(geofence: event.geofence, scope: "owner", callbackHandle: handle, callbackContext: handle)
        }
        let original = IosGeofenceCallbackJournal.RecoveryRegistration(
            geofence: event.geofence, scope: "owner", callbackHandle: 42, callbackContext: 71)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [original], managedIds: ["office"], authoritative: true, nowMillis: 1_000))
        XCTAssertEqual(journal.enqueue(event), .stored)
        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 1_000))
        XCTAssertTrue(journal.reconcileRecovery(registrations: [registration(100)], managedIds: ["office"], authoritative: true, nowMillis: 1_001))
        XCTAssertEqual(journal.complete(eventId: event.eventId, outcome: .terminalFailure(.callbackNotFound), nowMillis: 1_002, deliveredHandle: 42, deliveredContext: 71), .retryScheduled(nextAttemptAtMillis: 1_002))
        XCTAssertEqual(journal.drainBatch(nowMillis: 1_002).due.single.callbackHandle, 100)

        // Refresh can repair registration without changing either raw handle.
        // A late failure from the pre-refresh attempt must still retry.
        defaults.removeObject(forKey: storageKey)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [original], managedIds: ["office"], authoritative: true, nowMillis: 2_000))
        XCTAssertEqual(journal.enqueue(event), .stored)
        let preRefreshAttempt = journal.beginAttempt(eventId: event.eventId, nowMillis: 2_000)
        XCTAssertNotNil(preRefreshAttempt)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [original], managedIds: ["office"], authoritative: true, nowMillis: 2_001))
        XCTAssertEqual(journal.complete(eventId: event.eventId, outcome: .terminalFailure(.callbackNotFound), nowMillis: 2_002, deliveredHandle: 42, deliveredContext: 71, deliveredRecoveryRefreshRevision: preRefreshAttempt?.recoveryRefreshRevision), .retryScheduled(nextAttemptAtMillis: 2_002))
        XCTAssertEqual(journal.drainBatch(nowMillis: 2_002).due.map(\.eventId), [event.eventId])
        let retried = journal.beginAttempt(eventId: event.eventId, nowMillis: 2_002)
        XCTAssertNotNil(retried)
        // Without another refresh, another lookup failure waits; it must not
        // loop immediately or consume all attempts on the same registration.
        XCTAssertEqual(journal.complete(eventId: event.eventId, outcome: .terminalFailure(.callbackNotFound), nowMillis: 2_003, deliveredHandle: 42, deliveredContext: 71, deliveredRecoveryRefreshRevision: retried?.recoveryRefreshRevision), .awaitingCallbackRefresh)
        XCTAssertTrue(journal.drainBatch(nowMillis: 2_003).due.isEmpty)
    }

    func testChangedFenceCannotReceiveOldRecoveryEventAndPartialSyncPreservesUnmanagedStream() {
        let journal = makeJournal()
        let event = makeEnvelope(using: journal)
        let original = IosGeofenceCallbackJournal.RecoveryRegistration(
            geofence: event.geofence, scope: "owner", callbackHandle: 42, callbackContext: 71)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [original], managedIds: ["office"], authoritative: true, nowMillis: 1_000))
        XCTAssertEqual(journal.enqueue(event), .stored)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [], managedIds: ["other"], authoritative: false, nowMillis: 1_001))
        XCTAssertEqual(journal.pendingCount(), 1)
        let reordered = makeEnvelope(using: journal, triggers: [.exit, .enter]).geofence
        // Recovery treats trigger order as irrelevant without changing the
        // pre-existing snapshot equality used by legacy duplicate filtering.
        XCTAssertNotEqual(event.geofence, reordered)
        let reorderedRegistration = IosGeofenceCallbackJournal.RecoveryRegistration(
            geofence: reordered, scope: "owner", callbackHandle: 42, callbackContext: 71)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [reorderedRegistration], managedIds: ["office"], authoritative: false, nowMillis: 1_001))
        XCTAssertEqual(journal.pendingCount(), 1)
        let changed = IosGeofenceCallbackJournal.RecoveryRegistration(
            geofence: makeEnvelope(using: journal, latitude: 12).geofence,
            scope: "owner", callbackHandle: 42, callbackContext: 71)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [changed], managedIds: ["office"], authoritative: false, nowMillis: 1_002))
        XCTAssertEqual(journal.pendingCount(), 0)
    }

    func testDeferredEventCannotAcquireNewOwnerWithIdenticalCallbacksAndFence() {
        let journal = makeJournal()
        let event = makeEnvelope(using: journal)
        let registration = IosGeofenceCallbackJournal.RecoveryRegistration(
            geofence: event.geofence, scope: "new-owner", callbackHandle: 42, callbackContext: 71)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [registration], managedIds: ["office"], authoritative: true, nowMillis: 1_000))
        for capturedScope: String? in ["old-owner", nil] {
            XCTAssertEqual(journal.enqueue(event, recoveryOrigin: .init(scope: capturedScope)), .staleRecoveryOrigin)
        }
        XCTAssertEqual(journal.pendingCount(), 0)
        XCTAssertEqual(journal.enqueue(event, recoveryOrigin: .init(scope: "new-owner")), .stored)
        XCTAssertEqual(journal.drainBatch(nowMillis: 1_000).due.single.recoveryScope, "new-owner")
    }

    func testCapturedNewRegistrationOwnerSurvivesInterruptedRecoveryCommit() {
        let journal = makeJournal()
        let event = makeEnvelope(using: journal)
        XCTAssertEqual(journal.enqueue(event, recoveryOrigin: .init(scope: "pending-owner")), .stored)
        let restored = makeJournal().drainBatch(nowMillis: 1_000).due.single
        XCTAssertEqual(restored.recoveryScope, "pending-owner")
        // Publishing scoped state requires the separate opt-in record first.
        // A failed opt-in write must not leave scoped events without that record
        // or add a storage dependency for registrations that never opted in.
        defaults.removePersistentDomain(forName: suiteName)
        defaults.rejectedKeys = [storageKey + ".recovery-identifiers"]
        defer { defaults.rejectedKeys = [] }
        let unavailable = makeJournal()
        let registration = IosGeofenceCallbackJournal.RecoveryRegistration(
            geofence: event.geofence, scope: "pending-owner", callbackHandle: 42, callbackContext: 71)
        XCTAssertEqual(unavailable.enqueue(event, recoveryOrigin: .init(scope: "pending-owner")), .storageFailure)
        XCTAssertFalse(unavailable.reconcileRecovery(registrations: [registration], managedIds: ["office"], authoritative: true, nowMillis: 1_001))
        XCTAssertNil(defaults.data(forKey: storageKey))
        XCTAssertTrue(unavailable.cancelRecovery(identifier: "office"))
        XCTAssertTrue(unavailable.reconcileRecovery(registrations: [], managedIds: ["office"], authoritative: true, nowMillis: 1_002))
        XCTAssertEqual(restored.eventAtMillis, event.eventAtMillis)
    }

    func testLastInFlightAttemptCannotBeExpiredAheadOfItsFollowingExit() {
        let journal = makeJournal(maximumAttempts: 2)
        let event = makeEnvelope(using: journal)
        let registration = IosGeofenceCallbackJournal.RecoveryRegistration(
            geofence: event.geofence, scope: "owner", callbackHandle: 42, callbackContext: 71)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [registration], managedIds: ["office"], authoritative: true, nowMillis: 1_000))
        XCTAssertEqual(journal.enqueue(event), .stored)
        XCTAssertEqual(journal.enqueue(makeEnvelope(using: journal, eventId: "exit", transition: .exit)), .stored)
        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 1_000))
        XCTAssertEqual(journal.complete(eventId: event.eventId, outcome: .terminalFailure(.callbackInvalid), nowMillis: 1_001), .awaitingCallbackRefresh)
        XCTAssertTrue(journal.reconcileRecovery(registrations: [registration], managedIds: ["office"], authoritative: true, nowMillis: 1_002))
        XCTAssertNotNil(journal.beginAttempt(eventId: event.eventId, nowMillis: 1_002))
        let active = journal.drainBatch(nowMillis: 1_003, inFlightEventIds: [event.eventId])
        XCTAssertTrue(active.due.isEmpty)
        XCTAssertTrue(active.terminallyDiscardedEventIds.isEmpty)
        XCTAssertNil(active.nextDueAtMillis)
        XCTAssertEqual(journal.complete(eventId: event.eventId, outcome: .retryableFailure, nowMillis: 1_004), .retryExhausted)
        XCTAssertEqual(journal.drainBatch(nowMillis: 1_004).due.map(\.eventId), ["exit"])

        // Preserve ordinary retry exhaustion even when recovery is enabled.
        for scoped in [false, true] {
            defaults.removeObject(forKey: storageKey)
            let legacy = makeJournal(maximumAttempts: 1)
            let unscoped = makeEnvelope(using: legacy)
            if scoped {
                XCTAssertTrue(legacy.reconcileRecovery(registrations: [registration], managedIds: ["office"], authoritative: true, nowMillis: 1_000))
            }
            XCTAssertEqual(legacy.enqueue(unscoped), .stored)
            XCTAssertNotNil(legacy.beginAttempt(eventId: unscoped.eventId, nowMillis: 1_000))
            let exhausted = legacy.drainBatch(nowMillis: 1_001, inFlightEventIds: [unscoped.eventId])
            XCTAssertEqual(exhausted.terminallyDiscardedEventIds, [unscoped.eventId])
        }
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
        geofenceId: String = "office",
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
                id: geofenceId,
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

private final class JournalTestUserDefaults: UserDefaults {
    var rejectedKeys: Set<String> = []

    override func set(_ value: Any?, forKey defaultName: String) {
        guard !rejectedKeys.contains(defaultName) else { return }
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        guard !rejectedKeys.contains(defaultName) else { return }
        super.removeObject(forKey: defaultName)
    }
}

private extension Array {
    var single: Element {
        XCTAssertEqual(count, 1)
        return self[0]
    }
}
