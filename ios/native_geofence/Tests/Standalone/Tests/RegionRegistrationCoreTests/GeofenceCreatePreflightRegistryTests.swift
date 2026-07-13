import XCTest
@testable import RegionRegistrationCore

final class GeofenceCreatePreflightRegistryTests: XCTestCase {
    func testRemoveOneCancelsPendingPreflightAndIgnoresItsLateContinuation() throws {
        let registry = GeofenceCreatePreflightRegistry()
        let completion = CompletionRecorder()
        let token = try XCTUnwrap(
            registry.begin(id: "office", completion: completion.record)
        )

        XCTAssertTrue(registry.cancel(id: "office"))
        XCTAssertEqual(completion.failures, [.removed(id: "office")])

        XCTAssertNil(registry.takeIfPending(token))
        XCTAssertEqual(completion.count, 1)
    }

    func testRemoveAllCancelsEveryPendingPreflightExactlyOnce() throws {
        let registry = GeofenceCreatePreflightRegistry()
        let office = CompletionRecorder()
        let home = CompletionRecorder()
        let officeToken = try XCTUnwrap(
            registry.begin(id: "office", completion: office.record)
        )
        let homeToken = try XCTUnwrap(
            registry.begin(id: "home", completion: home.record)
        )

        registry.cancelAll()
        registry.cancelAll()

        XCTAssertEqual(office.failures, [.removed(id: "office")])
        XCTAssertEqual(home.failures, [.removed(id: "home")])
        XCTAssertNil(registry.takeIfPending(officeToken))
        XCTAssertNil(registry.takeIfPending(homeToken))
        XCTAssertEqual(office.count, 1)
        XCTAssertEqual(home.count, 1)
    }

    func testFirstConcurrentSameIdentifierPreflightWinsDeterministically() throws {
        let registry = GeofenceCreatePreflightRegistry()
        let first = CompletionRecorder()
        let second = CompletionRecorder()
        let firstToken = try XCTUnwrap(
            registry.begin(id: "office", completion: first.record)
        )

        XCTAssertNil(registry.begin(id: "office", completion: second.record))
        XCTAssertEqual(second.failures, [.duplicateRequest(id: "office")])
        XCTAssertEqual(second.count, 1)

        let firstCompletion = try XCTUnwrap(registry.takeIfPending(firstToken))
        firstCompletion(.success(()))
        XCTAssertEqual(first.successes, 1)
        XCTAssertEqual(first.count, 1)
    }

    func testLateContinuationCannotConsumeNewSameIdentifierPreflight() throws {
        let registry = GeofenceCreatePreflightRegistry()
        let removed = CompletionRecorder()
        let replacement = CompletionRecorder()
        let removedToken = try XCTUnwrap(
            registry.begin(id: "office", completion: removed.record)
        )
        XCTAssertTrue(registry.cancel(id: "office"))
        let replacementToken = try XCTUnwrap(
            registry.begin(id: "office", completion: replacement.record)
        )

        XCTAssertNil(registry.takeIfPending(removedToken))
        let replacementCompletion = try XCTUnwrap(
            registry.takeIfPending(replacementToken)
        )
        replacementCompletion(.success(()))

        XCTAssertEqual(removed.failures, [.removed(id: "office")])
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(replacement.successes, 1)
        XCTAssertEqual(replacement.count, 1)
    }

    func testHandedOffCompletionCanOnlyResolveOnce() throws {
        let registry = GeofenceCreatePreflightRegistry()
        let completion = CompletionRecorder()
        let token = try XCTUnwrap(
            registry.begin(id: "office", completion: completion.record)
        )

        let handedOffCompletion = try XCTUnwrap(registry.takeIfPending(token))
        handedOffCompletion(.success(()))
        handedOffCompletion(
            .failure(GeofenceCreatePreflightFailure.removed(id: "office"))
        )
        XCTAssertFalse(registry.cancel(id: "office"))
        XCTAssertEqual(completion.successes, 1)
        XCTAssertTrue(completion.failures.isEmpty)
        XCTAssertEqual(completion.count, 1)
    }
}

private final class CompletionRecorder {
    private(set) var successes = 0
    private(set) var failures: [GeofenceCreatePreflightFailure] = []

    var count: Int {
        successes + failures.count
    }

    func record(_ result: Result<Void, any Error>) {
        switch result {
        case .success:
            successes += 1
        case .failure(let error):
            guard let failure = error as? GeofenceCreatePreflightFailure else {
                XCTFail("Unexpected failure: \(error)")
                return
            }
            failures.append(failure)
        }
    }
}
