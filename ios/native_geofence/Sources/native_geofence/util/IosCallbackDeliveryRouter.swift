import Foundation

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
        let onAccepted: () -> Void
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
        let accepted = withLock {
            guard !closed else { return false }
            queue.append(Pending(element: element, onAccepted: onAccepted))
            return true
        }
        if accepted {
            processNext()
        }
    }

    /// Permanently rejects new work and drops work that has not started.
    ///
    /// The selected runtime still owns cancellation of an active delivery. Its
    /// eventual completion is ignored because the active token is invalidated
    /// before teardown can synchronously re-enter the router.
    func close() {
        withLock {
            guard !closed else { return }
            closed = true
            queue.removeAll()
            activeToken = nil
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

        let preferredRoute = selectRoute()
        let completion: (Bool) -> Void = { [weak self] _ in
            self?.complete(token: token)
        }
        guard isActive(token: token) else { return }
        var accepted = deliver(preferredRoute, pending.element, completion)
        if !accepted, preferredRoute == .main, isActive(token: token) {
            accepted = deliver(.headless, pending.element, completion)
        }

        if accepted, isOpen {
            pending.onAccepted()
        } else if !accepted {
            complete(token: token)
        }
    }

    private func isActive(token: UUID) -> Bool {
        withLock {
            !closed && activeToken == token
        }
    }

    private var isOpen: Bool {
        withLock { !closed }
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
