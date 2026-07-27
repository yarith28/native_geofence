import Foundation
import OSLog

enum IosNativeGeofenceFileLogLevel: String {
    case debug
    case diagnostic
    case info
    case warning
    case error

    var requiresVerbose: Bool {
        self == .debug
    }
}

/// A bounded, app-private native log that is independent of Flutter engine
/// initialization. OSLog remains the live system-log sink; production call
/// sites mirror reliability-relevant messages here for later app export.
final class IosNativeGeofenceLogFileStore {
    static let shared = IosNativeGeofenceLogFileStore()

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let logFileURL: URL
    private let now: () -> Date
    private let timestampFormatter: ISO8601DateFormatter
    private let fallbackLog = Logger(
        subsystem: Constants.PACKAGE_NAME,
        category: "IosNativeGeofenceFileLogger"
    )
    // Two half-size segments keep rotation to an atomic same-directory rename.
    // The public reader concatenates the older archive before the active file.
    private var archiveFileURL: URL {
        logFileURL.appendingPathExtension("previous")
    }

    init(
        userDefaults: UserDefaults = NativeGeofenceUserDefaults.standard(),
        logFileURL: URL = IosNativeGeofenceLogFileStore.defaultLogFileURL(),
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.logFileURL = logFileURL
        self.now = now
        timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
    }

    @discardableResult
    func configure(
        enabled: Bool,
        verbose: Bool,
        maxBytes: Int
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let normalizedMaximumBytes = normalizedMaxBytes(maxBytes)
        try enforceBoundsLocked(maximumBytes: normalizedMaximumBytes)
        userDefaults.set(enabled, forKey: Constants.LOG_FILE_ENABLED_KEY)
        userDefaults.set(verbose, forKey: Constants.LOG_FILE_VERBOSE_KEY)
        userDefaults.set(
            normalizedMaximumBytes,
            forKey: Constants.LOG_FILE_MAX_BYTES_KEY
        )
        _ = userDefaults.synchronize()
        return normalizedMaximumBytes
    }

    @discardableResult
    func append(
        level: IosNativeGeofenceFileLogLevel,
        category: String,
        message: () -> String
    ) -> Bool {
        let observedAt = now()
        lock.lock()
        defer { lock.unlock() }
        guard userDefaults.bool(forKey: Constants.LOG_FILE_ENABLED_KEY) else {
            return false
        }
        guard !level.requiresVerbose || isVerboseLocked() else {
            return false
        }

        do {
            try prepareLogDirectoryLocked()
            let maximumBytes = maxBytesLocked()
            try enforceBoundsLocked(maximumBytes: maximumBytes)
            let segmentBytes = segmentBytesLocked(
                maximumBytes: maximumBytes
            )
            let lineData = recordDataLocked(
                level: level,
                category: category,
                message: message(),
                observedAt: observedAt,
                maximumBytes: segmentBytes
            )
            let activeBytes = try fileSizeLocked(at: logFileURL)
            if activeBytes + lineData.count > segmentBytes {
                try rotateLocked()
            }
            try appendLocked(lineData)
            return true
        } catch {
            fallbackLog.error(
                "Failed to append the iOS native geofence log file: \(error.localizedDescription)"
            )
            return false
        }
    }

