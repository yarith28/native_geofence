import XCTest
@testable import RegionRegistrationCore

final class IosGeofenceOperationQueueTests: XCTestCase {
    func testOperationsAreFifoAndLateCompletionCannotReleaseNewOwner() {
        let subject = IosGeofenceOperationQueue()
        var events: [String] = []
        var finishFirst: (() -> Void)?
        var finishSecond: (() -> Void)?

        subject.enqueueExclusive { finish in
            events.append("first")
            finishFirst = finish
        }
        subject.enqueueExclusive { finish in
            events.append("second")
            finishSecond = finish
        }
        drainMainQueue()
        XCTAssertEqual(events, ["first"])

        finishFirst?()
        drainMainQueue()
        XCTAssertEqual(events, ["first", "second"])

        finishFirst?()
        subject.enqueueExclusive { finish in
            events.append("third")
            finish()
        }
        drainMainQueue()
        XCTAssertEqual(events, ["first", "second"])

        finishSecond?()
        drainMainQueue()
        XCTAssertEqual(events, ["first", "second", "third"])
    }

    func testUnrelatedCreatesRemainConcurrentWhileExclusiveWaits() {
        let subject = IosGeofenceOperationQueue()
        var events: [String] = []
        var finishOffice: (() -> Void)?
        var finishHome: (() -> Void)?

        subject.enqueueConcurrent(id: "office") { finish in
            events.append("office")
            finishOffice = finish
        }
        subject.enqueueConcurrent(id: "home") { finish in
            events.append("home")
            finishHome = finish
        }
        subject.enqueueExclusive { finish in
            events.append("synchronize")
            finish()
        }
        drainMainQueue()

        XCTAssertEqual(events, ["office", "home"])
        finishOffice?()
        drainMainQueue()
        XCTAssertEqual(events, ["office", "home"])
        finishHome?()
        drainMainQueue()
        XCTAssertEqual(events, ["office", "home", "synchronize"])
    }

    func testMatchingRemovalCanCancelCreateBeforeWaitingExclusive() {
        let subject = IosGeofenceOperationQueue()
        var events: [String] = []
        var finishCreate: (() -> Void)?
        var finishRemoval: (() -> Void)?

        subject.enqueueConcurrent(id: "office") { finish in
            events.append("create")
            finishCreate = finish
        }
        subject.enqueueExclusive { finish in
            events.append("synchronize")
            finish()
        }
        subject.enqueueCancellation(id: "office") { finish in
            events.append("remove")
            finishRemoval = finish
        }
        drainMainQueue()

        XCTAssertEqual(events, ["create", "remove"])
        finishCreate?()
        drainMainQueue()
        XCTAssertEqual(events, ["create", "remove"])
        finishRemoval?()
        drainMainQueue()
        XCTAssertEqual(events, ["create", "remove", "synchronize"])

        finishCreate?()
        finishRemoval?()
        drainMainQueue()
        XCTAssertEqual(events, ["create", "remove", "synchronize"])
    }

    func testSameIdCreateReachesAdmissionAuthorityBeforeWaitingExclusive() {
        let subject = IosGeofenceOperationQueue()
        var events: [String] = []
        var finishFirst: (() -> Void)?

        subject.enqueueConcurrent(id: "office") { finish in
            events.append("first-create")
            finishFirst = finish
        }
        subject.enqueueExclusive { finish in
            events.append("synchronize")
            finish()
        }
        subject.enqueueConcurrent(id: "office") { finish in
            // NativeGeofenceApiImpl reaches the still-owned preflight or
            // registration token here and rejects this request as a duplicate.
            events.append("duplicate-create-admission")
            finish()
        }
        drainMainQueue()

        XCTAssertEqual(events, ["first-create", "duplicate-create-admission"])
        finishFirst?()
        drainMainQueue()
        XCTAssertEqual(
            events,
            ["first-create", "duplicate-create-admission", "synchronize"]
        )
    }

    func testUnrelatedRemovalDoesNotOvertakeWaitingExclusive() {
        let subject = IosGeofenceOperationQueue()
        var events: [String] = []
        var finishCreate: (() -> Void)?
        var finishSynchronization: (() -> Void)?

        subject.enqueueConcurrent(id: "office") { finish in
            events.append("create-office")
            finishCreate = finish
        }
        subject.enqueueExclusive { finish in
            events.append("synchronize")
            finishSynchronization = finish
        }
        subject.enqueueCancellation(id: "home") { finish in
            events.append("remove-home")
            finish()
        }
        drainMainQueue()

        XCTAssertEqual(events, ["create-office"])
        finishCreate?()
        drainMainQueue()
        XCTAssertEqual(events, ["create-office", "synchronize"])
        finishSynchronization?()
        drainMainQueue()
        XCTAssertEqual(
            events,
            ["create-office", "synchronize", "remove-home"]
        )
    }

    func testRemoveAllCanCancelEveryOutstandingCreateBeforeExclusive() {
        let subject = IosGeofenceOperationQueue()
        var events: [String] = []
        var finishes: [() -> Void] = []

        for id in ["office", "home"] {
            subject.enqueueConcurrent(id: id) { finish in
                events.append("create-\(id)")
                finishes.append(finish)
            }
        }
        subject.enqueueExclusive { finish in
            events.append("synchronize")
            finish()
        }
        subject.enqueueCancellation(id: nil) { finish in
            events.append("remove-all")
            finishes.append(finish)
        }
        drainMainQueue()

        XCTAssertEqual(events, ["create-office", "create-home", "remove-all"])
        finishes.forEach { $0() }
        drainMainQueue()
        XCTAssertEqual(
            events,
            ["create-office", "create-home", "remove-all", "synchronize"]
        )
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}
