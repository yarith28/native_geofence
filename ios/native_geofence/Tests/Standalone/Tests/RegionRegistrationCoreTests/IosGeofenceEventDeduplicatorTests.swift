import Foundation
import XCTest
@testable import RegionRegistrationCore

final class IosGeofenceEventDeduplicatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var subject: IosGeofenceEventDeduplicator!

    override func setUp() {
        super.setUp()
        suiteName = "\(Constants.PACKAGE_NAME).dedup-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        subject = IosGeofenceEventDeduplicator(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        subject = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSuppressionWindowIsHalfOpenAndDoesNotSlide() {
        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 1_000))
        XCTAssertFalse(accept(id: "office", transition: .enter, atMillis: 10_999))
        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 11_000))
        XCTAssertFalse(accept(id: "office", transition: .enter, atMillis: 11_001))
    }

    func testBaselinePersistsAcrossInstances() {
        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 1_000))

        let restored = IosGeofenceEventDeduplicator(userDefaults: defaults)

        XCTAssertEqual(
            restored.suppressedAgeMillis(
                id: "office",
                transition: .enter,
                eventAtMillis: 1_001
            ),
            1
        )
    }

    func testOppositeTransitionsPassAndReplaceBaseline() {
        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 1_000))
        XCTAssertTrue(accept(id: "office", transition: .exit, atMillis: 1_001))
        XCTAssertFalse(accept(id: "office", transition: .exit, atMillis: 1_002))
        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 1_003))
    }

    func testRegionsAreIndependentAndScopedRemovalPreservesOthers() {
        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 1_000))
        XCTAssertTrue(accept(id: "home", transition: .enter, atMillis: 1_000))

        subject.remove(id: "office")

        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 1_001))
        XCTAssertFalse(accept(id: "home", transition: .enter, atMillis: 1_001))
        subject.remove(id: "missing")
    }

    func testRemoveAllResetsEveryRegion() {
        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 1_000))
        XCTAssertTrue(accept(id: "home", transition: .exit, atMillis: 1_000))

        subject.removeAll()

        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 1_001))
        XCTAssertTrue(accept(id: "home", transition: .exit, atMillis: 1_001))
    }

    func testClockRollbackAndExtremeTimestampsFailOpenAndHeal() {
        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 20_000))
        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 19_000))
        XCTAssertFalse(accept(id: "office", transition: .enter, atMillis: 19_001))

        subject.recordAccepted(
            id: "office",
            transition: .enter,
            eventAtMillis: Int64.min
        )
        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: Int64.max))
        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: Int64.min))
    }

    func testMalformedPersistenceFailsOpenAndHealsOnlyTargetEntry() {
        XCTAssertTrue(accept(id: "home", transition: .exit, atMillis: 1_000))
        defaults.set(
            [
                "home": ["event": "exit", "atMillis": NSNumber(value: 1_000)],
                "office": ["event": "unknown", "atMillis": "bad"],
            ],
            forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY
        )

        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 1_001))
        XCTAssertFalse(accept(id: "office", transition: .enter, atMillis: 1_002))
        XCTAssertFalse(accept(id: "home", transition: .exit, atMillis: 1_001))

        let office = defaults.dictionary(
            forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY
        )?["office"] as? [String: Any]
        XCTAssertEqual(office?["event"] as? String, "enter")
    }

    func testMalformedRootFailsOpenAndHeals() {
        defaults.set("not-a-dictionary", forKey: Constants.GEOFENCE_LAST_EVENT_DICT_KEY)

        XCTAssertTrue(accept(id: "office", transition: .enter, atMillis: 1_000))
        XCTAssertFalse(accept(id: "office", transition: .enter, atMillis: 1_001))
    }

    private func accept(
        id: String,
        transition: IosGeofenceTransition,
        atMillis: Int64
    ) -> Bool {
        if subject.suppressedAgeMillis(
            id: id,
            transition: transition,
            eventAtMillis: atMillis
        ) != nil {
            return false
        }
        subject.recordAccepted(
            id: id,
            transition: transition,
            eventAtMillis: atMillis
        )
        return true
    }
}
