import Foundation

/// Keeps one replaceable delivery route without letting an older attachment
/// detach the route installed by a newer engine.
final class IosReattachableDelivery<Delivery> {
    struct Attachment: Equatable {
        fileprivate let token: UUID
    }

    private let lock = NSLock()
    private var current: (attachment: Attachment, delivery: Delivery)?

    @discardableResult
    func attach(_ delivery: Delivery) -> Attachment {
        let attachment = Attachment(token: UUID())
        withLock {
            current = (attachment, delivery)
        }
        return attachment
    }

    func detach(_ attachment: Attachment) {
        withLock {
            guard current?.attachment == attachment else { return }
            current = nil
        }
    }

    func withCurrent<Result>(_ body: (Delivery) -> Result) -> Result? {
        let delivery = withLock { current?.delivery }
        return delivery.map(body)
    }

    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Owns scoped background-execution leases without exposing UIKit to the
/// delivery state machine. Each acquired token ends its platform task exactly
/// once on completion, explicit cleanup, or expiration.
final class IosCallbackBackgroundLeaseRegistry<Identifier> {
    typealias BeginTask = (@escaping () -> Void) -> Identifier?
    typealias EndTask = (Identifier) -> Void

    private enum LeaseState {
        case starting
        case active(Identifier)
        case expiredBeforeActivation
    }

    private let lock = NSLock()
    private let beginTask: BeginTask
    private let endTask: EndTask
    private var leases: [UUID: LeaseState] = [:]

    init(
        beginTask: @escaping BeginTask,
        endTask: @escaping EndTask
    ) {
        self.beginTask = beginTask
        self.endTask = endTask
    }

    func acquire(onExpired: @escaping () -> Void) -> UUID? {
        let token = UUID()
        withLock {
            leases[token] = .starting
        }
        guard let identifier = beginTask({ [weak self] in
            self?.expire(token: token, onExpired: onExpired)
        }) else {
            withLock {
                _ = leases.removeValue(forKey: token)
            }
            return nil
        }

        let activated = withLock { () -> Bool in
            switch leases[token] {
            case .starting:
                leases[token] = .active(identifier)
                return true
            case .expiredBeforeActivation:
                leases.removeValue(forKey: token)
                return false
            case .active, .none:
                return false
            }
        }
        if !activated {
            endTask(identifier)
        }
        return activated ? token : nil
    }

    func finish(_ token: UUID) {
        guard let identifier = takeActiveIdentifier(token: token) else { return }
        endTask(identifier)
    }

    func finishAll() {
        let identifiers = withLock { () -> [Identifier] in
            let identifiers = leases.values.compactMap { state -> Identifier? in
                guard case .active(let identifier) = state else { return nil }
                return identifier
            }
            leases.removeAll()
            return identifiers
        }
        identifiers.forEach(endTask)
    }

    private func expire(
        token: UUID,
        onExpired: @escaping () -> Void
    ) {
        let expiration = withLock { () -> (Identifier?, Bool) in
            switch leases[token] {
            case .starting:
                leases[token] = .expiredBeforeActivation
                return (nil, true)
            case .active(let identifier):
                leases.removeValue(forKey: token)
                return (identifier, true)
            case .expiredBeforeActivation, .none:
                return (nil, false)
            }
        }
        if let identifier = expiration.0 {
            endTask(identifier)
        }
        if expiration.1 {
            onExpired()
        }
    }