    func read() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        var data = Data()
        data.append(try dataLockedIfPresent(at: archiveFileURL))
        data.append(try dataLockedIfPresent(at: logFileURL))
        return String(decoding: data, as: UTF8.self)
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        let hasActive = FileManager.default.fileExists(
            atPath: logFileURL.path
        )
        let hasArchive = FileManager.default.fileExists(
            atPath: archiveFileURL.path
        )
        guard hasActive || hasArchive else {
            return
        }
        _ = try fileSizeLocked(at: logFileURL)
        _ = try fileSizeLocked(at: archiveFileURL)
        try prepareLogDirectoryLocked()
        try Data().write(to: logFileURL, options: .atomic)
        if hasArchive {
            try FileManager.default.removeItem(at: archiveFileURL)
        }
    }

    private func isVerboseLocked() -> Bool {
        guard userDefaults.object(forKey: Constants.LOG_FILE_VERBOSE_KEY) != nil else {
            return Constants.DEFAULT_LOG_FILE_VERBOSE
        }
        return userDefaults.bool(forKey: Constants.LOG_FILE_VERBOSE_KEY)
    }

    private func maxBytesLocked() -> Int {
        let configured = userDefaults.object(
            forKey: Constants.LOG_FILE_MAX_BYTES_KEY
        ) as? NSNumber
        return normalizedMaxBytes(
            configured?.intValue ?? Constants.DEFAULT_LOG_FILE_MAX_BYTES
        )
    }

    private func normalizedMaxBytes(_ maxBytes: Int) -> Int {
        min(
            Constants.MAX_LOG_FILE_MAX_BYTES,
            max(Constants.MIN_LOG_FILE_MAX_BYTES, maxBytes)
        )
    }

    private func segmentBytesLocked(maximumBytes: Int) -> Int {
        maximumBytes / 2
    }

    private func prepareLogDirectoryLocked() throws {
        let directory = logFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resourceValues)
    }

    private func fileSizeLocked(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else {
            throw NSError(
                domain: "\(Constants.PACKAGE_NAME).file_logger",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The native geofence log path is not a regular file: \(url.path)",
                ]
            )
        }
        return size.intValue
    }

    private func appendLocked(_ data: Data) throws {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            try Data().write(to: logFileURL, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: logFileURL)
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func rotateLocked() throws {
        if FileManager.default.fileExists(atPath: archiveFileURL.path) {
            _ = try FileManager.default.replaceItemAt(
                archiveFileURL,
                withItemAt: logFileURL
            )
        } else if FileManager.default.fileExists(atPath: logFileURL.path) {
            try FileManager.default.moveItem(
                at: logFileURL,
                to: archiveFileURL
            )
        }
        try Data().write(to: logFileURL, options: .atomic)
    }

    private func enforceBoundsLocked(
        maximumBytes: Int
    ) throws {
        let segmentBytes = segmentBytesLocked(
            maximumBytes: maximumBytes
        )
        let archiveBytes = try fileSizeLocked(at: archiveFileURL)
        let activeBytes = try fileSizeLocked(at: logFileURL)
        guard archiveBytes > segmentBytes || activeBytes > segmentBytes else {
            return
        }

        var combined = Data()
        combined.reserveCapacity(archiveBytes + activeBytes)
        combined.append(try dataLockedIfPresent(at: archiveFileURL))
        combined.append(try dataLockedIfPresent(at: logFileURL))
        let records = normalizedRecordsLocked(
            from: combined,
            maximumRecordBytes: segmentBytes
        )
        let segments = segmentsLocked(
            retainingNewest: records,
            maximumSegmentBytes: segmentBytes
        )

        try prepareLogDirectoryLocked()
        if !segments.archive.isEmpty {
            try segments.archive.write(
                to: archiveFileURL,
                options: .atomic
            )
        }
        try segments.active.write(to: logFileURL, options: .atomic)
        if segments.archive.isEmpty,
           FileManager.default.fileExists(atPath: archiveFileURL.path)
        {
            try FileManager.default.removeItem(at: archiveFileURL)
        }
    }

    private func dataLockedIfPresent(at url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Data()
        }
        _ = try fileSizeLocked(at: url)
        return try Data(contentsOf: url)
    }

    private func recordDataLocked(
        level: IosNativeGeofenceFileLogLevel,
        category: String,
        message: String,
        observedAt: Date,
        maximumBytes: Int
    ) -> Data {
        let timestamp = timestampFormatter.string(from: observedAt)
        let prefix =
            "\(timestamp) [\(level.rawValue)] \(singleLine(category)): "
        let body = singleLine(message)
        let fullRecord = Data("\(prefix)\(body)\n".utf8)
        guard fullRecord.count > maximumBytes else {
            return fullRecord
        }

        let truncationMarker = Data("… [truncated]\n".utf8)
        let contentBytes = max(0, maximumBytes - truncationMarker.count)
        let prefixData = utf8PrefixData(
            prefix,
            maximumBytes: contentBytes
        )
        let bodyData = utf8PrefixData(
            body,
            maximumBytes: max(0, contentBytes - prefixData.count)
        )
        var bounded = Data()
        bounded.reserveCapacity(maximumBytes)
        bounded.append(prefixData)
        bounded.append(bodyData)
        bounded.append(truncationMarker)
        return bounded
    }

    private func normalizedRecordsLocked(
        from data: Data,
        maximumRecordBytes: Int
    ) -> [Data] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ).map { line in
            let value = singleLine(String(line))
            let fullRecord = Data("\(value)\n".utf8)
            guard fullRecord.count > maximumRecordBytes else {
                return fullRecord
            }
            let marker = Data("… [truncated]\n".utf8)
            var bounded = utf8PrefixData(
                value,
                maximumBytes: max(
                    0,
                    maximumRecordBytes - marker.count
                )
            )
            bounded.append(marker)
            return bounded
        }
    }

    private func segmentsLocked(
        retainingNewest records: [Data],
        maximumSegmentBytes: Int
    ) -> (archive: Data, active: Data) {
        var activeReversed: [Data] = []
        var archiveReversed: [Data] = []
        var activeBytes = 0
        var archiveBytes = 0
        var fillingArchive = false

        for record in records.reversed() {
            if !fillingArchive,
               activeBytes + record.count <= maximumSegmentBytes
            {
                activeReversed.append(record)
                activeBytes += record.count
                continue
            }
            fillingArchive = true
            guard archiveBytes + record.count <= maximumSegmentBytes else {
                break
            }
            archiveReversed.append(record)
            archiveBytes += record.count
        }

        return (
            dataInOriginalOrder(archiveReversed),
            dataInOriginalOrder(activeReversed)
        )
    }

    private func dataInOriginalOrder(_ reversedRecords: [Data]) -> Data {
        var data = Data()
        data.reserveCapacity(
            reversedRecords.reduce(0) { $0 + $1.count }
        )
        for record in reversedRecords.reversed() {
            data.append(record)
        }
        return data
    }

    private func utf8PrefixData(
        _ value: String,
        maximumBytes: Int
    ) -> Data {
        guard maximumBytes > 0 else { return Data() }
        let bytes = Array(value.utf8)
        guard bytes.count > maximumBytes else { return Data(bytes) }

        var end = maximumBytes
        while end > 0, bytes[end] & 0xC0 == 0x80 {
            end -= 1
        }
        return Data(bytes[..<end])
    }

    private func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func defaultLogFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("native_geofence", isDirectory: true)
            .appendingPathComponent(Constants.LOG_FILE_NAME, isDirectory: false)
    }
}

final class IosNativeGeofenceFileLogger {
    private let category: String
    private let store: IosNativeGeofenceLogFileStore

    init(
        category: String,
        store: IosNativeGeofenceLogFileStore = .shared
    ) {
        self.category = category
        self.store = store
    }

    @discardableResult
    func debug(_ message: @autoclosure () -> String) -> Bool {
        store.append(level: .debug, category: category, message: message)
    }

    @discardableResult
    func diagnostic(_ message: @autoclosure () -> String) -> Bool {
        store.append(
            level: .diagnostic,
            category: category,
            message: message
        )
    }

    @discardableResult
    func info(_ message: @autoclosure () -> String) -> Bool {
        store.append(level: .info, category: category, message: message)
    }

    @discardableResult
    func warning(_ message: @autoclosure () -> String) -> Bool {
        store.append(level: .warning, category: category, message: message)
    }

    @discardableResult
    func error(_ message: @autoclosure () -> String) -> Bool {
        store.append(level: .error, category: category, message: message)
    }
}
