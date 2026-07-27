import CoreLocation
import XCTest
@testable import RegionRegistrationCore

final class InitialStateRequestGateTests: XCTestCase {
    func testUnsolicitedPublicStateResponseIsIgnored() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(id: "office")
        XCTAssertNil(gate.commit(region: publicRegion, initialTrigger: false))

        XCTAssertNil(gate.consumeInitialStateResponse(for: publicRegion))
    }

    func testExplicitProbeIsPrivateOneShotAndMapsBackToPublicRegion() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(
            id: "office",
            latitude: 11.56,
            radius: 125,
            notifyOnEntry: false,
            notifyOnExit: true
        )
        let probe = try! XCTUnwrap(
            gate.commit(region: publicRegion, initialTrigger: true)
        )

        XCTAssertNotEqual(probe.identifier, publicRegion.identifier)
        XCTAssertEqual(probe.center.latitude, publicRegion.center.latitude)
        XCTAssertEqual(probe.center.longitude, publicRegion.center.longitude)
        XCTAssertEqual(probe.radius, publicRegion.radius)
        XCTAssertEqual(probe.notifyOnEntry, publicRegion.notifyOnEntry)
        XCTAssertEqual(probe.notifyOnExit, publicRegion.notifyOnExit)
        XCTAssertTrue(gate.consumeInitialStateResponse(for: probe) === publicRegion)
        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
    }

    func testPublicStateDoesNotConsumePendingPrivateProbe() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(id: "office")
        let probe = try! XCTUnwrap(
            gate.commit(region: publicRegion, initialTrigger: true)
        )

        XCTAssertNil(gate.consumeInitialStateResponse(for: publicRegion))
        XCTAssertTrue(gate.consumeInitialStateResponse(for: probe) === publicRegion)
    }

    func testSameIdReplacementInvalidatesTheOlderProbe() {
        let gate = InitialStateRequestGate()
        let oldProbe = try! XCTUnwrap(
            gate.commit(
                region: region(id: "office", latitude: 1),
                initialTrigger: true
            )
        )
        let currentRegion = region(id: "office", latitude: 2)
        let currentProbe = try! XCTUnwrap(
            gate.commit(region: currentRegion, initialTrigger: true)
        )

        XCTAssertNil(gate.consumeInitialStateResponse(for: oldProbe))
        XCTAssertTrue(
            gate.consumeInitialStateResponse(for: currentProbe) === currentRegion
        )
    }

    func testReplacementWithoutInitialTriggerInvalidatesTheOlderProbe() {
        let gate = InitialStateRequestGate()
        let oldProbe = try! XCTUnwrap(
            gate.commit(
                region: region(id: "office", radius: 50),
                initialTrigger: true
            )
        )
        let replacementRegion = region(id: "office", radius: 100)

        XCTAssertNil(
            gate.commit(region: replacementRegion, initialTrigger: false)
        )

        XCTAssertNil(gate.consumeInitialStateResponse(for: oldProbe))
        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: replacementRegion) === replacementRegion
        )
    }

    func testBoundaryWithoutPendingProbePassesThrough() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(id: "office")
        _ = gate.commit(region: publicRegion, initialTrigger: false)

        XCTAssertTrue(gate.consumeBoundaryEvent(for: publicRegion) === publicRegion)
    }

    func testCurrentBoundaryCancelsPendingProbe() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(id: "office")
        let probe = try! XCTUnwrap(
            gate.commit(region: publicRegion, initialTrigger: true)
        )
        let callbackRegion = region(id: "office")

        guard case .accepted(let acceptedRegion, let reason) =
            gate.decideBoundaryEvent(for: callbackRegion)
        else {
            return XCTFail("Expected the committed boundary to be accepted.")
        }
        XCTAssertTrue(acceptedRegion === publicRegion)
        XCTAssertEqual(reason, .monitoringSemanticsMatch)
        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
    }

    func testBoundaryUsesCommittedIdentifierWhenCallbackGeometryDiffers() {
        let gate = InitialStateRequestGate()
        let currentRegion = region(id: "office", latitude: 2)
        let currentProbe = try! XCTUnwrap(
            gate.commit(region: currentRegion, initialTrigger: true)
        )
        let staleRegion = region(id: "office", latitude: 1)

        guard case .accepted(let acceptedRegion, let reason) =
            gate.decideBoundaryEvent(for: staleRegion)
        else {
            return XCTFail("Expected the committed identifier to be accepted.")
        }
        XCTAssertTrue(acceptedRegion === currentRegion)
        XCTAssertEqual(reason, .monitoringSemanticsMismatch)
        XCTAssertNil(gate.consumeInitialStateResponse(for: currentProbe))
    }

    func testPendingMutationBufferPreservesMismatchedBoundaryUntilNewCommit() {
        let gate = InitialStateRequestGate()
        let previousRegion = region(id: "office", radius: 50)
        let probe = try! XCTUnwrap(
            gate.commit(region: previousRegion, initialTrigger: true)
        )
        let requestedRegion = region(id: "office", radius: 100)
        let callbackRegion = region(id: "office", radius: 75)
        let buffer = pendingBuffer()
        buffer.append(
            .enter,
            responseRegion: callbackRegion,
            receivedAtMillis: 123,
            resolutionCandidates: []
        )

        _ = gate.commit(region: requestedRegion, initialTrigger: false)
        let pending = buffer.pending(identifier: "office")

        XCTAssertEqual(pending.map(\.transition), [.enter])
        XCTAssertEqual(pending.map(\.receivedAtMillis), [123])
        let pendingEvent = try! XCTUnwrap(pending.first)
        guard case .accepted(let acceptedRegion, let reason) =
            gate.decideBoundaryEvent(for: pendingEvent.responseRegion)
        else {
            return XCTFail("Expected the deferred boundary to use the new commit.")
        }
        XCTAssertTrue(acceptedRegion === requestedRegion)
        XCTAssertEqual(reason, .monitoringSemanticsMismatch)
        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
    }

    func testPendingMutationBufferDrainsOnlyResolvedIdentifierInFifoOrder() {
        let buffer = pendingBuffer()
        buffer.append(
            .enter,
            responseRegion: region(id: "office"),
            receivedAtMillis: 1,
            resolutionCandidates: []
        )
        buffer.append(
            .exit,
            responseRegion: region(id: "home"),
            receivedAtMillis: 2,
            resolutionCandidates: []
        )
        buffer.append(
            .exit,
            responseRegion: region(id: "office"),
            receivedAtMillis: 3,
            resolutionCandidates: []
        )

        XCTAssertEqual(
            buffer.pending(identifier: "office").map(\.transition),
            [.enter, .exit]
        )
        XCTAssertEqual(
            buffer.pending(identifier: "home").map(\.transition),
            [.exit]
        )
    }

    func testPendingMutationBufferRemovalCannotLeakIntoSameIdRecreation() {
        let suiteName = "\(Constants.PACKAGE_NAME).pending-boundary.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let buffer = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
        buffer.append(
            .enter,
            responseRegion: region(id: "office"),
            receivedAtMillis: 1,
            resolutionCandidates: []
        )

        buffer.remove(identifier: "office")

        XCTAssertTrue(buffer.pending(identifier: "office").isEmpty)
        XCTAssertTrue(
            PendingBoundaryEventBuffer(
                userDefaults: defaults,
                storageKey: "events"
            ).pending(identifier: "office").isEmpty
        )
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPendingMutationBufferCanResolveAgainstRestoredPreviousCommit() {
        let gate = InitialStateRequestGate()
        let previousRegion = region(id: "office", radius: 50)
        _ = gate.commit(region: previousRegion, initialTrigger: false)
        let buffer = pendingBuffer()
        buffer.append(
            .exit,
            responseRegion: region(id: "office", radius: 100),
            receivedAtMillis: 456,
            resolutionCandidates: []
        )

        let pending = buffer.pending(identifier: "office")
        let pendingEvent = try! XCTUnwrap(pending.first)
        guard case .accepted(let acceptedRegion, _) =
            gate.decideBoundaryEvent(for: pendingEvent.responseRegion)
        else {
            return XCTFail("Expected the restored previous commit to own the event.")
        }
        XCTAssertTrue(acceptedRegion === previousRegion)
    }

    func testProductionAdmissionCoordinatorDefersUnknownPendingRegistration() {
        let gate = InitialStateRequestGate()
        let buffer = pendingBuffer()
        let requested = region(id: "office", radius: 100)
        var registrationPending = true
        let candidate = PendingBoundaryRegistrationCandidate(
            region: requested,
            callbackHandle: 7,
            callbackContext: 9
        )
        let coordinator = PendingBoundaryEventAdmissionCoordinator(
            gate: gate,
            buffer: buffer,
            hasPendingMutation: { _ in registrationPending },
            pendingCandidates: { _ in [candidate] }
        )

        guard case .deferred(let persisted) = coordinator.admit(
            responseRegion: region(id: "office", radius: 75),
            transition: .enter,
            receivedAtMillis: 123
        ) else {
            return XCTFail("Expected a pending new registration to defer.")
        }
        XCTAssertTrue(persisted)

        registrationPending = false
        _ = gate.commit(region: requested, initialTrigger: false)
        XCTAssertTrue(coordinator.isSettled(identifier: "office"))
        let pendingEvents = coordinator.pendingEvents(identifier: "office")
        XCTAssertEqual(pendingEvents.count, 1)
        let event = try! XCTUnwrap(pendingEvents.first)
        XCTAssertEqual(event.eventId.isEmpty, false)
        XCTAssertEqual(event.receivedAtMillis, 123)
        XCTAssertEqual(event.resolutionCandidates, [candidate])
        guard case .accepted(let committed, _) = gate.decideBoundaryEvent(
            for: event.responseRegion
        ) else {
            return XCTFail("Expected the committed registration to win.")
        }
        XCTAssertTrue(committed === requested)
    }

    func testProductionAdmissionCoordinatorHoldsThroughSynchronizationOutcome() {
        let gate = InitialStateRequestGate()
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        _ = gate.commit(region: previous, initialTrigger: false)
        let coordinator = PendingBoundaryEventAdmissionCoordinator(
            gate: gate,
            buffer: pendingBuffer(),
            hasPendingMutation: { _ in false },
            pendingCandidates: { _ in [] }
        )
        coordinator.beginSynchronization(
            identifier: "office",
            candidates: [
                PendingBoundaryRegistrationCandidate(
                    region: previous,
                    callbackHandle: 1,
                    callbackContext: 2
                ),
                PendingBoundaryRegistrationCandidate(
                    region: requested,
                    callbackHandle: 3,
                    callbackContext: 4
                ),
            ]
        )

        guard case .deferred = coordinator.admit(
            responseRegion: region(id: "office", radius: 75),
            transition: .exit,
            receivedAtMillis: 456
        ) else {
            return XCTFail("Expected synchronization-scoped deferral.")
        }
        _ = gate.commit(region: requested, initialTrigger: false)
        XCTAssertFalse(coordinator.isSettled(identifier: "office"))

        coordinator.finishSynchronization(identifier: "office")

        XCTAssertTrue(coordinator.isSettled(identifier: "office"))
        XCTAssertEqual(
            coordinator.pendingEvents(identifier: "office")
                .map(\.transition),
            [.exit]
        )
    }

    func testSynchronizationScopeExcludesCoordinatorLocalHybridCandidate() {
        let gate = InitialStateRequestGate()
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let previousCandidate = PendingBoundaryRegistrationCandidate(
            region: previous,
            callbackHandle: 1,
            callbackContext: 11
        )
        let requestedCandidate = PendingBoundaryRegistrationCandidate(
            region: requested,
            callbackHandle: 2,
            callbackContext: 22
        )
        let hybridCandidate = PendingBoundaryRegistrationCandidate(
            region: requested,
            callbackHandle: 1,
            callbackContext: 11
        )
        let coordinator = PendingBoundaryEventAdmissionCoordinator(
            gate: gate,
            buffer: pendingBuffer(),
            hasPendingMutation: { _ in true },
            pendingCandidates: { _ in [hybridCandidate] }
        )
        coordinator.beginSynchronization(
            identifier: "office",
            candidates: [previousCandidate, requestedCandidate]
        )

        guard case .deferred = coordinator.admit(
            responseRegion: requested,
            transition: .enter,
            receivedAtMillis: 1
        ) else {
            return XCTFail("Expected synchronization-scoped deferral.")
        }

        XCTAssertEqual(
            coordinator.pendingEvents(identifier: "office")
                .first?.resolutionCandidates,
            [previousCandidate, requestedCandidate]
        )
    }

    func testProductionResolutionCoordinatorFlushesCommittedWinnerMetadataAndTimestamp() {
        let gate = InitialStateRequestGate()
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        _ = gate.commit(region: previous, initialTrigger: false)
        var registrationPending = true
        var callbackHandle: Int64? = 1
        var callbackContext: Int64? = 11
        let previousCandidate = PendingBoundaryRegistrationCandidate(
            region: previous,
            callbackHandle: 1,
            callbackContext: 11
        )
        let requestedCandidate = PendingBoundaryRegistrationCandidate(
            region: requested,
            callbackHandle: 2,
            callbackContext: 22
        )
        let admission = PendingBoundaryEventAdmissionCoordinator(
            gate: gate,
            buffer: pendingBuffer(),
            hasPendingMutation: { _ in registrationPending },
            pendingCandidates: { _ in
                [previousCandidate, requestedCandidate]
            }
        )
        let resolution = PendingBoundaryEventResolutionCoordinator(
            gate: gate,
            admissionCoordinator: admission,
            getCallbackHandle: { _ in callbackHandle },
            getCallbackContext: { _ in callbackContext }
        )

        guard case .deferred = admission.admit(
            responseRegion: region(id: "office", radius: 75),
            transition: .exit,
            receivedAtMillis: 456
        ) else {
            return XCTFail("Expected the delegate pipeline to defer.")
        }
        guard case .unsettled = resolution.next(identifier: "office") else {
            return XCTFail("The pending registration must hold the callback.")
        }

        registrationPending = false
        callbackHandle = 2
        callbackContext = 22
        _ = gate.commit(region: requested, initialTrigger: false)

        guard case .deliver(
            let pending,
            let committed,
            let winner,
            let reason
        ) = resolution.next(identifier: "office") else {
            return XCTFail("Expected the committed winner to flush.")
        }
        XCTAssertEqual(pending.receivedAtMillis, 456)
        XCTAssertEqual(pending.transition, .exit)
        XCTAssertTrue(committed === requested)
        XCTAssertEqual(winner, requestedCandidate)
        XCTAssertEqual(reason, .monitoringSemanticsMismatch)
        XCTAssertTrue(resolution.remove(eventId: pending.eventId))
        guard case .empty = resolution.next(identifier: "office") else {
            return XCTFail(
                "Raw deletion must commit before the FIFO can advance."
            )
        }
    }

    func testDurablyPinnedWinnerSurvivesQueuedSameIdGeneration() {
        let suiteName = "\(Constants.PACKAGE_NAME).pending-boundary.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let buffer = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
        let gate = InitialStateRequestGate()
        let first = region(id: "office", radius: 50)
        let second = region(id: "office", radius: 100)
        let third = region(id: "office", radius: 150)
        _ = gate.commit(region: first, initialTrigger: false)
        var registrationPending = true
        var callbackHandle: Int64? = 1
        var callbackContext: Int64? = 11
        var candidates = [
            PendingBoundaryRegistrationCandidate(
                region: first,
                callbackHandle: 1,
                callbackContext: 11
            ),
            PendingBoundaryRegistrationCandidate(
                region: second,
                callbackHandle: 2,
                callbackContext: 22
            ),
        ]
        let admission = PendingBoundaryEventAdmissionCoordinator(
            gate: gate,
            buffer: buffer,
            hasPendingMutation: { _ in registrationPending },
            pendingCandidates: { _ in candidates }
        )
        let resolution = PendingBoundaryEventResolutionCoordinator(
            gate: gate,
            admissionCoordinator: admission,
            getCallbackHandle: { _ in callbackHandle },
            getCallbackContext: { _ in callbackContext }
        )

        guard case .deferred = admission.admit(
            responseRegion: second,
            transition: .enter,
            receivedAtMillis: 100
        ) else {
            return XCTFail("Expected first-generation deferral.")
        }
        registrationPending = false
        callbackHandle = 2
        callbackContext = 22
        _ = gate.commit(region: second, initialTrigger: false)
        XCTAssertEqual(
            resolution.prepare(identifier: "office"),
            .ready(cleanupRetryEventIds: [])
        )
        XCTAssertEqual(
            admission.pendingEvents(identifier: "office")
                .first?.resolvedRegistrationCandidate,
            candidates[1]
        )
        XCTAssertEqual(
            PendingBoundaryEventBuffer(
                userDefaults: defaults,
                storageKey: "events"
            ).pending(identifier: "office")
                .first?.resolvedRegistrationCandidate,
            candidates[1]
        )

        // Simulate callback-journal storage failure by retaining the raw event,
        // then allow a queued replacement to commit another generation.
        registrationPending = true
        candidates = [
            candidates[1],
            PendingBoundaryRegistrationCandidate(
                region: third,
                callbackHandle: 3,
                callbackContext: 33
            ),
        ]
        guard case .deferred = admission.admit(
            responseRegion: third,
            transition: .exit,
            receivedAtMillis: 200
        ) else {
            return XCTFail("Expected second-generation deferral.")
        }
        registrationPending = false
        callbackHandle = 3
        callbackContext = 33
        _ = gate.commit(region: third, initialTrigger: false)
        XCTAssertEqual(
            resolution.prepare(identifier: "office"),
            .ready(cleanupRetryEventIds: [])
        )

        guard case .deliver(
            let older,
            let olderRegion,
            let olderWinner,
            _
        ) = resolution.next(identifier: "office") else {
            return XCTFail("Expected the pinned older generation first.")
        }
        XCTAssertEqual(older.receivedAtMillis, 100)
        XCTAssertEqual(olderRegion.radius, second.radius)
        XCTAssertEqual(olderWinner?.callbackHandle, 2)
        XCTAssertTrue(resolution.remove(eventId: older.eventId))

        guard case .deliver(
            let newer,
            let newerRegion,
            let newerWinner,
            _
        ) = resolution.next(identifier: "office") else {
            return XCTFail("Expected the newer generation second.")
        }
        XCTAssertEqual(newer.receivedAtMillis, 200)
        XCTAssertEqual(newerRegion.radius, third.radius)
        XCTAssertEqual(newerWinner?.callbackHandle, 3)
    }

    func testWinnerResolverCompletesInterruptedCommitButRejectsStaleRecreation() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let candidates = [
            PendingBoundaryRegistrationCandidate(
                region: previous,
                callbackHandle: 1,
                callbackContext: 11
            ),
            PendingBoundaryRegistrationCandidate(
                region: requested,
                callbackHandle: 2,
                callbackContext: 22
            ),
        ]

        XCTAssertEqual(
            PendingBoundaryRegistrationWinnerResolver.select(
                from: candidates,
                committedRegion: requested,
                currentCallbackHandle: 1,
                currentCallbackContext: 11
            ),
            candidates[1]
        )
        XCTAssertNil(
            PendingBoundaryRegistrationWinnerResolver.select(
                from: candidates,
                committedRegion: requested,
                currentCallbackHandle: 3,
                currentCallbackContext: 33
            )
        )
    }

    func testRecoveryPlannerDeduplicatesRepeatedCandidateEvidence() {
        let requested = region(id: "office", radius: 100)
        let candidate = PendingBoundaryRegistrationCandidate(
            region: requested,
            callbackHandle: 2,
            callbackContext: 22
        )
        let buffer = pendingBuffer()
        buffer.append(
            .enter,
            responseRegion: requested,
            receivedAtMillis: 100,
            resolutionCandidates: [candidate]
        )
        buffer.append(
            .exit,
            responseRegion: requested,
            receivedAtMillis: 101,
            resolutionCandidates: [candidate]
        )
        let events = buffer.pending(identifier: "office")

        let interrupted = PendingBoundaryEventRecoveryPlanner.makePlan(
            events: events,
            committedRegion: requested,
            currentCallbackHandle: nil,
            currentCallbackContext: nil
        )
        XCTAssertEqual(interrupted?.winnerCandidate, candidate)
        XCTAssertEqual(interrupted?.resetsDeduplication, true)

        let unchanged = PendingBoundaryEventRecoveryPlanner.makePlan(
            events: events,
            committedRegion: requested,
            currentCallbackHandle: 2,
            currentCallbackContext: 22
        )
        XCTAssertEqual(unchanged?.winnerCandidate, candidate)
        XCTAssertEqual(unchanged?.resetsDeduplication, false)
    }

    func testRollbackPlannerAuthorizesOnlyCoherentLiveWinner() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let candidates = [
            PendingBoundaryRegistrationCandidate(
                region: previous,
                callbackHandle: 1,
                callbackContext: 11
            ),
            PendingBoundaryRegistrationCandidate(
                region: requested,
                callbackHandle: 2,
                callbackContext: 22
            ),
        ]
        var callbackHandle: Int64? = 1
        var callbackContext: Int64? = 11

        let interrupted = PendingBoundarySynchronizationRollbackPlanner
            .makePlan(
                monitoredRegions: [requested],
                authorityTouchedIdentifiers: ["office"],
                candidatesByIdentifier: ["office": candidates],
                getCallbackHandle: { _ in callbackHandle },
                getCallbackContext: { _ in callbackContext }
            )

        XCTAssertTrue(interrupted.incoherentIdentifiers.isEmpty)
        XCTAssertEqual(
            interrupted.authorities.first?.winnerCandidate,
            candidates[1]
        )
        XCTAssertEqual(
            interrupted.authorities.first?.resetsDeduplication,
            true
        )

        callbackHandle = 3
        callbackContext = 33
        let staleRecreation = PendingBoundarySynchronizationRollbackPlanner
            .makePlan(
                monitoredRegions: [requested],
                authorityTouchedIdentifiers: ["office"],
                candidatesByIdentifier: ["office": candidates],
                getCallbackHandle: { _ in callbackHandle },
                getCallbackContext: { _ in callbackContext }
            )

        XCTAssertTrue(staleRecreation.authorities.isEmpty)
        XCTAssertEqual(
            staleRecreation.incoherentIdentifiers,
            ["office"]
        )
    }

    func testFailedDurableCancellationRetainsRetryAuthority() {
        let suiteName = "\(Constants.PACKAGE_NAME).pending-boundary.\(UUID())"
        let defaults = FailingWriteUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let buffer = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
        let admission = PendingBoundaryEventAdmissionCoordinator(
            gate: InitialStateRequestGate(),
            buffer: buffer,
            hasPendingMutation: { _ in true },
            pendingCandidates: { _ in [] }
        )
        guard case .deferred = admission.admit(
            responseRegion: region(id: "office"),
            transition: .enter,
            receivedAtMillis: 1
        ) else {
            return XCTFail("Expected a buffered event.")
        }
        let eventId = try! XCTUnwrap(
            admission.pendingEvents(identifier: "office").first?.eventId
        )

        defaults.failWriteAttempt = defaults.writeAttempts + 2
        XCTAssertEqual(
            admission.cancel(identifier: "office"),
            .cleanupPending(eventIds: [eventId])
        )
        XCTAssertTrue(
            admission.pendingEvents(identifier: "office").isEmpty
        )
        let restoredBuffer = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
        XCTAssertTrue(restoredBuffer.pending(identifier: "office").isEmpty)
        XCTAssertEqual(
            restoredBuffer.pendingCancellationEventIds(),
            [eventId]
        )

        defaults.failWriteAttempt = nil
        XCTAssertEqual(
            restoredBuffer.cancel(eventIds: [eventId]),
            .completed
        )
        let cleanedBuffer = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
        XCTAssertTrue(cleanedBuffer.pending(identifier: "office").isEmpty)
        XCTAssertTrue(cleanedBuffer.pendingCancellationEventIds().isEmpty)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFailedInitialTombstoneWriteLeavesEventVisibleAndRecoverable() {
        let suiteName = "\(Constants.PACKAGE_NAME).pending-boundary.\(UUID())"
        let defaults = FailingWriteUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let buffer = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
        let result = buffer.append(
            .enter,
            responseRegion: region(id: "office"),
            receivedAtMillis: 1,
            resolutionCandidates: []
        )
        XCTAssertTrue(result.persisted)

        defaults.failWrites = true
        XCTAssertEqual(
            buffer.cancel(eventIds: [result.event.eventId]),
            .persistenceFailure(eventIds: [result.event.eventId])
        )
        XCTAssertEqual(
            buffer.pending(identifier: "office").map(\.eventId),
            [result.event.eventId]
        )
        XCTAssertTrue(buffer.pendingCancellationEventIds().isEmpty)

        let restored = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
        XCTAssertEqual(
            restored.pending(identifier: "office").map(\.eventId),
            [result.event.eventId]
        )
        XCTAssertTrue(restored.pendingCancellationEventIds().isEmpty)
        defaults.failWrites = false
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testWinnerPersistenceFailureKeepsLaterCallbackBehindBacklogUntilRetry() {
        let suiteName = "\(Constants.PACKAGE_NAME).pending-boundary.\(UUID())"
        let defaults = FailingWriteUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let buffer = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
        let gate = InitialStateRequestGate()
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        _ = gate.commit(region: previous, initialTrigger: false)
        var registrationPending = true
        let requestedCandidate = PendingBoundaryRegistrationCandidate(
            region: requested,
            callbackHandle: 2,
            callbackContext: 22
        )
        let admission = PendingBoundaryEventAdmissionCoordinator(
            gate: gate,
            buffer: buffer,
            hasPendingMutation: { _ in registrationPending },
            pendingCandidates: { _ in [requestedCandidate] }
        )
        let resolution = PendingBoundaryEventResolutionCoordinator(
            gate: gate,
            admissionCoordinator: admission,
            getCallbackHandle: { _ in 2 },
            getCallbackContext: { _ in 22 }
        )
        guard case .deferred(let persisted) = admission.admit(
            responseRegion: requested,
            transition: .enter,
            receivedAtMillis: 1
        ) else {
            return XCTFail("Expected a buffered event.")
        }
        XCTAssertTrue(persisted)
        registrationPending = false
        _ = gate.commit(region: requested, initialTrigger: false)

        defaults.failWrites = true
        XCTAssertEqual(
            resolution.prepare(identifier: "office"),
            .storageFailure
        )
        XCTAssertNil(
            admission.pendingEvents(identifier: "office")
                .first?.resolvedRegistrationCandidate
        )

        defaults.failWrites = false
        guard case .deferred(let laterPersisted) = admission.admit(
            responseRegion: requested,
            transition: .exit,
            receivedAtMillis: 2
        ) else {
            return XCTFail(
                "A settled raw backlog must retain FIFO admission authority."
            )
        }
        XCTAssertTrue(laterPersisted)
        XCTAssertEqual(
            resolution.prepare(identifier: "office"),
            .ready(cleanupRetryEventIds: [])
        )
        XCTAssertEqual(
            admission.pendingEvents(identifier: "office")
                .first?.resolvedRegistrationCandidate,
            requestedCandidate
        )
        guard case .deliver(let first, _, _, _) = resolution.next(
            identifier: "office"
        ) else {
            return XCTFail("Expected the older callback first.")
        }
        XCTAssertEqual(first.transition, .enter)
        XCTAssertEqual(first.receivedAtMillis, 1)
        XCTAssertTrue(resolution.remove(eventId: first.eventId))
        guard case .deliver(let second, _, _, _) = resolution.next(
            identifier: "office"
        ) else {
            return XCTFail("Expected the later callback second.")
        }
        XCTAssertEqual(second.transition, .exit)
        XCTAssertEqual(second.receivedAtMillis, 2)
    }

    func testFailedInitialPersistenceCanBeRetriedBeforeResolution() {
        let suiteName = "\(Constants.PACKAGE_NAME).pending-boundary.\(UUID())"
        let defaults = FailingWriteUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let buffer = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )

        defaults.failWrites = true
        let result = buffer.append(
            .enter,
            responseRegion: region(id: "office"),
            receivedAtMillis: 1,
            resolutionCandidates: []
        )
        XCTAssertFalse(result.persisted)
        XCTAssertEqual(
            buffer.pending(identifier: "office").map(\.eventId),
            [result.event.eventId]
        )

        defaults.failWrites = false
        XCTAssertTrue(buffer.retryPersistence())
        XCTAssertEqual(
            PendingBoundaryEventBuffer(
                userDefaults: defaults,
                storageKey: "events"
            ).pending(identifier: "office").map(\.eventId),
            [result.event.eventId]
        )
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFallbackStoreRecoversInitialEventWhenUserDefaultsWritesFail() {
        let suiteName = "\(Constants.PACKAGE_NAME).pending-boundary.\(UUID())"
        let defaults = FailingWriteUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let fallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "native-geofence-pending-boundary-\(UUID().uuidString)"
            )
            .appendingPathComponent("events.json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(
                at: fallbackURL.deletingLastPathComponent()
            )
        }
        let buffer = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events",
            fallbackStorageURL: fallbackURL
        )
        let firstResult = buffer.append(
            .enter,
            responseRegion: region(id: "office"),
            receivedAtMillis: 122,
            resolutionCandidates: []
        )
        XCTAssertTrue(firstResult.persisted)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fallbackURL.path)
        )

        defaults.failWrites = true
        let secondResult = buffer.append(
            .exit,
            responseRegion: region(id: "office"),
            receivedAtMillis: 123,
            resolutionCandidates: []
        )

        XCTAssertTrue(secondResult.persisted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackURL.path))
        let restored = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events",
            fallbackStorageURL: fallbackURL
        )
        XCTAssertEqual(
            restored.pending(identifier: "office").map(\.eventId),
            [firstResult.event.eventId, secondResult.event.eventId]
        )
        XCTAssertEqual(
            restored.pending(identifier: "office").map(\.receivedAtMillis),
            [122, 123]
        )

        defaults.failWrites = false
        XCTAssertTrue(restored.removeAll())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackURL.path))
        XCTAssertTrue(
            PendingBoundaryEventBuffer(
                userDefaults: defaults,
                storageKey: "events",
                fallbackStorageURL: fallbackURL
            ).pending(identifier: "office").isEmpty
        )
    }

    func testLegacyPendingEventArrayRemainsRecoverable() {
        let suiteName = "\(Constants.PACKAGE_NAME).pending-boundary.\(UUID())"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let legacyEvent = PendingBoundaryEvent(
            eventId: "legacy-event",
            sequence: 7,
            transition: .exit,
            responseRegionSnapshot: PendingBoundaryRegionSnapshot(
                region: region(id: "office")
            ),
            receivedAtMillis: 123,
            resolutionCandidates: []
        )
        defaults.set(
            try! JSONEncoder().encode([legacyEvent]),
            forKey: "events"
        )

        let restored = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
        XCTAssertEqual(
            restored.pending(identifier: "office"),
            [legacyEvent]
        )
        XCTAssertTrue(restored.pendingCancellationEventIds().isEmpty)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPendingMutationBufferSurvivesRelaunchWithStableFifoAndIdentity() {
        let suiteName = "\(Constants.PACKAGE_NAME).pending-boundary.\(UUID())"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let first = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
        let firstResult = first.append(
            .enter,
            responseRegion: region(id: "office"),
            receivedAtMillis: 1_000,
            resolutionCandidates: []
        )
        let secondResult = first.append(
            .exit,
            responseRegion: region(id: "office"),
            receivedAtMillis: 1_000,
            resolutionCandidates: []
        )
        XCTAssertTrue(firstResult.persisted)
        XCTAssertTrue(secondResult.persisted)

        let restored = PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
        let events = restored.pending(identifier: "office")

        XCTAssertEqual(
            events.map(\.eventId),
            [firstResult.event.eventId, secondResult.event.eventId]
        )
        XCTAssertEqual(events.map(\.transition), [.enter, .exit])
        XCTAssertEqual(events.map(\.receivedAtMillis), [1_000, 1_000])
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCallbackGeometryAndFlagsAreNotBoundaryAdmissionAuthority() {
        let gate = InitialStateRequestGate()
        let publicRegion = region(
            id: "office",
            latitude: 11.56,
            longitude: 104.93,
            radius: 100
        )
        let probe = try! XCTUnwrap(
            gate.commit(region: publicRegion, initialTrigger: true)
        )
        let normalizedRegion = region(
            id: "office",
            latitude: 11.57,
            longitude: 104.94,
            radius: 250,
            notifyOnEntry: false,
            notifyOnExit: false
        )

        guard case .accepted(let acceptedRegion, let reason) =
            gate.decideBoundaryEvent(for: normalizedRegion)
        else {
            return XCTFail("Expected the committed identifier to be accepted.")
        }
        XCTAssertTrue(acceptedRegion === publicRegion)
        XCTAssertEqual(reason, .monitoringSemanticsMismatch)
        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
    }

    func testPrivateProbeCannotBeRoutedAsBoundaryEvent() {
        let gate = InitialStateRequestGate()
        let probe = try! XCTUnwrap(
            gate.commit(region: region(id: "office"), initialTrigger: true)
        )

        XCTAssertNil(gate.consumeBoundaryEvent(for: probe))
        guard case .rejected(let reason) = gate.decideBoundaryEvent(for: probe) else {
            return XCTFail("Expected the private probe to be rejected.")
        }
        XCTAssertEqual(reason, .privateInitialStateProbe)
    }

    func testUnknownBoundaryIdentifierReportsAStableReason() {
        let gate = InitialStateRequestGate()
        _ = gate.commit(region: region(id: "office"), initialTrigger: false)

        guard case .rejected(let reason) = gate.decideBoundaryEvent(
            for: region(id: "home")
        ) else {
            return XCTFail("Expected the unknown identifier to be rejected.")
        }
        XCTAssertEqual(reason, .unknownIdentifier)
    }

    func testNonCircularBoundaryReportsAStableReason() {
        let gate = InitialStateRequestGate()
        _ = gate.commit(region: region(id: "office"), initialTrigger: false)

        guard case .rejected(let reason) = gate.decideBoundaryEvent(
            for: CLBeaconRegion(uuid: UUID(), identifier: "office")
        ) else {
            return XCTFail("Expected the non-circular region to be rejected.")
        }
        XCTAssertEqual(reason, .unsupportedRegionType)
    }

    func testRemovalAndRemoveAllInvalidateAuthority() {
        let gate = InitialStateRequestGate()
        let officeRegion = region(id: "office")
        let homeRegion = region(id: "home")
        let officeProbe = try! XCTUnwrap(
            gate.commit(region: officeRegion, initialTrigger: true)
        )
        let homeProbe = try! XCTUnwrap(
            gate.commit(region: homeRegion, initialTrigger: true)
        )

        gate.remove("office")
        XCTAssertNil(gate.consumeInitialStateResponse(for: officeProbe))
        XCTAssertNil(gate.consumeBoundaryEvent(for: officeRegion))

        gate.removeAll()
        XCTAssertNil(gate.consumeInitialStateResponse(for: homeProbe))
        XCTAssertNil(gate.consumeBoundaryEvent(for: homeRegion))
    }

    func testBoundaryUsesPreviousCommitUntilReplacementCommits() {
        let gate = InitialStateRequestGate()
        let previousRegion = region(id: "office", radius: 50)
        let requestedRegion = region(id: "office", radius: 100)
        _ = gate.commit(region: previousRegion, initialTrigger: false)

        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: requestedRegion) === previousRegion
        )
    }

    func testBoundaryUsesCurrentCommitAfterReplacement() {
        let gate = InitialStateRequestGate()
        let previousRegion = region(id: "office", radius: 50)
        let replacementRegion = region(id: "office", radius: 100)
        _ = gate.commit(region: previousRegion, initialTrigger: false)
        _ = gate.commit(region: replacementRegion, initialTrigger: false)

        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: previousRegion) === replacementRegion
        )
        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: replacementRegion) === replacementRegion
        )
    }

    func testRestoredCommitAuthorizesBoundaryWithoutInitialProbe() {
        let gate = InitialStateRequestGate()
        let restoredRegion = region(id: "office")
        gate.restoreCommittedRegions([restoredRegion])

        XCTAssertNil(gate.consumeInitialStateResponse(for: restoredRegion))
        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: restoredRegion) === restoredRegion
        )
    }

    func testRestoringChangedSemanticsInvalidatesStaleProbe() {
        let gate = InitialStateRequestGate()
        let probe = try! XCTUnwrap(
            gate.commit(
                region: region(id: "office", radius: 50),
                initialTrigger: true
            )
        )
        let restoredRegion = region(id: "office", radius: 100)

        gate.restoreCommittedRegions([restoredRegion])

        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: restoredRegion) === restoredRegion
        )
    }

    func testSynchronizationAuthorityReplacementPreservesUnrelatedProbe() {
        let gate = InitialStateRequestGate()
        let office = region(id: "office", radius: 50)
        let home = region(id: "home", radius: 75)
        let officeProbe = try! XCTUnwrap(
            gate.commit(region: office, initialTrigger: true)
        )
        let homeProbe = try! XCTUnwrap(
            gate.commit(region: home, initialTrigger: true)
        )
        let restoredOffice = region(id: "office", radius: 100)

        gate.replaceCommittedRegions(
            for: ["office"],
            with: [restoredOffice, home]
        )

        XCTAssertNil(gate.consumeInitialStateResponse(for: officeProbe))
        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: restoredOffice) === restoredOffice
        )
        XCTAssertTrue(gate.consumeInitialStateResponse(for: homeProbe) === home)
    }

    func testEmptyTargetedRestorationRemovesOnlyTransactionOwnedAuthority() {
        let gate = InitialStateRequestGate()
        let office = region(id: "office")
        let home = region(id: "home")
        let homeProbe = try! XCTUnwrap(
            gate.commit(region: home, initialTrigger: true)
        )
        _ = gate.commit(region: office, initialTrigger: false)

        gate.replaceCommittedRegions(for: ["office"], with: [])

        XCTAssertNil(gate.consumeBoundaryEvent(for: office))
        XCTAssertTrue(gate.consumeInitialStateResponse(for: homeProbe) === home)
    }

    private func region(
        id: String,
        latitude: CLLocationDegrees = 0,
        longitude: CLLocationDegrees = 0,
        radius: CLLocationDistance = 100,
        notifyOnEntry: Bool = true,
        notifyOnExit: Bool = true
    ) -> CLCircularRegion {
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: longitude
            ),
            radius: radius,
            identifier: id
        )
        region.notifyOnEntry = notifyOnEntry
        region.notifyOnExit = notifyOnExit
        return region
    }

    private func pendingBuffer() -> PendingBoundaryEventBuffer {
        let defaults = UserDefaults(
            suiteName: "\(Constants.PACKAGE_NAME).pending-boundary.\(UUID())"
        )!
        return PendingBoundaryEventBuffer(
            userDefaults: defaults,
            storageKey: "events"
        )
    }
}

private final class FailingWriteUserDefaults: UserDefaults {
    var failWrites = false
    var failWriteAttempt: Int?
    private(set) var writeAttempts = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        writeAttempts += 1
        guard !failWrites, failWriteAttempt != writeAttempts else { return }
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        guard !failWrites else { return }
        super.removeObject(forKey: defaultName)
    }
}
