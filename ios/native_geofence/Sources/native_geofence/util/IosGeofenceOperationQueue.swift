import Foundation

/// Coordinates plugin-owned Core Location mutations on the main thread.
///
/// Ordinary create operations may remain outstanding concurrently so an
/// unrelated identifier is never blocked behind Core Location confirmation.
/// Synchronization takes exclusive ownership, while a matching removal may
/// interrupt an outstanding create before a waiting exclusive operation starts.
/// Tokens make every finish callback idempotent and prevent a late callback from
/// releasing a newer owner.
final class IosGeofenceOperationQueue {
    typealias Finish = () -> Void
    typealias Operation = (@escaping Finish) -> Void

    private struct PendingOperation {
        let token: UUID
        let access: Access
        let operation: Operation
    }

    private enum Access {
        case create(id: String)
        case cancellation(id: String?)
        case exclusive
    }

    private struct ActiveConcurrentOperation {
        let id: String?
        let access: Access
    }

    private var pending: [PendingOperation] = []
    private var activeConcurrent: [UUID: ActiveConcurrentOperation] = [:]
    private var activeExclusiveToken: UUID?

    func enqueueConcurrent(
        id: String,
        _ operation: @escaping Operation
    ) {
        let pendingOperation = PendingOperation(
            token: UUID(),
            access: .create(id: id),
            operation: operation
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Admission authority still belongs to the active same-ID create.
            // Let this transition reach its token registry/coordinator now so it
            // is rejected as a duplicate instead of becoming a replacement
            // after an already-waiting exclusive operation.
            if activeExclusiveToken == nil,
               hasActiveCreate(id: id)
            {
                startConcurrent(pendingOperation)
                return
            }
            pending.append(pendingOperation)
            startAvailableOperations()
        }
    }

    /// Enqueues a complete removal transition. If a matching create is active,
    /// the removal runs before a waiting exclusive operation so cancellation,
    /// the ownership snapshot, platform stop, and metadata cleanup stay atomic.
    /// Passing nil represents remove-all and matches every active create.
    func enqueueCancellation(
        id: String?,
        _ operation: @escaping Operation
    ) {
        let pendingOperation = PendingOperation(
            token: UUID(),
            access: .cancellation(id: id),
            operation: operation
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if activeExclusiveToken == nil,
               hasMatchingActiveCreate(id: id)
            {
                startConcurrent(pendingOperation)
                return
            }
            pending.append(pendingOperation)
            startAvailableOperations()
        }
    }

    func enqueueExclusive(_ operation: @escaping Operation) {
        enqueue(access: .exclusive, operation)
    }

    private func enqueue(
        access: Access,
        _ operation: @escaping Operation
    ) {
        let pendingOperation = PendingOperation(
            token: UUID(),
            access: access,
            operation: operation
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pending.append(pendingOperation)
            startAvailableOperations()
        }
    }

    private func startAvailableOperations() {
        guard activeExclusiveToken == nil else { return }

        while let next = pending.first {
            switch next.access {
            case .create, .cancellation:
                pending.removeFirst()
                startConcurrent(next)
            case .exclusive:
                guard activeConcurrent.isEmpty else { return }
                pending.removeFirst()
                activeExclusiveToken = next.token
                start(next)
                return
            }
        }
    }

    private func startConcurrent(_ operation: PendingOperation) {
        let id: String?
        switch operation.access {
        case .create(let value): id = value
        case .cancellation(let value): id = value
        case .exclusive: return
        }
        activeConcurrent[operation.token] = ActiveConcurrentOperation(
            id: id,
            access: operation.access
        )
        start(operation)
    }

    private func start(_ operation: PendingOperation) {
        operation.operation { [weak self] in
            DispatchQueue.main.async {
                self?.finish(token: operation.token)
            }
        }
    }

    private func finish(token: UUID) {
        if activeExclusiveToken == token {
            activeExclusiveToken = nil
            startAvailableOperations()
            return
        }
        guard activeConcurrent.removeValue(forKey: token) != nil else { return }
        startAvailableOperations()
    }

    private func hasMatchingActiveCreate(id: String?) -> Bool {
        activeConcurrent.values.contains { active in
            guard case .create = active.access else { return false }
            return id == nil || active.id == id
        }
    }

    private func hasActiveCreate(id: String) -> Bool {
        hasMatchingActiveCreate(id: id)
    }
}
