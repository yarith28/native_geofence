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
        currentPackageFingerprint: String
    ) -> IosCallbackRefreshDecision {
        guard registrationCount > 0 else { return .notApplicable }
        guard let storedPackageFingerprint else { return .unknown }
        return storedPackageFingerprint == currentPackageFingerprint
            ? .unknown
            : .refreshRequired
    }
}
