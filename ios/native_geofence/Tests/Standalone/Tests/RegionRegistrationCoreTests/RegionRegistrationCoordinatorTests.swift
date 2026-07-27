import CoreLocation
import XCTest
@testable import RegionRegistrationCore

private final class FakeMonitor: RegionMonitoring {
    var monitoredRegions: Set<CLRegion>
    private(set) var started: [CLRegion] = []
    private(set) var stopped: [CLRegion] = []

    init(_ monitoredRegions: Set<CLRegion> = []) {
        self.monitoredRegions = monitoredRegions
    }

    func startMonitoring(for region: CLRegion) { started.append(region) }
    func stopMonitoring(for region: CLRegion) { stopped.append(region) }
}

private final class HandleStore {
    enum Event: Equatable {
        case set(String, Int64)
        case remove(String)
    }

    var values: [String: Int64]
    private(set) var events: [Event] = []

    init(_ values: [String: Int64] = [:]) { self.values = values }

    func set(_ id: String, _ handle: Int64) {
        values[id] = handle
        events.append(.set(id, handle))
    }

    func remove(_ id: String) {
        values.removeValue(forKey: id)
        events.append(.remove(id))
    }
}

private final class ContextStore {
    var values: [String: Int64]

    init(_ values: [String: Int64] = [:]) { self.values = values }

    func set(_ id: String, _ context: Int64?) {
        if let context {
            values[id] = context
        } else {
            values.removeValue(forKey: id)
        }
    }
}

private final class CompletionRecorder {
    private(set) var successes = 0
    private(set) var failures: [RegionRegistrationFailure] = []
    var count: Int { successes + failures.count }

    func record(_ result: Result<Void, RegionRegistrationFailure>) {
        switch result {
        case .success: successes += 1
        case .failure(let failure): failures.append(failure)
        }
    }
}

