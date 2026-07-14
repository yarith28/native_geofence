import Foundation

enum IosCallbackRefreshDecision: Equatable {
    case notApplicable
    case refreshRequired
    case unknown
}

/// Public status is conservative because iOS cannot validate persisted Dart
/// callback handles individually. Package equality is reconciliation evidence,
/// not proof that every handle still resolves.
enum IosCallbackRefreshPolicy {
    static func evaluate(
        registrationCount: Int,
        storedPackageFingerprint: String?,
        registrationPackageFingerprints: [String?]? = nil,
        currentPackageFingerprint: String
    ) -> IosCallbackRefreshDecision {
        guard registrationCount > 0 else { return .notApplicable }
        if let registrationPackageFingerprints {
            if registrationPackageFingerprints.contains(where: {
                $0 != nil && $0 != currentPackageFingerprint
            }) {
                return .refreshRequired
            }
            if registrationPackageFingerprints.count == registrationCount,
               registrationPackageFingerprints.allSatisfy({ $0 != nil })
            {
                // Per-registration evidence supersedes the legacy global value.
                // Equality still cannot prove that persisted Dart handles resolve.
                return .unknown
            }
        }
        guard let storedPackageFingerprint else { return .unknown }
        return storedPackageFingerprint == currentPackageFingerprint
            ? .unknown
            : .refreshRequired
    }
}