    private func takeActiveIdentifier(token: UUID) -> Identifier? {
        withLock {
            guard case .active(let identifier) = leases.removeValue(forKey: token) else {
                return nil
            }
            return identifier
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class IosCallbackDeliveryCompletionGate {
    private let lock = NSLock()
    private var accepted: Bool?
    private var completionResult: Bool?

    func receiveCompletion(_ succeeded: Bool, _ action: (Bool) -> Void) {
        let result = withLock { () -> Bool? in
            guard completionResult == nil else { return nil }
            completionResult = succeeded
            return accepted == true ? succeeded : nil
        }
        if let result {
            action(result)
        }
    }

    func resolve(accepted: Bool, _ action: (Bool) -> Void) {
        let result = withLock { () -> Bool? in
            guard self.accepted == nil else { return nil }
            self.accepted = accepted
            return accepted ? completionResult : nil
        }
        if let result {
            action(result)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class IosCallbackDeliveryFinalizer {
    private let lock = NSLock()
    private var resolved = false
    private let completion: (Bool) -> Void

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func resolve(_ succeeded: Bool) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        lock.unlock()
        completion(succeeded)
    }
}

/// Serializes delivery across the main and headless Flutter runtimes.
///
/// A route owns an event only when `deliver` returns true. The ownership hook
/// is deliberately separate from completion so callers can publish a dedup
/// baseline after the selected runtime accepts the attempt, while FIFO remains
/// blocked until that attempt completes or times out.
final class IosCallbackDeliveryRouter<Element> {
    enum Route: Equatable {
        case main
        case headless
    }

    typealias RouteSelector = () -> Route
    typealias Delivery = (
        _ route: Route,
        _ element: Element,
        _ completion: @escaping (Bool) -> Void
    ) -> Bool

    private struct Pending {
        let element: Element
        let shouldAttempt: () -> Bool
        let onAccepted: () -> Void
        let onRejected: () -> Void
        let finalizer: IosCallbackDeliveryFinalizer
    }

    private let lock = NSRecursiveLock()
    private let selectRoute: RouteSelector
    private let deliver: Delivery
    private var queue: [Pending] = []
    private var activeToken: UUID?
    private var activePending: Pending?
    private var closed = false

    init(
        selectRoute: @escaping RouteSelector,
        deliver: @escaping Delivery
    ) {
        self.selectRoute = selectRoute
        self.deliver = deliver
    }

    func enqueue(_ element: Element, onAccepted: @escaping () -> Void) {
        enqueue(
            element,
            shouldAttempt: { true },
            onAccepted: onAccepted,
            onRejected: {},
            onCompletion: { _ in }
        )
    }

    func enqueue(
        _ element: Element,
        onAccepted: @escaping () -> Void,
        onRejected: @escaping () -> Void
    ) {
        enqueue(
            element,
            shouldAttempt: { true },
            onAccepted: onAccepted,
            onRejected: onRejected,
            onCompletion: { _ in }
        )
    }

    /// Enqueues a journal-owned event and reports its final Dart outcome. A
    /// route rejection, engine teardown, timeout, or Dart error reports false.
    func enqueue(
        _ element: Element,
        completion: @escaping (Bool) -> Void
    ) {
        enqueue(
            element,
            shouldAttempt: { true },
            onAccepted: {},
            onRejected: {},
            onCompletion: completion
        )
    }

    func enqueue(
        _ element: Element,
        shouldAttempt: @escaping () -> Bool,
        onAccepted: @escaping () -> Void,
        onRejected: @escaping () -> Void,
        onCompletion: @escaping (Bool) -> Void = { _ in }
    ) {
        let queued = withLock {
            guard !closed else { return false }
            queue.append(
                Pending(
                    element: element,
                    shouldAttempt: shouldAttempt,
                    onAccepted: onAccepted,
                    onRejected: onRejected,
                    finalizer: IosCallbackDeliveryFinalizer(
                        completion: onCompletion
                    )
                )
            )
            return true
        }
        if queued {
            processNext()
        } else {
            onRejected()
        }
    }

    /// Permanently rejects new work and fails every unfinished delivery.
    ///
    /// Queued work receives its rejection hook. Active work was already
    /// accepted, so only its final completion is failed. Late runtime results
    /// are ignored after the active token is invalidated.
    func close() {
        let rejected = withLock { () -> (queued: [Pending], active: Pending?) in
            guard !closed else { return ([], nil) }
            closed = true
            let rejected = queue
            queue.removeAll()
            let active = activePending
            activeToken = nil
            activePending = nil
            return (rejected, active)
        }
        rejected.active?.finalizer.resolve(false)
        for pending in rejected.queued {
            pending.onRejected()
            pending.finalizer.resolve(false)
        }
    }

    private func processNext() {
        let selected: (Pending, UUID)? = withLock {
            guard !closed, activeToken == nil, !queue.isEmpty else { return nil }
            let token = UUID()
            activeToken = token
            let pending = queue.removeFirst()
            activePending = pending
            return (pending, token)
        }
        guard let (pending, token) = selected else { return }
        guard isActive(token: token) else {
            pending.onRejected()
            return
        }
        guard pending.shouldAttempt() else {
            pending.onRejected()
            pending.finalizer.resolve(false)
            complete(token: token)
            return
        }

        let preferredRoute = selectRoute()
        var accepted = attemptDelivery(
            route: preferredRoute,
            pending: pending,
            token: token
        )
        if !accepted, preferredRoute == .main, isActive(token: token) {
            accepted = attemptDelivery(
                route: .headless,
                pending: pending,
                token: token
            )
        }

        if !accepted {
            pending.onRejected()
            pending.finalizer.resolve(false)
            complete(token: token)
        }
    }

    private func attemptDelivery(
        route: Route,
        pending: Pending,
        token: UUID
    ) -> Bool {
        guard isActive(token: token) else { return false }
        let completionGate = IosCallbackDeliveryCompletionGate()
        let complete: (Bool) -> Void = { [weak self] succeeded in
            guard let self, self.isActive(token: token) else { return }
            pending.finalizer.resolve(succeeded)
            self.complete(token: token)
        }
        let accepted = deliver(route, pending.element) { succeeded in
            completionGate.receiveCompletion(succeeded, complete)
        }
        let publishAcceptance = accepted && isActive(token: token)
        if publishAcceptance {
            pending.onAccepted()
        }
        completionGate.resolve(accepted: publishAcceptance, complete)
        return publishAcceptance
    }

    private func isActive(token: UUID) -> Bool {
        withLock {
            !closed && activeToken == token
        }
    }

    private func complete(token: UUID) {
        let shouldContinue = withLock {
            guard activeToken == token else { return false }
            activeToken = nil
            activePending = nil
            return true
        }
        if shouldContinue {
            processNext()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
