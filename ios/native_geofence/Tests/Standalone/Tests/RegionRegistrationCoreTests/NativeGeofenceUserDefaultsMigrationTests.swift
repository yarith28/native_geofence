import Foundation
import XCTest
@testable import RegionRegistrationCore

final class NativeGeofenceUserDefaultsMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "\(Constants.PACKAGE_NAME).migration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMigratesEveryLegacyKeyAndRemovesGenericCopies() {
        for (index, migration) in Constants.LEGACY_USER_DEFAULTS_KEY_MIGRATIONS.enumerated() {
            defaults.set("legacy-\(index)", forKey: migration.legacy)
        }
        let legacyDiagnosticKey =
            Constants.LEGACY_DIAGNOSTIC_FACT_KEY_PREFIX + "worker"
        let currentDiagnosticKey = Constants.DIAGNOSTIC_FACT_KEY_PREFIX + "worker"
        defaults.set(["outcome": "completed"], forKey: legacyDiagnosticKey)

        NativeGeofenceUserDefaults.migrate(defaults)

        for (index, migration) in Constants.LEGACY_USER_DEFAULTS_KEY_MIGRATIONS.enumerated() {
            XCTAssertEqual(defaults.string(forKey: migration.current), "legacy-\(index)")
            XCTAssertNil(defaults.object(forKey: migration.legacy))
        }
        XCTAssertEqual(
            defaults.dictionary(forKey: currentDiagnosticKey)?["outcome"] as? String,
            "completed"
        )
        XCTAssertNil(defaults.object(forKey: legacyDiagnosticKey))
        XCTAssertTrue(defaults.bool(forKey: Constants.USER_DEFAULTS_MIGRATION_KEY))
    }

    func testNamespacedStateWinsAndMigrationIsIdempotent() {
        let migration = Constants.LEGACY_USER_DEFAULTS_KEY_MIGRATIONS[0]
        defaults.set("legacy", forKey: migration.legacy)
        defaults.set("current", forKey: migration.current)

        NativeGeofenceUserDefaults.migrate(defaults)
        defaults.set("updated", forKey: migration.current)
        NativeGeofenceUserDefaults.migrate(defaults)

        XCTAssertEqual(defaults.string(forKey: migration.current), "updated")
        XCTAssertNil(defaults.object(forKey: migration.legacy))
    }
}
