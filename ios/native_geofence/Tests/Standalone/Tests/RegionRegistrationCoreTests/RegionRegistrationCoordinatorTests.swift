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
    func testDoesNotCompleteEarlyAndMatchingConfirmationCompletesOnlyOnce() {
        let monitor = FakeMonitor()
        let handles = HandleStore()
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()
        let requested = region(id: "office")

        XCTAssertNil(subject.start(region: requested, callbackHandle: 2, initialTrigger: false, completion: completion.record))
        XCTAssertEqual(completion.count, 0)
        XCTAssertNil(handles.values["office"])
        XCTAssertEqual(monitor.started.map(\.identifier), ["office"])

        XCTAssertNil(subject.didStartMonitoring(for: requested))
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

    func testInitialTriggerControlsRegionReturnedAfterConfirmation() {
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

            XCTAssertEqual(
                subject.didStartMonitoring(for: requested)?.identifier,
                initialTrigger ? requested.identifier : nil
            )
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
    }

    func testFailedReplacementCompletesOnlyAfterExactPriorRegionIsRestored() {
        let previous = region(id: "office", radius: 50, notifyOnEntry: false, notifyOnExit: true)
        let requested = region(id: "office", radius: 100, notifyOnEntry: true, notifyOnExit: false)
        let monitor = FakeMonitor([previous])
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()
        _ = subject.start(region: requested, callbackHandle: 2, initialTrigger: false, completion: completion.record)

        subject.didFailMonitoring(for: requested, error: NSError(domain: "test", code: 1))

        XCTAssertEqual(completion.count, 0)
        XCTAssertEqual(handles.values["office"], 1)
        XCTAssertFalse(handles.events.contains(.set("office", 2)))
        XCTAssertEqual(monitor.started.count, 2)
        XCTAssertTrue(monitor.started[0] === requested)
        XCTAssertTrue(monitor.started[1] === previous)
        XCTAssertEqual(monitor.stopped.count, 1)
        XCTAssertTrue(monitor.stopped[0] === requested)

        XCTAssertNil(subject.didStartMonitoring(for: previous))
        XCTAssertEqual(completion.failures.count, 1)
        XCTAssertEqual(handles.values["office"], 1)
        XCTAssertFalse(handles.events.contains(.set("office", 2)))
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

        let initialStateRegion = subject.start(
            region: requested,
            callbackHandle: 2,
            initialTrigger: true,
            completion: completion.record
        )

        XCTAssertTrue(initialStateRegion === existing)
        XCTAssertEqual(completion.successes, 1)
        XCTAssertEqual(handles.values["office"], 2)
        XCTAssertTrue(monitor.started.isEmpty)
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

        XCTAssertEqual(subject.didStartMonitoring(for: requested)?.identifier, "office")
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

        XCTAssertNil(subject.didStartMonitoring(for: office))
        XCTAssertNil(subject.didStartMonitoring(for: home))
        XCTAssertEqual(first.successes, 1)
        XCTAssertEqual(second.successes, 1)
        XCTAssertEqual(handles.values, ["office": 1, "home": 2])
    }

    func testIdenticalActiveRegistrationRefreshesHandleWithoutRestart() {
        let existing = region(id: "office")
        let monitor = FakeMonitor([existing])
        let handles = HandleStore(["office": 1])
        let subject = makeSubject(monitor, handles)
        let completion = CompletionRecorder()

        let initialStateRegion = subject.start(
            region: region(id: "office"),
            callbackHandle: 2,
            initialTrigger: true,
            completion: completion.record
        )

        XCTAssertTrue(initialStateRegion === existing)
        XCTAssertEqual(completion.successes, 1)
        XCTAssertEqual(handles.values["office"], 2)
        XCTAssertEqual(handles.events, [.set("office", 2)])
        XCTAssertTrue(monitor.started.isEmpty)
        XCTAssertTrue(monitor.stopped.isEmpty)
    }

    private func makeSubject(
        _ monitor: FakeMonitor,
        _ handles: HandleStore,
        timeoutSeconds: TimeInterval = 10,
        scheduleTimeout: @escaping RegionRegistrationCoordinator.TimeoutScheduler = { _, _ in }
    ) -> RegionRegistrationCoordinator {
        RegionRegistrationCoordinator(
            monitor: monitor,
            timeoutSeconds: timeoutSeconds,
            scheduleTimeout: scheduleTimeout,
            getCallbackHandle: { handles.values[$0] },
            setCallbackHandle: handles.set,
            removeCallbackHandle: handles.remove
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
