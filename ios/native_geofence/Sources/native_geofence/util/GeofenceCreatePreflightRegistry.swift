import Foundation

enum GeofenceCreatePreflightFailure: Error, Equatable {
    case duplicateRequest(id: String)
    case removed(id: String)

    var message: String {
        switch self {
        case .duplicateRequest(let id):
            return "A registration for geofence ID=\(id) is already pending."
        case .removed(let id):
            return "Registration for geofence ID=\(id) was cancelled because the geofence was removed."
        }
    }
}

/// Owns create admission while an off-main preflight or its handed-off Core
/// Location registration is outstanding. Completion ownership transfers to the
/// registration coordinator, but the token remains the same-ID duplicate
/// authority until that one-shot completion resolves.
final class GeofenceCreatePreflightRegistry {
    typealias Completion = (Result<Void, any Error>) -> Void
    typealias FailureFactory = (GeofenceCreatePreflightFailure) -> any Error

    struct Token: Hashable {
        fileprivate let sequence: UInt64
    }

    private final class OneShotCompletion {
        private var completion: Completion?

        init(_ completion: @escaping Completion) {
            self.completion = completion
        }

        func resolve(_ result: Result<Void, any Error>) {
            guard let completion else { return }
            self.completion = nil
            completion(result)
        }
    }

    private struct PendingOperation {
        let id: String
        let completion: OneShotCompletion
    }

    private let makeFailure: FailureFactory
    private var nextSequence: UInt64 = 0
    private var operationsByToken: [Token: PendingOperation] = [:]
    private var tokensById: [String: Token] = [:]

    init(
        makeFailure: @escaping FailureFactory = { failure in failure }
    ) {
        self.makeFailure = makeFailure
    }

    /// Registers the first outstanding preflight for an identifier. A second
    /// same-ID request is rejected immediately so asynchronous results cannot
    /// reorder which request reaches the registration coordinator.
    func begin(id: String, completion: @escaping Completion) -> Token? {
        let oneShotCompletion = OneShotCompletion(completion)
        guard tokensById[id] == nil else {
            oneShotCompletion.resolve(
                .failure(makeFailure(.duplicateRequest(id: id)))
            )
            return nil
        }

        nextSequence &+= 1
        let token = Token(sequence: nextSequence)
        operationsByToken[token] = PendingOperation(
            id: id,
            completion: oneShotCompletion
        )
        tokensById[id] = token
        return token
    }

    /// Transfers a still-pending operation to the registration coordinator.
    /// The supplied completion remains one-shot after the transfer.
    @discardableResult
    func takeIfPending(_ token: Token) -> Completion? {
        guard let operation = removePending(token, endAdmission: false) else {
            return nil
        }
        return { [weak self] result in
            self?.endAdmission(token: token, id: operation.id)
            operation.completion.resolve(result)
        }
    }

    @discardableResult
    func cancel(id: String) -> Bool {
        guard let token = tokensById[id],
              let operation = removePending(token, endAdmission: true)
        else {
            return false
        }
        operation.completion.resolve(.failure(makeFailure(.removed(id: id))))
        return true
    }

    func cancelAll() {
        // Stable ordering makes simultaneous cancellation deterministic and
        // keeps completion behavior reproducible in tests and diagnostics.
        let tokens = operationsByToken.keys.sorted { $0.sequence < $1.sequence }
        let operations = tokens.compactMap {
            removePending($0, endAdmission: true)
        }
        for operation in operations {
            operation.completion.resolve(
                .failure(makeFailure(.removed(id: operation.id)))
            )
        }
    }

    private func removePending(
        _ token: Token,
        endAdmission: Bool
    ) -> PendingOperation? {
        guard let operation = operationsByToken.removeValue(forKey: token) else {
            return nil
        }
        if endAdmission {
            self.endAdmission(token: token, id: operation.id)
        }
        return operation
    }

    private func endAdmission(token: Token, id: String) {
        if tokensById[id] == token {
            tokensById.removeValue(forKey: id)
        }
    }
}
