import Foundation

struct IosNativeGeofenceDeliveryTrace: Codable, Equatable {
    let sequence: Int64
    let occurredAtMillis: Int64
    let elapsedRealtimeMillis: Int64
    let stage: String
    let outcome: String
    let event: String?
    let geofenceCount: Int?
    let owner: String?
    let reasonCode: String?
}

struct IosNativeGeofenceDeliveryTraceSnapshot: Equatable {
    let entries: [IosNativeGeofenceDeliveryTrace]
    let droppedCount: Int64
}

/// A small, privacy-safe trace that survives background suspension without
/// depending on OSLog collection or writable log files.
final class IosNativeGeofenceDeliveryDiagnostics {
    static let shared = IosNativeGeofenceDeliveryDiagnostics()

    private struct StoredRead {
        let entries: [IosNativeGeofenceDeliveryTrace]
        let corruptEntryCount: Int64
    }

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let traceKey: String
    private let sequenceKey: String
    private let droppedKey: String
    private let maximumEntries: Int
    private let nowMillis: () -> Int64
    private let elapsedRealtimeMillis: () -> Int64
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = NativeGeofenceUserDefaults.standard(),
        traceKey: String = Constants.DIAGNOSTIC_DELIVERY_TRACE_KEY,
        sequenceKey: String = Constants.DIAGNOSTIC_DELIVERY_TRACE_SEQUENCE_KEY,
        droppedKey: String = Constants.DIAGNOSTIC_DELIVERY_TRACE_DROPPED_KEY,
        maximumEntries: Int = 128,
        nowMillis: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        },
        elapsedRealtimeMillis: @escaping () -> Int64 = {
            Int64(ProcessInfo.processInfo.systemUptime * 1000)
        }
    ) {
        precondition(maximumEntries > 0)
        self.userDefaults = userDefaults
        self.traceKey = traceKey
        self.sequenceKey = sequenceKey
        self.droppedKey = droppedKey
        self.maximumEntries = maximumEntries
        self.nowMillis = nowMillis
        self.elapsedRealtimeMillis = elapsedRealtimeMillis
        encoder.outputFormatting = [.sortedKeys]
    }

    @discardableResult
    func record(
        stage: String,
        outcome: String,
        event: String? = nil,
        geofenceCount: Int? = nil,
        owner: String? = nil,
        reasonCode: String? = nil
    ) -> Bool {
        withLock {
            let previous = readStoredLocked()
            let storedSequence = (userDefaults.object(forKey: sequenceKey) as? NSNumber)?
                .int64Value ?? 0
            let previousSequence = previous.entries.map(\.sequence).max() ?? 0
            let sequenceBase = max(storedSequence, previousSequence)
            let nextSequence = sequenceBase == Int64.max
                ? Int64.max
                : sequenceBase + 1
            let entry = IosNativeGeofenceDeliveryTrace(
                sequence: nextSequence,
                occurredAtMillis: nowMillis(),
                elapsedRealtimeMillis: max(0, elapsedRealtimeMillis()),
                stage: code(stage),
                outcome: code(outcome),
                event: codeOrNil(event),
                geofenceCount: geofenceCount.map { max(0, $0) },
                owner: codeOrNil(owner),
                reasonCode: codeOrNil(reasonCode)
            )
            let allEntries = previous.entries + [entry]
            let overflow = max(0, allEntries.count - maximumEntries)
            let retained = Array(allEntries.suffix(maximumEntries))
            let priorDropped = (userDefaults.object(forKey: droppedKey) as? NSNumber)?
                .int64Value ?? 0
            let dropped = priorDropped
                + previous.corruptEntryCount
                + Int64(overflow)
            guard let encoded = try? encoder.encode(retained) else { return false }
            userDefaults.set(encoded, forKey: traceKey)
            userDefaults.set(NSNumber(value: nextSequence), forKey: sequenceKey)
            userDefaults.set(NSNumber(value: dropped), forKey: droppedKey)
            _ = userDefaults.synchronize()
            return userDefaults.data(forKey: traceKey) == encoded
        }
    }

    func snapshot() -> IosNativeGeofenceDeliveryTraceSnapshot {
        withLock {
            let stored = readStoredLocked()
            let dropped = (userDefaults.object(forKey: droppedKey) as? NSNumber)?
                .int64Value ?? 0
            return IosNativeGeofenceDeliveryTraceSnapshot(
                entries: stored.entries,
                droppedCount: dropped + stored.corruptEntryCount
            )
        }
    }

    private func readStoredLocked() -> StoredRead {
        guard let data = userDefaults.data(forKey: traceKey) else {
            return StoredRead(entries: [], corruptEntryCount: 0)
        }
        guard let entries = try? decoder.decode(
            [IosNativeGeofenceDeliveryTrace].self,
            from: data
        ) else {
            return StoredRead(entries: [], corruptEntryCount: 1)
        }
        return StoredRead(entries: entries, corruptEntryCount: 0)
    }

    private func code(_ value: String) -> String {
        codeOrNil(value) ?? "unknown"
    }

    private func codeOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        let scalars = value.lowercased().unicodeScalars.prefix(96).map {
            allowed.contains($0) ? Character(String($0)) : "_"
        }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? nil : sanitized
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
