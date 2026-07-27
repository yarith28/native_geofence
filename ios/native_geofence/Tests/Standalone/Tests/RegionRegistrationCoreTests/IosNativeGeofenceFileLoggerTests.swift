import Foundation
import XCTest
@testable import RegionRegistrationCore

final class IosNativeGeofenceFileLoggerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var temporaryDirectory: URL!
    private var logFileURL: URL!

    override func setUpWithError() throws {
        suiteName = "IosNativeGeofenceFileLoggerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        logFileURL = temporaryDirectory.appendingPathComponent(
            "native_geofence.log"
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        defaults = nil
        temporaryDirectory = nil
        logFileURL = nil
    }

    func testVerboseFalseKeepsImportantDiagnosticsButFiltersDebug() throws {
        let store = makeStore()
        let logger = IosNativeGeofenceFileLogger(
            category: "test",
            store: store
        )

        XCTAssertFalse(logger.error("disabled error"))
        try store.configure(
            enabled: true,
            verbose: false,
            maxBytes: 64 * 1024
        )

        var debugMessageEvaluated = false
        XCTAssertFalse(
            logger.debug(({
                debugMessageEvaluated = true
                return "chatty trace"
            })())
        )
        XCTAssertFalse(debugMessageEvaluated)
        XCTAssertTrue(logger.diagnostic("boundary callback received"))
        XCTAssertTrue(logger.info("callback journal persisted"))
        XCTAssertTrue(logger.warning("callback retry scheduled"))
        XCTAssertTrue(logger.error("callback delivery failed"))

        let content = try store.read()
        XCTAssertFalse(content.contains("disabled error"))
        XCTAssertFalse(content.contains("chatty trace"))
        XCTAssertTrue(content.contains("[diagnostic] test: boundary callback received"))
        XCTAssertTrue(content.contains("[info] test: callback journal persisted"))
        XCTAssertTrue(content.contains("[warning] test: callback retry scheduled"))
        XCTAssertTrue(content.contains("[error] test: callback delivery failed"))
    }

    func testPersistedVerboseConfigurationWorksBeforePluginInitialization() throws {
        let configuringStore = makeStore()
        try configuringStore.configure(
            enabled: true,
            verbose: true,
            maxBytes: 64 * 1024
        )

        let coldStore = makeStore()
        let coldLogger = IosNativeGeofenceFileLogger(
            category: "cold-start",
            store: coldStore
        )

        XCTAssertTrue(coldLogger.debug("early background trace"))
        XCTAssertTrue(
            try coldStore.read().contains(
                "[debug] cold-start: early background trace"
            )
        )
    }

    func testWritesRemainFifoAndClearRemovesContent() throws {
        let store = makeStore(
            now: { Date(timeIntervalSince1970: 1_721_000_000.123) }
        )
        try store.configure(
            enabled: true,
            verbose: false,
            maxBytes: 64 * 1024
        )
        let logger = IosNativeGeofenceFileLogger(
            category: "ordering",
            store: store
        )

        XCTAssertTrue(logger.diagnostic("first"))
        XCTAssertTrue(logger.error("second"))
        XCTAssertTrue(logger.info("third"))

        let content = try store.read()
        let first = try XCTUnwrap(content.range(of: "ordering: first"))
        let second = try XCTUnwrap(content.range(of: "ordering: second"))
        let third = try XCTUnwrap(content.range(of: "ordering: third"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertLessThan(second.lowerBound, third.lowerBound)
        XCTAssertEqual(content.components(separatedBy: "\n").count - 1, 3)

        try store.clear()
        XCTAssertEqual(try store.read(), "")
    }

    func testFileRemainsBoundedAndRetainsNewestCompleteRecords() throws {
        let store = makeStore()
        try store.configure(
            enabled: true,
            verbose: false,
            maxBytes: Constants.MIN_LOG_FILE_MAX_BYTES
        )
        let logger = IosNativeGeofenceFileLogger(
            category: "bounded",
            store: store
        )

        for index in 0 ..< 200 {
            XCTAssertTrue(
                logger.diagnostic(
                    "record-\(index)-\(String(repeating: "x", count: 160))"
                )
            )
        }

        let archiveFileURL = logFileURL.appendingPathExtension("previous")
        let activeData = try Data(contentsOf: logFileURL)
        let archiveData = try Data(contentsOf: archiveFileURL)
        let content = try store.read()
        let segmentBytes = Constants.MIN_LOG_FILE_MAX_BYTES / 2
        XCTAssertLessThanOrEqual(activeData.count, segmentBytes)
        XCTAssertLessThanOrEqual(archiveData.count, segmentBytes)
        XCTAssertLessThanOrEqual(
            activeData.count + archiveData.count,
            Constants.MIN_LOG_FILE_MAX_BYTES
        )
        XCTAssertFalse(content.contains("record-0-"))
        XCTAssertTrue(content.contains("record-199-"))
        XCTAssertTrue(content.hasSuffix("\n"))
    }

    func testOversizedUnicodeRecordRemainsCompleteAndReadable() throws {
        let store = makeStore()
        try store.configure(
            enabled: true,
            verbose: false,
            maxBytes: Constants.MIN_LOG_FILE_MAX_BYTES
        )
        let logger = IosNativeGeofenceFileLogger(
            category: "unicode",
            store: store
        )

        XCTAssertTrue(
            logger.error(String(repeating: "😀", count: 6_000))
        )

        let content = try store.read()
        let activeData = try Data(contentsOf: logFileURL)
        XCTAssertLessThanOrEqual(
            activeData.count,
            Constants.MIN_LOG_FILE_MAX_BYTES / 2
        )
        XCTAssertTrue(content.contains("[error] unicode:"))
        XCTAssertTrue(content.contains("… [truncated]"))
        XCTAssertTrue(content.hasSuffix("\n"))
        XCTAssertFalse(content.contains("\u{FFFD}"))
    }

    func testUnreadableExistingPathIsNotReplacedDuringConfiguration() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: logFileURL,
            withIntermediateDirectories: true
        )
        let sentinel = logFileURL.appendingPathComponent("sentinel")
        try Data("preserve-me".utf8).write(to: sentinel)

        XCTAssertThrowsError(
            try store.configure(
                enabled: true,
                verbose: false,
                maxBytes: Constants.MIN_LOG_FILE_MAX_BYTES
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve-me".utf8))
        XCTAssertNil(
            defaults.object(forKey: Constants.LOG_FILE_ENABLED_KEY)
        )
    }

    func testAppendIoFailureReturnsFalseAndPreservesExistingPath() throws {
        let store = makeStore()
        try store.configure(
            enabled: true,
            verbose: false,
            maxBytes: Constants.MIN_LOG_FILE_MAX_BYTES
        )
        try FileManager.default.createDirectory(
            at: logFileURL,
            withIntermediateDirectories: true
        )
        let sentinel = logFileURL.appendingPathComponent("sentinel")
        try Data("preserve-me".utf8).write(to: sentinel)
        let logger = IosNativeGeofenceFileLogger(
            category: "io-failure",
            store: store
        )

        XCTAssertFalse(logger.error("must not escape the error handler"))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve-me".utf8))
    }

    func testLowerMaximumCompactsExistingSegmentsAndKeepsNewestRecord() throws {
        let store = makeStore()
        try store.configure(
            enabled: true,
            verbose: false,
            maxBytes: 64 * 1024
        )
        let logger = IosNativeGeofenceFileLogger(
            category: "reconfigure",
            store: store
        )
        for index in 0 ..< 400 {
            XCTAssertTrue(
                logger.info(
                    "record-\(index)-\(String(repeating: "x", count: 160))"
                )
            )
        }

        try store.configure(
            enabled: true,
            verbose: false,
            maxBytes: Constants.MIN_LOG_FILE_MAX_BYTES
        )

        let archiveFileURL = logFileURL.appendingPathExtension("previous")
        let activeData = try Data(contentsOf: logFileURL)
        let archiveData = try Data(contentsOf: archiveFileURL)
        let content = try store.read()
        XCTAssertLessThanOrEqual(
            activeData.count + archiveData.count,
            Constants.MIN_LOG_FILE_MAX_BYTES
        )
        XCTAssertFalse(content.contains("record-0-"))
        XCTAssertTrue(content.contains("record-399-"))
        XCTAssertTrue(content.hasSuffix("\n"))
    }

    private func makeStore(
        now: @escaping () -> Date = Date.init
    ) -> IosNativeGeofenceLogFileStore {
        IosNativeGeofenceLogFileStore(
            userDefaults: defaults,
            logFileURL: logFileURL,
            now: now
        )
    }
}
