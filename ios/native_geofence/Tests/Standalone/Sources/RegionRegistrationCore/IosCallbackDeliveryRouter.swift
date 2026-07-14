import Foundation

private final class IosCallbackDeliveryCompletionGate {
    private let lock = NSLock()
    private var accepted: Bool?
    private var completionReceived = false

    func receiveCompletion(_ action: () -> Void) {
        let shouldRun = withLock {
            guard !completionReceived else { return false }
            completionReceived = true
            return accepted == true
        }
        if shouldRun {
            action()
        }
    }

    func resolve(accepted: Bool, _ action: () -> Void) {
        let shouldRun = withLock {
            guard self.accepted == nil else { return false }
            self.accepted = accepted
            return accepted && completionReceived
        }
        if shouldRun {
            action()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

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
    }

    private let lock = NSRecursiveLock()
    private let selectRoute: RouteSelector
    private let deliver: Delivery
    private var queue: [Pending] = []
    private var activeToken: UUID?
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
            onRejected: {}
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
            onRejected: onRejected
        )
    }

    func enqueue(
        _ element: Element,
        shouldAttempt: @escaping () -> Bool,
        onAccepted: @escaping () -> Void,
        onRejected: @escaping () -> Void
    ) {
        let queued = withLock {
            guard !closed else { return false }
            queue.append(
                Pending(
                    element: element,
                    shouldAttempt: shouldAttempt,
                    onAccepted: onAccepted,
                    onRejected: onRejected
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

    /// Permanently rejects new work and drops work that has not started.
    ///
    /// The selected runtime still owns cancellation of an active delivery. Its
    /// eventual completion is ignored because the active token is invalidated
    /// before teardown can synchronously re-enter the router.
    func close() {
        let rejected = withLock { () -> [Pending] in
            guard !closed else { return [] }
            closed = true
            let rejected = queue
            queue.removeAll()
            activeToken = nil
            return rejected
        }
        for pending in rejected {
            pending.onRejected()
        }
    }

    private func processNext() {
        let selected: (Pending, UUID)? = withLock {
            guard !closed, activeToken == nil, !queue.isEmpty else { return nil }
            let token = UUID()
            activeToken = token
            return (queue.removeFirst(), token)
        }
        guard let (pending, token) = selected else { return }
        guard isActive(token: token) else {
            pending.onRejected()
            return
        }
        guard pending.shouldAttempt() else {
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
        let complete: () -> Void = { [weak self] in
            self?.complete(token: token)
        }
        let accepted = deliver(route, pending.element) { _ in
            completionGate.receiveCompletion(complete)
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