final class RegionRegistrationCoordinatorTests: XCTestCase {
    func testPendingBoundaryCandidatesPreserveBothPossibleWinners() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let contexts = ContextStore(["office": 11])
        let subject = makeSubject(monitor, handles, contexts)

        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            callbackContext: 22,
            initialTrigger: false,
            completion: { _ in }
        )

        let candidates = subject.pendingBoundaryResolutionCandidates(
            id: "office"
        )
        XCTAssertEqual(candidates.map(\.callbackHandle), [1, 2])
        XCTAssertEqual(candidates.map(\.callbackContext), [11, 22])
        XCTAssertTrue(
            RegionMonitoringSemantics.matches(candidates[0].region, previous)
        )
        XCTAssertTrue(
            RegionMonitoringSemantics.matches(candidates[1].region, requested)
        )

        _ = subject.didFailMonitoring(
            for: requested,
            error: NSError(domain: "test", code: 1)
        )

        let restoration = subject.pendingBoundaryResolutionCandidates(
            id: "office"
        )
        XCTAssertEqual(restoration.map(\.callbackHandle), [1, 2])
        XCTAssertEqual(restoration.map(\.callbackContext), [11, 22])
        XCTAssertTrue(
            RegionMonitoringSemantics.matches(restoration[0].region, previous)
        )
        XCTAssertTrue(
            RegionMonitoringSemantics.matches(restoration[1].region, requested)
        )
    }

    func testChangedMetadataPublishesOnlyAfterMonitoringConfirmation() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let contexts = ContextStore(["office": 11])
        let subject = makeSubject(monitor, handles, contexts)

        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            callbackContext: 22,
            initialTrigger: false,
            completion: { _ in }
        )

        XCTAssertEqual(handles.values["office"], 1)
        XCTAssertEqual(contexts.values["office"], 11)
        _ = subject.didStartMonitoring(for: requested)
        XCTAssertEqual(handles.values["office"], 2)
        XCTAssertEqual(contexts.values["office"], 22)
    }

    func testIdenticalRegistrationRefreshesMetadataWithoutRestartingMonitoring() {
        let existing = region(id: "office")
        let monitor = FakeMonitor([existing])
        let handles = HandleStore(["office": 1])
        let contexts = ContextStore(["office": 11])
        let subject = makeSubject(monitor, handles, contexts)

        let committed = subject.start(
            region: region(id: "office"),
            callbackHandle: 2,
            callbackContext: 22,
            initialTrigger: false,
            completion: { _ in }
        )

        XCTAssertNotNil(committed)
        XCTAssertEqual(handles.values["office"], 2)
        XCTAssertEqual(contexts.values["office"], 22)
        XCTAssertTrue(monitor.started.isEmpty)
        XCTAssertTrue(monitor.stopped.isEmpty)
    }

    func testFailedReplacementRetainsPreviousContextThroughRestoration() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let contexts = ContextStore(["office": 11])
        let subject = makeSubject(monitor, handles, contexts)

        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            callbackContext: 22,
            initialTrigger: false,
            completion: { _ in }
        )
        subject.didFailMonitoring(for: requested, error: NSError(domain: "test", code: 1))
        _ = subject.didStartMonitoring(for: previous)

        XCTAssertEqual(handles.values["office"], 1)
        XCTAssertEqual(contexts.values["office"], 11)
    }

    func testDoesNotCompleteEarlyAndMatchingConfirmationCompletesOnlyOnce() {
        let monitor = FakeMonitor()
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()
        let requested = region(id: "office")

        XCTAssertNil(subject.start(region: requested, callbackHandle: 2, initialTrigger: false, completion: completion.record))
        XCTAssertTrue(subject.hasPendingMutation(id: "office"))
        XCTAssertEqual(completion.count, 0)
        XCTAssertNil(handles.values["office"])
        XCTAssertEqual(monitor.started.map(\.identifier), ["office"])

        let committed = subject.didStartMonitoring(for: requested)
        XCTAssertFalse(subject.hasPendingMutation(id: "office"))
        XCTAssertTrue(committed?.region === requested)
        XCTAssertEqual(committed?.initialTrigger, false)
        XCTAssertEqual(committed?.isNewMonitoringRegistration, true)
        XCTAssertNil(subject.didStartMonitoring(for: requested))
        XCTAssertEqual(completion.successes, 1)
        XCTAssertEqual(completion.count, 1)
        XCTAssertEqual(handles.values["office"], 2)
    }

    func testNewRegistrationClearsAStaleHandleUntilConfirmation() {
        let monitor = FakeMonitor()
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()
        let requested = region(id: "office")

        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            initialTrigger: false,
            completion: completion.record
        )

        XCTAssertNil(handles.values["office"])
        XCTAssertEqual(handles.events, [.remove("office")])
        XCTAssertEqual(completion.count, 0)

        _ = subject.didStartMonitoring(for: requested)

        XCTAssertEqual(handles.values["office"], 2)
        XCTAssertEqual(handles.events, [.remove("office"), .set("office", 2)])
        XCTAssertEqual(completion.successes, 1)
    }

    func testConfirmationReturnsTheCommittedInitialTriggerContract() {
        for initialTrigger in [false, true] {
            let monitor = FakeMonitor()
            let handles = HandleStore()
            let subject = makeSubject(monitor, handles)
            let requested = region(id: initialTrigger ? "true" : "false")

            _ = subject.start(
                region: requested,
                callbackHandle: 2,
                initialTrigger: initialTrigger,
                completion: { _ in }
            )

            let committed = subject.didStartMonitoring(for: requested)
            XCTAssertTrue(committed?.region === requested)
            XCTAssertEqual(committed?.initialTrigger, initialTrigger)
        }
    }

    func testGenericFailureMapsAndCleansUp() {
        let monitor = FakeMonitor()
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()
        let requested = region(id: "office")
        _ = subject.start(region: requested, callbackHandle: 2, initialTrigger: false, completion: completion.record)

        subject.didFailMonitoring(
            for: requested,
            error: NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        )

        XCTAssertEqual(completion.failures, [.monitoringFailed("iOS region monitoring failed for geofence ID=office: boom")])
        XCTAssertEqual(monitor.stopped.map(\.identifier), ["office"])
        XCTAssertNil(handles.values["office"])
        XCTAssertEqual(handles.events, [.remove("office")])
    }

    func testPermissionFailureMapsAndCleansUp() {
        let monitor = FakeMonitor()
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()
        let requested = region(id: "office")
        _ = subject.start(region: requested, callbackHandle: 2, initialTrigger: false, completion: completion.record)

        subject.didFailMonitoring(
            for: requested,
            error: NSError(domain: kCLErrorDomain, code: CLError.denied.rawValue)
        )

        guard case .missingLocationPermission(let message)? = completion.failures.first else {
            return XCTFail("Expected missing-location-permission failure")
        }
        XCTAssertTrue(message.contains("geofence ID=office"))
        XCTAssertEqual(monitor.stopped.map(\.identifier), ["office"])
        XCTAssertNil(handles.values["office"])
    }

    func testTimeoutCleansUpAndIgnoresLateCallback() {
        let monitor = FakeMonitor()
        let handles = HandleStore()
        var scheduledDelay: TimeInterval?
        var timeout: DispatchWorkItem?
        let subject = makeSubject(
            monitor,
            handles,
            timeoutSeconds: 3,
            maximumConfirmationAttempts: 1,
            scheduleTimeout: { delay, workItem in
                scheduledDelay = delay
                timeout = workItem
            }
        )
        let completion = CompletionRecorder()
        let requested = region(id: "office")
        _ = subject.start(region: requested, callbackHandle: 2, initialTrigger: true, completion: completion.record)

        XCTAssertEqual(scheduledDelay, 3)
        timeout?.perform()
        XCTAssertEqual(completion.count, 1)
        guard case .monitoringFailed(let message)? = completion.failures.first else {
            return XCTFail("Expected timeout failure")
        }
        XCTAssertTrue(message.contains("Timed out"))
        XCTAssertEqual(monitor.stopped.map(\.identifier), ["office"])
        XCTAssertNil(handles.values["office"])

        XCTAssertNil(subject.didStartMonitoring(for: requested))
        XCTAssertEqual(completion.count, 1)
        XCTAssertEqual(monitor.stopped.map(\.identifier), ["office", "office"])
    }

    func testLateConfirmationDuringRetryCommitsRegistration() {
        let monitor = FakeMonitor()
        let handles = HandleStore()
        var timeouts: [DispatchWorkItem] = []
        let subject = makeSubject(
            monitor,
            handles,
            scheduleTimeout: { _, workItem in timeouts.append(workItem) }
        )
        let completion = CompletionRecorder()
        let requested = region(id: "office")
        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            initialTrigger: true,
            completion: completion.record
        )

        timeouts[0].perform()
        XCTAssertEqual(completion.count, 0)
        XCTAssertEqual(monitor.started.count, 2)

        let committed = subject.didStartMonitoring(for: requested)

        XCTAssertTrue(committed?.region === requested)
        XCTAssertEqual(committed?.initialTrigger, true)
        XCTAssertEqual(completion.successes, 1)
        XCTAssertEqual(handles.values["office"], 2)
        XCTAssertFalse(subject.hasPendingMutation(id: "office"))
    }

    func testFailedReplacementCompletesOnlyAfterExactPriorRegionIsRestored() {
        let previous = region(id: "office", radius: 50, notifyOnEntry: false, notifyOnExit: true)
        let requested = region(id: "office", radius: 100, notifyOnEntry: true, notifyOnExit: false)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()
        _ = subject.start(region: requested, callbackHandle: 2, initialTrigger: false, completion: completion.record)
        XCTAssertTrue(subject.hasPendingMutation(id: "office"))

        subject.didFailMonitoring(for: requested, error: NSError(domain: "test", code: 1))
        XCTAssertTrue(subject.hasPendingMutation(id: "office"))

        XCTAssertEqual(completion.count, 0)
        XCTAssertEqual(handles.values["office"], 1)
        XCTAssertFalse(handles.events.contains(.set("office", 2)))
        XCTAssertEqual(monitor.started.count, 2)
        XCTAssertTrue(monitor.started[0] === requested)
        XCTAssertTrue(monitor.started[1] === previous)
        XCTAssertEqual(monitor.stopped.count, 1)
        XCTAssertTrue(monitor.stopped[0] === requested)

        XCTAssertNil(subject.didStartMonitoring(for: previous))
        XCTAssertFalse(subject.hasPendingMutation(id: "office"))
        XCTAssertEqual(completion.failures.count, 1)
        XCTAssertEqual(handles.values["office"], 1)
        XCTAssertFalse(handles.events.contains(.set("office", 2)))
    }

    func testIgnoredPreviousFailurePreservesGateThroughSuccessfulRestoration() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let gate = InitialStateRequestGate()
        let previousProbe = try! XCTUnwrap(
            gate.commit(region: previous, initialTrigger: true)
        )
        var restoredRegions: [CLCircularRegion] = []
        let subject = makeSubject(
            monitor,
            handles,
            restoreCommittedRegion: { region in
                restoredRegions.append(region)
                gate.restoreCommittedRegions([region])
            },
            invalidateCommittedRegion: gate.remove
        )

        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            initialTrigger: false,
            completion: { _ in }
        )

        subject.didFailMonitoring(
            for: previous,
            error: NSError(domain: "stale-previous", code: 1)
        )
        subject.didFailMonitoring(
            for: requested,
            error: NSError(domain: "requested", code: 2)
        )
        _ = subject.didStartMonitoring(for: previous)

        XCTAssertEqual(restoredRegions.count, 1)
        XCTAssertTrue(restoredRegions.first === previous)
        XCTAssertTrue(
            gate.consumeInitialStateResponse(for: previousProbe) === previous
        )
        XCTAssertTrue(gate.consumeBoundaryEvent(for: previous) === previous)
    }

    func testCommittedFailureInvalidatesGateAndCallbackHandle() {
        let active = region(id: "office")
        let monitor = FakeMonitor([active])
        let handles = HandleStore(["office": 1])
        let contexts = ContextStore(["office": 11])
        let gate = InitialStateRequestGate()
        let probe = try! XCTUnwrap(
            gate.commit(region: active, initialTrigger: true)
        )
        let subject = makeSubject(
            monitor,
            handles,
            contexts,
            invalidateMatchingCommittedRegion: gate.remove
        )

        subject.didFailMonitoring(
            for: active,
            error: NSError(domain: "active", code: 1)
        )

        XCTAssertNil(handles.values["office"])
        XCTAssertNil(contexts.values["office"])
        XCTAssertEqual(monitor.stopped.map(\.identifier), ["office"])
        XCTAssertNil(gate.consumeInitialStateResponse(for: probe))
        XCTAssertNil(gate.consumeBoundaryEvent(for: active))
    }

    func testStaleFailureAfterReplacementPreservesCurrentCommit() {
        let previous = region(id: "office", radius: 50)
        let replacement = region(id: "office", radius: 100)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let gate = InitialStateRequestGate()
        _ = gate.commit(region: previous, initialTrigger: false)
        let subject = makeSubject(
            monitor,
            handles,
            invalidateMatchingCommittedRegion: gate.remove
        )

        _ = subject.start(
            region: replacement,
            callbackHandle: 2,
            initialTrigger: false,
            completion: { _ in }
        )
        let committed = try! XCTUnwrap(
            subject.didStartMonitoring(for: replacement)
        )
        _ = gate.commit(
            region: committed.region,
            initialTrigger: committed.initialTrigger
        )

        subject.didFailMonitoring(
            for: previous,
            error: NSError(domain: "stale", code: 1)
        )

        XCTAssertEqual(handles.values["office"], 2)
        XCTAssertTrue(
            gate.consumeBoundaryEvent(for: replacement) === replacement
        )
        XCTAssertTrue(monitor.stopped.isEmpty)

        subject.didFailMonitoring(
            for: replacement,
            error: NSError(domain: "active", code: 2)
        )

        XCTAssertNil(handles.values["office"])
        XCTAssertNil(gate.consumeBoundaryEvent(for: replacement))
        XCTAssertEqual(monitor.stopped.map(\.identifier), ["office"])
    }

    func testNilFailureDoesNotCancelUnrelatedPendingRegistrationOrCommittedProbe() {
        let active = region(id: "office")
        let pending = region(id: "home")
        let monitor = FakeMonitor([active])
        let handles = HandleStore(["office": 1])
        let gate = InitialStateRequestGate()
        let probe = try! XCTUnwrap(
            gate.commit(region: active, initialTrigger: true)
        )
        let subject = makeSubject(
            monitor,
            handles,
            invalidateCommittedRegion: gate.remove
        )

        _ = subject.start(
            region: pending,
            callbackHandle: 2,
            initialTrigger: false,
            completion: { _ in }
        )

        subject.didFailMonitoring(
            for: nil,
            error: NSError(domain: "global", code: 1)
        )

        XCTAssertEqual(handles.values["office"], 1)
        XCTAssertNil(handles.values["home"])
        XCTAssertTrue(monitor.stopped.isEmpty)
        XCTAssertTrue(gate.consumeInitialStateResponse(for: probe) === active)
        XCTAssertTrue(gate.consumeBoundaryEvent(for: active) === active)

        _ = subject.didStartMonitoring(for: pending)
        XCTAssertEqual(handles.values["home"], 2)
    }

    func testNilFailureLeavesReplacementPendingUntilScopedFailureRestoresProbe() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let gate = InitialStateRequestGate()
        let previousProbe = try! XCTUnwrap(
            gate.commit(region: previous, initialTrigger: true)
        )
        let subject = makeSubject(
            monitor,
            handles,
            restoreCommittedRegion: { gate.restoreCommittedRegions([$0]) },
            invalidateCommittedRegion: gate.remove
        )

        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            initialTrigger: false,
            completion: { _ in }
        )
        subject.didFailMonitoring(
            for: nil,
            error: NSError(domain: "global", code: 1)
        )
        XCTAssertEqual(handles.values["office"], 1)

        subject.didFailMonitoring(
            for: requested,
            error: NSError(domain: "requested", code: 2)
        )
        _ = subject.didStartMonitoring(for: previous)

        XCTAssertEqual(handles.values["office"], 1)
        XCTAssertTrue(
            gate.consumeInitialStateResponse(for: previousProbe) === previous
        )
        XCTAssertTrue(gate.consumeBoundaryEvent(for: previous) === previous)
    }

    func testRestorationFailureInvalidatesGateAuthority() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let gate = InitialStateRequestGate()
        let previousProbe = try! XCTUnwrap(
            gate.commit(region: previous, initialTrigger: true)
        )
        let subject = makeSubject(
            monitor,
            handles,
            invalidateCommittedRegion: gate.remove
        )

        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            initialTrigger: false,
            completion: { _ in }
        )
        subject.didFailMonitoring(
            for: requested,
            error: NSError(domain: "requested", code: 1)
        )
        subject.didFailMonitoring(
            for: previous,
            error: NSError(domain: "restoration", code: 2)
        )

        XCTAssertNil(gate.consumeInitialStateResponse(for: previousProbe))
        XCTAssertNil(gate.consumeBoundaryEvent(for: previous))
    }

    func testNilRestorationFailureDoesNotInvalidateUntilScopedFailure() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let gate = InitialStateRequestGate()
        let previousProbe = try! XCTUnwrap(
            gate.commit(region: previous, initialTrigger: true)
        )
        var invalidated: [String] = []
        let subject = makeSubject(
            monitor,
            handles,
            invalidateCommittedRegion: {
                invalidated.append($0)
                gate.remove($0)
            }
        )

        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            initialTrigger: false,
            completion: { _ in }
        )
        subject.didFailMonitoring(
            for: requested,
            error: NSError(domain: "requested", code: 1)
        )
        subject.didFailMonitoring(
            for: nil,
            error: NSError(domain: "global", code: 2)
        )

        XCTAssertEqual(handles.values["office"], 1)
        XCTAssertTrue(invalidated.isEmpty)

        subject.didFailMonitoring(
            for: previous,
            error: NSError(domain: "restoration", code: 3)
        )

        XCTAssertEqual(invalidated, ["office"])
        XCTAssertNil(gate.consumeInitialStateResponse(for: previousProbe))
        XCTAssertNil(gate.consumeBoundaryEvent(for: previous))
    }

    func testRestorationTimeoutInvalidatesGateAuthority() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let gate = InitialStateRequestGate()
        _ = gate.commit(region: previous, initialTrigger: false)
        var timeouts: [DispatchWorkItem] = []
        let subject = makeSubject(
            monitor,
            handles,
            maximumConfirmationAttempts: 1,
            scheduleTimeout: { _, workItem in timeouts.append(workItem) },
            invalidateCommittedRegion: gate.remove
        )

        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            initialTrigger: false,
            completion: { _ in }
        )
        subject.didFailMonitoring(
            for: requested,
            error: NSError(domain: "requested", code: 1)
        )
        XCTAssertEqual(timeouts.count, 2)

        timeouts[1].perform()

        XCTAssertNil(gate.consumeBoundaryEvent(for: previous))
    }

    func testReplacementRestorationFailureRemovesHandleAndCompletesOnce() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()
        _ = subject.start(region: requested, callbackHandle: 2, initialTrigger: false, completion: completion.record)

        subject.didFailMonitoring(for: requested, error: NSError(domain: "test", code: 1))
        XCTAssertEqual(completion.count, 0)
        XCTAssertTrue(monitor.started.last === previous)

        subject.didFailMonitoring(for: previous, error: NSError(domain: "test", code: 2))

        XCTAssertEqual(completion.failures.count, 1)
        XCTAssertNil(handles.values["office"])
        XCTAssertEqual(handles.events, [.remove("office")])
        subject.didFailMonitoring(for: previous, error: NSError(domain: "test", code: 3))
        XCTAssertEqual(completion.count, 1)
    }

    func testReplacementRestorationTimeoutRemovesHandleAndIgnoresLateSuccess() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        var timeouts: [DispatchWorkItem] = []
        let subject = makeSubject(
            monitor,
            handles,
            maximumConfirmationAttempts: 1,
            scheduleTimeout: { _, workItem in timeouts.append(workItem) }
        )
        let completion = CompletionRecorder()
        _ = subject.start(region: requested, callbackHandle: 2, initialTrigger: false, completion: completion.record)

        subject.didFailMonitoring(for: requested, error: NSError(domain: "test", code: 1))
        guard timeouts.count == 2 else {
            return XCTFail("Expected registration and restoration timeouts, got \(timeouts.count)")
        }
        XCTAssertEqual(completion.count, 0)
        timeouts[1].perform()

        XCTAssertEqual(completion.failures.count, 1)
        XCTAssertNil(handles.values["office"])
        XCTAssertNil(subject.didStartMonitoring(for: previous))
        XCTAssertEqual(completion.count, 1)
        XCTAssertEqual(monitor.stopped.count, 3)
        XCTAssertTrue(monitor.stopped.last === previous)
    }

    func testLiveSameIdCollisionWithoutStoredHandleIsRejected() {
        let existing = region(id: "office", radius: 50)
        let monitor = FakeMonitor([existing])
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()

        XCTAssertNil(
            subject.start(
                region: region(id: "office", radius: 100),
                callbackHandle: 2,
                initialTrigger: false,
                completion: completion.record
            )
        )

        XCTAssertEqual(completion.failures.count, 1)
        XCTAssertTrue(monitor.started.isEmpty)
        XCTAssertTrue(monitor.stopped.isEmpty)
        XCTAssertTrue(handles.values.isEmpty)
        XCTAssertTrue(handles.events.isEmpty)
    }

    func testNonCircularSameIdCollisionIsRejectedEvenWithStoredHandle() {
        let existing = CLBeaconRegion(uuid: UUID(), identifier: "office")
        let monitor = FakeMonitor([existing])
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()

        XCTAssertNil(
            subject.start(
                region: region(id: "office"),
                callbackHandle: 2,
                initialTrigger: false,
                completion: completion.record
            )
        )

        XCTAssertEqual(completion.failures.count, 1)
        XCTAssertTrue(monitor.started.isEmpty)
        XCTAssertTrue(monitor.stopped.isEmpty)
        XCTAssertEqual(handles.values["office"], 1)
        XCTAssertTrue(handles.events.isEmpty)
    }

    func testNewRegistrationIsRejectedAtTheAppWideRegionLimit() {
        let existingRegions: Set<CLRegion> = Set(
            (0 ..< 20).map { region(id: "existing-\($0)") as CLRegion }
        )
        let monitor = FakeMonitor(existingRegions)
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()

        XCTAssertNil(
            subject.start(
                region: region(id: "new"),
                callbackHandle: 2,
                initialTrigger: false,
                completion: completion.record
            )
        )

        guard case .monitoringFailed(let message)? = completion.failures.first else {
            return XCTFail("Expected region-limit failure")
        }
        XCTAssertTrue(message.contains("at most 20"))
        XCTAssertTrue(monitor.started.isEmpty)
        XCTAssertTrue(handles.events.isEmpty)
    }

    func testOwnedReplacementIsAllowedAtTheAppWideRegionLimit() {
        let previous = region(id: "office", radius: 50)
        let existingRegions: Set<CLRegion> = Set(
            [previous as CLRegion]
                + (0 ..< 19).map { region(id: "existing-\($0)") as CLRegion }
        )
        let monitor = FakeMonitor(existingRegions)
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()
        let requested = region(id: "office", radius: 100)

        XCTAssertNil(
            subject.start(
                region: requested,
                callbackHandle: 2,
                initialTrigger: false,
                completion: completion.record
            )
        )

        XCTAssertEqual(completion.count, 0)
        XCTAssertEqual(monitor.started.count, 1)
        XCTAssertTrue(monitor.started[0] === requested)
        XCTAssertEqual(handles.values["office"], 1)
        XCTAssertTrue(handles.events.isEmpty)
    }

    func testPendingNewRegistrationsCountTowardTheAppWideRegionLimit() {
        let existingRegions: Set<CLRegion> = Set(
            (0 ..< 19).map { region(id: "existing-\($0)") as CLRegion }
        )
        let monitor = FakeMonitor(existingRegions)
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let first = CompletionRecorder()
        let second = CompletionRecorder()

        _ = subject.start(
            region: region(id: "first-new"),
            callbackHandle: 1,
            initialTrigger: false,
            completion: first.record
        )
        _ = subject.start(
            region: region(id: "second-new"),
            callbackHandle: 2,
            initialTrigger: false,
            completion: second.record
        )

        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(second.failures.count, 1)
        XCTAssertEqual(monitor.started.map(\.identifier), ["first-new"])
        XCTAssertTrue(handles.events.isEmpty)
    }

    func testPendingRegionAlreadyExposedByCoreLocationIsNotDoubleCounted() {
        let existingRegions: Set<CLRegion> = Set(
            (0 ..< 18).map { region(id: "existing-\($0)") as CLRegion }
        )
        let monitor = FakeMonitor(existingRegions)
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let firstRegion = region(id: "first-new")

        _ = subject.start(
            region: firstRegion,
            callbackHandle: 1,
            initialTrigger: false,
            completion: { _ in }
        )
        monitor.monitoredRegions.insert(firstRegion)

        let second = CompletionRecorder()
        _ = subject.start(
            region: region(id: "second-new"),
            callbackHandle: 2,
            initialTrigger: false,
            completion: second.record
        )

        XCTAssertEqual(second.count, 0)
        XCTAssertEqual(
            monitor.started.map(\.identifier),
            ["first-new", "second-new"]
        )
    }

    func testPendingReplacementReservesCapacityWhenOldRegionDisappears() {
        let previous = region(id: "office", radius: 50)
        let existingRegions: Set<CLRegion> = Set(
            [previous as CLRegion]
                + (0 ..< 19).map { region(id: "existing-\($0)") as CLRegion }
        )
        let monitor = FakeMonitor(existingRegions)
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)

        _ = subject.start(
            region: region(id: "office", radius: 100),
            callbackHandle: 2,
            initialTrigger: false,
            completion: { _ in }
        )
        monitor.monitoredRegions.remove(previous)

        let newRegistration = CompletionRecorder()
        _ = subject.start(
            region: region(id: "new"),
            callbackHandle: 3,
            initialTrigger: false,
            completion: newRegistration.record
        )

        XCTAssertEqual(newRegistration.failures.count, 1)
        XCTAssertEqual(monitor.started.map(\.identifier), ["office"])
    }

    func testPendingRestorationReservesCapacityWhenOldRegionDisappears() {
        let previous = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let existingRegions: Set<CLRegion> = Set(
            [previous as CLRegion]
                + (0 ..< 19).map { region(id: "existing-\($0)") as CLRegion }
        )
        let monitor = FakeMonitor(existingRegions)
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        let replacement = CompletionRecorder()

        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            initialTrigger: false,
            completion: replacement.record
        )
        monitor.monitoredRegions.remove(previous)
        subject.didFailMonitoring(
            for: requested,
            error: NSError(domain: "test", code: 1)
        )

        let newRegistration = CompletionRecorder()
        _ = subject.start(
            region: region(id: "new"),
            callbackHandle: 3,
            initialTrigger: false,
            completion: newRegistration.record
        )

        XCTAssertEqual(replacement.count, 0)
        XCTAssertEqual(newRegistration.failures.count, 1)
        XCTAssertEqual(monitor.started.map(\.identifier), ["office", "office"])
        XCTAssertEqual(handles.values["office"], 1)
    }

    func testCancellationTombstoneBlocksImmediateIdenticalRecreation() {
        let requested = region(id: "office")
        let monitor = FakeMonitor()
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        _ = subject.start(region: requested, callbackHandle: 1, initialTrigger: false, completion: { _ in })
        XCTAssertTrue(subject.cancel(id: "office"))
        monitor.monitoredRegions = [requested]
        let recreation = CompletionRecorder()

        XCTAssertNil(
            subject.start(
                region: region(id: "office"),
                callbackHandle: 2,
                initialTrigger: false,
                completion: recreation.record
            )
        )

        XCTAssertEqual(recreation.failures.count, 1)
        XCTAssertEqual(monitor.started.count, 1)
        XCTAssertEqual(monitor.stopped.count, 1)
        XCTAssertNil(handles.values["office"])
    }

    func testCancellationDoesNotSearchForOrStopAnActiveRegion() {
        let active = region(id: "office")
        let monitor = FakeMonitor([active])
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)

        XCTAssertFalse(subject.cancel(id: "office"))
        XCTAssertTrue(monitor.stopped.isEmpty)
        XCTAssertEqual(handles.values["office"], 1)

        subject.recordRemoval(of: active)
        let recreation = CompletionRecorder()
        _ = subject.start(
            region: region(id: "office"),
            callbackHandle: 2,
            initialTrigger: false,
            completion: recreation.record
        )
        XCTAssertEqual(recreation.failures.count, 1)
    }

    func testSynchronizationCanClearRemovalTombstoneBeforeRollbackRestore() {
        let active = region(id: "office")
        let monitor = FakeMonitor([active])
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        subject.recordRemoval(of: active)

        let blocked = CompletionRecorder()
        _ = subject.start(
            region: region(id: "office"),
            callbackHandle: 1,
            initialTrigger: false,
            completion: blocked.record
        )
        XCTAssertEqual(blocked.failures.count, 1)

        subject.clearRemovalTombstone(matching: active)
        let restored = CompletionRecorder()
        let committed = subject.start(
            region: region(id: "office"),
            callbackHandle: 1,
            initialTrigger: false,
            completion: restored.record
        )

        XCTAssertNotNil(committed)
        XCTAssertEqual(restored.successes, 1)
        XCTAssertTrue(monitor.started.isEmpty)
        XCTAssertTrue(monitor.stopped.isEmpty)
    }

    func testSynchronizationRollbackCanForceStartARegionStillVisibleAfterStop() {
        let active = region(id: "office")
        let monitor = FakeMonitor([active])
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        let restored = CompletionRecorder()
        subject.recordRemoval(of: active)
        subject.clearRemovalTombstone(matching: active)

        let committed = subject.startForSynchronization(
            region: region(id: "office"),
            callbackHandle: 1,
            forceMonitoring: true,
            completion: restored.record
        )

        XCTAssertNil(committed)
        XCTAssertEqual(monitor.started.map(\.identifier), ["office"])
        XCTAssertEqual(restored.count, 0)
        _ = subject.didStartMonitoring(for: monitor.started[0])
        XCTAssertEqual(restored.successes, 1)
    }

    func testRemovalTombstoneTracksPendingAndActiveReplacementRegions() {
        let active = region(id: "office", radius: 50)
        let requested = region(id: "office", radius: 100)
        let monitor = FakeMonitor([active])
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        _ = subject.start(
            region: requested,
            callbackHandle: 2,
            initialTrigger: false,
            completion: { _ in }
        )

        XCTAssertTrue(subject.cancel(id: "office"))
        subject.recordRemoval(of: active)
        _ = subject.didStartMonitoring(for: requested)
        _ = subject.didStartMonitoring(for: active)

        XCTAssertEqual(
            monitor.stopped.map { ObjectIdentifier($0) },
            [
                ObjectIdentifier(requested),
                ObjectIdentifier(requested),
                ObjectIdentifier(active),
            ]
        )
    }

    func testTinyCoreLocationNormalizationDifferencesStillMatch() {
        let existing = region(id: "office", latitude: 11.56, longitude: 104.93, radius: 100)
        let requested = region(
            id: "office",
            latitude: 11.5600000001,
            longitude: 104.9300000001,
            radius: 100.0000001
        )
        let monitor = FakeMonitor([existing])
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()

        let committed = subject.start(
            region: requested,
            callbackHandle: 2,
            initialTrigger: true,
            completion: completion.record
        )

        XCTAssertTrue(committed?.region === existing)
        XCTAssertEqual(committed?.initialTrigger, true)
        XCTAssertEqual(committed?.isNewMonitoringRegistration, false)
        XCTAssertEqual(completion.successes, 1)
        XCTAssertEqual(handles.values["office"], 2)
        XCTAssertTrue(monitor.started.isEmpty)
    }

    func testChangedActiveRegistrationCommitsAsNewMonitoringRegistration() {
        let existing = region(id: "office", radius: 100)
        let requested = region(id: "office", radius: 200)
        let monitor = FakeMonitor([existing])
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()

        XCTAssertNil(
            subject.start(
                region: requested,
                callbackHandle: 2,
                initialTrigger: false,
                completion: completion.record
            )
        )

        let committed = subject.didStartMonitoring(for: requested)

        XCTAssertTrue(committed?.region === requested)
        XCTAssertEqual(committed?.isNewMonitoringRegistration, true)
        XCTAssertEqual(completion.successes, 1)
        XCTAssertEqual(handles.values["office"], 2)
    }

    func testConcurrentSameIdIsRejectedWithoutDisturbingFirst() {
        let monitor = FakeMonitor()
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let first = CompletionRecorder()
        let second = CompletionRecorder()
        let requested = region(id: "office")
        _ = subject.start(region: requested, callbackHandle: 1, initialTrigger: false, completion: first.record)

        XCTAssertNil(
            subject.start(
                region: region(id: "office", radius: 200),
                callbackHandle: 2,
                initialTrigger: false,
                completion: second.record
            )
        )

        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(second.failures.count, 1)
        XCTAssertNil(handles.values["office"])
        XCTAssertEqual(monitor.started.count, 1)
        XCTAssertTrue(monitor.stopped.isEmpty)

        _ = subject.didStartMonitoring(for: requested)
        XCTAssertEqual(first.successes, 1)
    }

    func testStaleSameIdCallbacksWithDifferentSemanticsAreIgnored() {
        let monitor = FakeMonitor()
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()
        let requested = region(id: "office", radius: 100, notifyOnEntry: true, notifyOnExit: false)
        let stale = region(id: "office", radius: 200, notifyOnEntry: false, notifyOnExit: true)
        _ = subject.start(region: requested, callbackHandle: 2, initialTrigger: true, completion: completion.record)

        XCTAssertNil(subject.didStartMonitoring(for: stale))
        subject.didFailMonitoring(for: stale, error: NSError(domain: "test", code: 1))
        XCTAssertEqual(completion.count, 0)
        XCTAssertTrue(monitor.stopped.isEmpty)
        XCTAssertNil(handles.values["office"])

        XCTAssertEqual(
            subject.didStartMonitoring(for: requested)?.region.identifier,
            "office"
        )
        XCTAssertEqual(completion.successes, 1)
        XCTAssertEqual(handles.values["office"], 2)
    }

    func testCancellationCleansUpAndIgnoresLateCallback() {
        let monitor = FakeMonitor()
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()
        let requested = region(id: "office")
        _ = subject.start(region: requested, callbackHandle: 2, initialTrigger: true, completion: completion.record)

        XCTAssertTrue(subject.cancel(id: "office"))
        XCTAssertFalse(subject.cancel(id: "office"))
        XCTAssertEqual(completion.failures.count, 1)
        XCTAssertEqual(monitor.stopped.map(\.identifier), ["office"])
        XCTAssertNil(handles.values["office"])

        XCTAssertNil(subject.didStartMonitoring(for: requested))
        subject.didFailMonitoring(for: requested, error: NSError(domain: "test", code: 1))
        XCTAssertEqual(completion.count, 1)
    }

    func testNilRegionFailureDoesNotCancelUnrelatedPendingRegistrations() {
        let monitor = FakeMonitor()
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let first = CompletionRecorder()
        let second = CompletionRecorder()
        let office = region(id: "office")
        let home = region(id: "home")
        _ = subject.start(region: office, callbackHandle: 1, initialTrigger: false, completion: first.record)
        _ = subject.start(region: home, callbackHandle: 2, initialTrigger: false, completion: second.record)

        subject.didFailMonitoring(
            for: nil,
            error: NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "global failure"])
        )

        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(second.count, 0)
        XCTAssertTrue(monitor.stopped.isEmpty)

        _ = subject.didStartMonitoring(for: office)
        _ = subject.didStartMonitoring(for: home)
        XCTAssertEqual(first.successes, 1)
        XCTAssertEqual(second.successes, 1)
        XCTAssertEqual(handles.values, ["office": 1, "home": 2])
    }

    func testIdenticalActiveRegistrationCommitsWithoutRestart() {
        for initialTrigger in [false, true] {
            let id = initialTrigger ? "initial" : "no-initial"
            let existing = region(id: id)
            let monitor = FakeMonitor([existing])
            let handles = HandleStore([id: 1])
            let subject = makeSubject(monitor, handles)
            let completion = CompletionRecorder()

            let committed = subject.start(
                region: region(id: id),
                callbackHandle: 2,
                initialTrigger: initialTrigger,
                completion: completion.record
            )

            XCTAssertTrue(committed?.region === existing)
            XCTAssertEqual(committed?.initialTrigger, initialTrigger)
            XCTAssertEqual(completion.successes, 1)
            XCTAssertEqual(handles.values[id], 2)
            XCTAssertEqual(handles.events, [.set(id, 2)])
            XCTAssertTrue(monitor.started.isEmpty)
            XCTAssertTrue(monitor.stopped.isEmpty)
        }
    }

    func testMonitoringFailureOutcomeRecordsOnlyMatchingCommittedInvalidation() {
        let committed = region(id: "committed")
        let committedMonitor = FakeMonitor([committed])
        let committedHandles = HandleStore(["committed": 1])
        let committedSubject = makeSubject(
            committedMonitor,
            committedHandles,
            invalidateMatchingCommittedRegion: {
                RegionMonitoringSemantics.matches($0, committed)
            }
        )

        let committedOutcome = committedSubject.didFailMonitoring(
            for: committed,
            error: NSError(domain: "test", code: 1)
        )

        XCTAssertEqual(committedOutcome, .committedRegistrationInvalidated)
        XCTAssertTrue(committedOutcome.shouldRecordRegistrationFailureFact)
        XCTAssertNil(committedHandles.values["committed"])
        XCTAssertEqual(committedMonitor.stopped.map(\.identifier), ["committed"])

        let pendingMonitor = FakeMonitor()
        let pendingHandles = HandleStore()
        let pendingSubject = makeSubject(pendingMonitor, pendingHandles)
        let pendingCompletion = CompletionRecorder()
        let pending = region(id: "pending")
        _ = pendingSubject.start(
            region: pending,
            callbackHandle: 2,
            initialTrigger: false,
            completion: pendingCompletion.record
        )
        let pendingOutcome = pendingSubject.didFailMonitoring(
            for: pending,
            error: NSError(domain: "test", code: 2)
        )
        XCTAssertEqual(pendingOutcome, .pendingRegistrationHandled)
        XCTAssertFalse(pendingOutcome.shouldRecordRegistrationFailureFact)
        XCTAssertEqual(pendingCompletion.count, 1)

        let previous = region(id: "replacement", radius: 50)
        let requested = region(id: "replacement", radius: 100)
        let restorationMonitor = FakeMonitor([previous])
        let restorationHandles = HandleStore(["replacement": 3])
        let restorationSubject = makeSubject(restorationMonitor, restorationHandles)
        let restorationCompletion = CompletionRecorder()
        _ = restorationSubject.start(
            region: requested,
            callbackHandle: 4,
            initialTrigger: false,
            completion: restorationCompletion.record
        )
        XCTAssertEqual(
            restorationSubject.didFailMonitoring(
                for: requested,
                error: NSError(domain: "test", code: 3)
            ),
            .pendingRegistrationHandled
        )
        let restorationOutcome = restorationSubject.didFailMonitoring(
            for: previous,
            error: NSError(domain: "test", code: 4)
        )
        XCTAssertEqual(restorationOutcome, .pendingRestorationHandled)
        XCTAssertFalse(restorationOutcome.shouldRecordRegistrationFailureFact)
        XCTAssertEqual(restorationCompletion.count, 1)

        let staleMonitor = FakeMonitor()
        let staleHandles = HandleStore()
        let staleSubject = makeSubject(staleMonitor, staleHandles)
        let staleCompletion = CompletionRecorder()
        let current = region(id: "stale", radius: 100)
        _ = staleSubject.start(
            region: current,
            callbackHandle: 5,
            initialTrigger: false,
            completion: staleCompletion.record
        )
        let staleOutcome = staleSubject.didFailMonitoring(
            for: region(id: "stale", radius: 200),
            error: NSError(domain: "test", code: 5)
        )
        XCTAssertEqual(staleOutcome, .ignoredStaleOrUnowned)
        XCTAssertFalse(staleOutcome.shouldRecordRegistrationFailureFact)
        XCTAssertEqual(staleCompletion.count, 0)

        let ignoredSubject = makeSubject(FakeMonitor(), HandleStore())
        let foreignOutcome = ignoredSubject.didFailMonitoring(
            for: region(id: "foreign"),
            error: NSError(domain: "test", code: 6)
        )
        XCTAssertEqual(foreignOutcome, .ignoredStaleOrUnowned)
        XCTAssertFalse(foreignOutcome.shouldRecordRegistrationFailureFact)

        let nilOutcome = ignoredSubject.didFailMonitoring(
            for: nil,
            error: NSError(domain: "test", code: 7)
        )
        XCTAssertEqual(nilOutcome, .ignoredUnattributed)
        XCTAssertFalse(nilOutcome.shouldRecordRegistrationFailureFact)
    }

    private func makeSubject(
        _ monitor: FakeMonitor,
        _ handles: HandleStore,
        _ contexts: ContextStore = ContextStore(),
        timeoutSeconds: TimeInterval = 10,
        maximumConfirmationAttempts: Int = 3,
        scheduleTimeout: @escaping RegionRegistrationCoordinator.TimeoutScheduler = { _, _ in },
        restoreCommittedRegion: @escaping RegionRegistrationCoordinator.CommittedRegionRestorer = { _ in },
        invalidateCommittedRegion: @escaping RegionRegistrationCoordinator.CommittedRegionInvalidator = { _ in },
        invalidateMatchingCommittedRegion: @escaping
            RegionRegistrationCoordinator.MatchingCommittedRegionInvalidator = { _ in false }
    ) -> RegionRegistrationCoordinator {
        RegionRegistrationCoordinator(
            monitor: monitor,
            timeoutSeconds: timeoutSeconds,
            maximumConfirmationAttempts: maximumConfirmationAttempts,
            scheduleTimeout: scheduleTimeout,
            getCallbackHandle: { handles.values[$0] },
            getCallbackContext: { contexts.values[$0] },
            setCallbackHandle: handles.set,
            removeCallbackHandle: handles.remove,
            setCallbackContext: contexts.set,
            restoreCommittedRegion: restoreCommittedRegion,
            invalidateCommittedRegion: invalidateCommittedRegion,
            invalidateMatchingCommittedRegion: invalidateMatchingCommittedRegion
        )
    }

    private func region(
        id: String,
        latitude: CLLocationDegrees = 11.56,
        longitude: CLLocationDegrees = 104.93,
        radius: CLLocationDistance = 100,
        notifyOnEntry: Bool = true,
        notifyOnExit: Bool = true
    ) -> CLCircularRegion {
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            radius: radius,
            identifier: id
        )
        region.notifyOnEntry = notifyOnEntry
        region.notifyOnExit = notifyOnExit
        return region
    }
}
