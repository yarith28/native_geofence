import Foundation

enum IosGeofenceSynchronizationReason: Equatable {
    case firstRun
    case callbackFingerprintChanged
    case registrationDrift
}

struct IosGeofenceSynchronizationRegistration: Equatable {
    let id: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let triggers: [String]
    let callbackHandle: Int64
    let callbackContext: Int64?
}

struct IosGeofenceSynchronizationInventory {
    let pluginOwnedIds: Set<String>
    let registrations: [IosGeofenceSynchronizationRegistration]
    let inactiveRegistrationIds: Set<String>
    let registrationFingerprint: String?
    let callbackFingerprintCurrent: Bool
}

struct IosGeofenceSynchronizationDecision {
    let reasons: [IosGeofenceSynchronizationReason]
    let desiredRegistrationFingerprint: String
    let desiredCount: Int
    let previousCount: Int

    var requiresSynchronization: Bool {
        !reasons.isEmpty
    }
}

enum IosGeofenceSynchronizationPlanner {
    static func requiresRegistrationPreflight(
        current: [IosGeofenceSynchronizationRegistration],
        desired: [IosGeofenceSynchronizationRegistration]
    ) -> Bool {
        let currentById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return desired.contains { wanted in
            guard let existing = currentById[wanted.id] else { return true }
            return !platformSemanticsMatch(existing, wanted)
        }
    }

    static func decide(
        current: IosGeofenceSynchronizationInventory,
        desired: [IosGeofenceSynchronizationRegistration],
        removeUnlisted: Bool
    ) -> IosGeofenceSynchronizationDecision {
        let desiredById = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        let currentById = current.registrations.reduce(
            into: [String: IosGeofenceSynchronizationRegistration]()
        ) { values, registration in
            values[registration.id] = registration
        }
        let desiredIds = Set(desiredById.keys)
        let missingIds = desiredIds.subtracting(current.pluginOwnedIds)
        let unlistedIds = removeUnlisted
            ? current.pluginOwnedIds.subtracting(desiredIds)
            : []
        let inactiveIds = current.inactiveRegistrationIds.intersection(desiredIds)
        var driftedIds = Set<String>()
        var metadataChangedIds = Set<String>()

        for id in desiredIds {
            guard let wanted = desiredById[id], let existing = currentById[id] else {
                continue
            }
            if !platformSemanticsMatch(existing, wanted) {
                driftedIds.insert(id)
            }
            if existing.callbackHandle != wanted.callbackHandle
                || existing.callbackContext != wanted.callbackContext
            {
                metadataChangedIds.insert(id)
            }
        }

        let desiredFingerprint = desiredRegistrationFingerprint(desired)
        var reasons: [IosGeofenceSynchronizationReason] = []
        if removeUnlisted && current.registrationFingerprint == nil {
            reasons.append(.firstRun)
        }
        if !current.callbackFingerprintCurrent || !metadataChangedIds.isEmpty {
            reasons.append(.callbackFingerprintChanged)
        }
        if (removeUnlisted && current.registrationFingerprint != desiredFingerprint)
            || !missingIds.isEmpty
            || !unlistedIds.isEmpty
            || !driftedIds.isEmpty
            || !inactiveIds.isEmpty
        {
            reasons.append(.registrationDrift)
        }

        return IosGeofenceSynchronizationDecision(
            reasons: reasons,
            desiredRegistrationFingerprint: desiredFingerprint,
            desiredCount: desired.count,
            previousCount: current.pluginOwnedIds.count
        )
    }

    static func desiredRegistrationFingerprint(
        _ desired: [IosGeofenceSynchronizationRegistration]
    ) -> String {
        let registrations = desired.sorted { $0.id < $1.id }.map { value in
            let triggers = value.triggers.sorted()
                .map(jsonString)
                .joined(separator: ",")
            return "{"
                + "\"id\":\(jsonString(value.id)),"
                + "\"latitude\":\(jsonDouble(value.latitude)),"
                + "\"longitude\":\(jsonDouble(value.longitude)),"
                + "\"radiusMeters\":\(jsonDouble(value.radiusMeters)),"
                + "\"triggers\":[\(triggers)],"
                + "\"callbackHandle\":\(value.callbackHandle),"
                + "\"callbackContext\":\(value.callbackContext.map(String.init) ?? "null")"
                + "}"
        }.joined(separator: ",")
        return "{\"version\":1,\"platform\":\"ios\",\"registrations\":[\(registrations)]}"
    }

    private static func platformSemanticsMatch(
        _ current: IosGeofenceSynchronizationRegistration,
        _ desired: IosGeofenceSynchronizationRegistration
    ) -> Bool {
        abs(current.latitude - desired.latitude) <= 0.0000001
            && abs(current.longitude - desired.longitude) <= 0.0000001
            && abs(current.radiusMeters - desired.radiusMeters) <= 0.01
            && Set(current.triggers) == Set(desired.triggers)
    }

    private static func jsonString(_ value: String) -> String {
        var encoded = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: encoded += "\\b"
            case 0x09: encoded += "\\t"
            case 0x0A: encoded += "\\n"
            case 0x0C: encoded += "\\f"
            case 0x0D: encoded += "\\r"
            case 0x22: encoded += "\\\""
            case 0x5C: encoded += "\\\\"
            case 0x00 ... 0x1F:
                encoded += String(format: "\\u%04x", scalar.value)
            default:
                encoded.unicodeScalars.append(scalar)
            }
        }
        encoded += "\""
        return encoded
    }

    /// Mirrors Dart's finite-double JSON spelling, including fixed notation at
    /// exponents -6 through 20 and a lowercase exponent without leading zeroes.
    private static func jsonDouble(_ value: Double) -> String {
        let raw = String(value).lowercased()
        guard let exponentMarker = raw.firstIndex(of: "e") else { return raw }

        let mantissa = String(raw[..<exponentMarker])
        let exponentText = String(raw[raw.index(after: exponentMarker)...])
        guard let exponent = Int(exponentText) else { return raw }
        if exponent >= -6 && exponent < 21 {
            let negative = mantissa.hasPrefix("-")
            let unsignedMantissa = negative ? String(mantissa.dropFirst()) : mantissa
            let digits = unsignedMantissa.replacingOccurrences(of: ".", with: "")
            let decimalPosition = 1 + exponent
            let fixed: String
            if decimalPosition <= 0 {
                fixed = "0." + String(repeating: "0", count: -decimalPosition) + digits
            } else if decimalPosition >= digits.count {
                fixed = digits
                    + String(repeating: "0", count: decimalPosition - digits.count)
                    + ".0"
            } else {
                let split = digits.index(digits.startIndex, offsetBy: decimalPosition)
                fixed = String(digits[..<split]) + "." + String(digits[split...])
            }
            return negative ? "-\(fixed)" : fixed
        }

        let exponentSign = exponent >= 0 ? "+" : "-"
        return "\(mantissa)e\(exponentSign)\(abs(exponent))"
    }
}
