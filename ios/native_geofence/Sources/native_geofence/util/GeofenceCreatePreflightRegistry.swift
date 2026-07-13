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

/// Owns create completions only while their off-main Location Services check is
/// outstanding. Flutter API calls and preflight continuations are serialized on
/// the main thread, so handing an operation off to the registration coordinator
/// is an atomic ownership transfer.
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
        guard let operation = remove(token) else { return nil }
        return { result in
            operation.completion.resolve(result)
        }
    }

    @discardableResult
    func cancel(id: String) -> Bool {
        guard let token = tokensById[id],
              let operation = remove(token)
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
        let operations = tokens.compactMap(remove)
        for operation in operations {
            operation.completion.resolve(
                .failure(makeFailure(.removed(id: operation.id)))
            )
        }
    }

    private func remove(_ token: Token) -> PendingOperation? {
        guard let operation = operationsByToken.removeValue(forKey: token) else {
            return nil
        }
        if tokensById[operation.id] == token {
            tokensById.removeValue(forKey: operation.id)
        }
        return operation
    }
}
