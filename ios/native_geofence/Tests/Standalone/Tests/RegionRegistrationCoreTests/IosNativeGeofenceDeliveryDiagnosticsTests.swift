import Foundation
import XCTest
@testable import RegionRegistrationCore

final class IosNativeGeofenceDeliveryDiagnosticsTests: XCTestCase {
    func testTracePersistsAcrossInstancesAndBoundsRetention() throws {
        let suiteName = "IosNativeGeofenceDeliveryDiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var wallClock: Int64 = 100
        var elapsed: Int64 = 200
        let subject = makeSubject(
            defaults: defaults,
            maximumEntries: 2,
            wallClock: { wallClock += 1; return wallClock },
            elapsed: { elapsed += 1; return elapsed }
        )

        XCTAssertTrue(
            subject.record(
                stage: "Core Location Callback",
                outcome: "Received",
                event: "ENTER",
                geofenceCount: 1,
                owner: "iOS Delegate"
            )
        )
        XCTAssertTrue(
            subject.record(
                stage: "boundary_gate",
                outcome: "accepted",
                event: "enter",
                reasonCode: "committed_identifier_semantics_mismatch"
            )
        )
        XCTAssertTrue(
            subject.record(
                stage: "callback_journal",
                outcome: "stored",
                event: "enter"
            )
        )

        let restored = makeSubject(defaults: defaults, maximumEntries: 2)
            .snapshot()
        XCTAssertEqual(restored.entries.map(\.sequence), [2, 3])
        XCTAssertEqual(restored.entries.map(\.stage), [
            "boundary_gate",
            "callback_journal",
        ])
        XCTAssertEqual(restored.droppedCount, 1)
    }

    func testCorruptTraceIsCountedAndReplacedByNextRecord() throws {
        let suiteName = "IosNativeGeofenceDeliveryDiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "trace")
        let subject = makeSubject(defaults: defaults, maximumEntries: 2)

        XCTAssertEqual(subject.snapshot().droppedCount, 1)
        XCTAssertTrue(
            subject.record(
                stage: "boundary_gate",
                outcome: "rejected",
                event: "enter",
                reasonCode: "unknown_identifier"
            )
        )

        let snapshot = subject.snapshot()
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.entries.single?.reasonCode, "unknown_identifier")
        XCTAssertEqual(snapshot.droppedCount, 1)
    }

    func testConcurrentRecordsHaveUniqueMonotonicSequences() throws {
        let suiteName = "IosNativeGeofenceDeliveryDiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let subject = makeSubject(defaults: defaults, maximumEntries: 64)

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            _ = subject.record(
                stage: "core_location_callback",
                outcome: "received",
                event: "event-\(index)"
            )
        }

        let snapshot = subject.snapshot()
        XCTAssertEqual(snapshot.entries.count, 64)
        XCTAssertEqual(
            snapshot.entries.map(\.sequence),
            (1 ... 64).map(Int64.init)
        )
        XCTAssertEqual(snapshot.droppedCount, 0)
    }

    private func makeSubject(
        defaults: UserDefaults,
        maximumEntries: Int,
        wallClock: @escaping () -> Int64 = { 1_000 },
        elapsed: @escaping () -> Int64 = { 2_000 }
    ) -> IosNativeGeofenceDeliveryDiagnostics {
        IosNativeGeofenceDeliveryDiagnostics(
            userDefaults: defaults,
            traceKey: "trace",
            sequenceKey: "sequence",
            droppedKey: "dropped",
            maximumEntries: maximumEntries,
            nowMillis: wallClock,
            elapsedRealtimeMillis: elapsed
        )
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? self[0] : nil
    }
}
