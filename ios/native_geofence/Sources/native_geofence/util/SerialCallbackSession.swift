import Foundation

/// A bounded, single-in-flight callback session. Flutter and UIKit ownership
/// stay in the caller; this type owns only queue ordering and timer authority.
final class SerialCallbackSession<Element> {
    enum CloseReason: Equatable {
        case idle
        case startupTimeout(String)
        case callbackTimeout(String)
        case forced(String)
    }

    typealias Sender = (Element, @escaping () -> Bool) -> Void
    typealias Scheduler = (_ delayMillis: Int, _ work: @escaping () -> Void) -> Void

    private enum TimerKind {
        case startup
        case callback(dispatchId: UUID)
        case idle
    }

    private let lock = NSLock()
    // External actions are serialized separately from state mutation. A
    // recursive lock permits a synchronous sender completion to advance FIFO.
    private let actionLock = NSRecursiveLock()
    private let startupTimeoutMillis: Int
    private let callbackTimeoutMillis: Int
    private let idleGraceMillis: Int
    private let describe: (Element) -> String
    private let schedule: Scheduler
    private let onClose: (CloseReason) -> Void

    private var queue: [Element] = []
    private var sender: Sender?
    private var activeDispatchId: UUID?
    private var startupTimerToken: UUID?
    private var callbackTimerToken: UUID?
    private var idleTimerToken: UUID?
    private var closed = false

    init(
        startupTimeoutMillis: Int,
        callbackTimeoutMillis: Int,
        idleGraceMillis: Int,
        describe: @escaping (Element) -> String,
        schedule: @escaping Scheduler,
        onClose: @escaping (CloseReason) -> Void
    ) {
        precondition(startupTimeoutMillis > 0)
        precondition(callbackTimeoutMillis > 0)
        precondition(idleGraceMillis >= 0)
        self.startupTimeoutMillis = startupTimeoutMillis
        self.callbackTimeoutMillis = callbackTimeoutMillis
        self.idleGraceMillis = idleGraceMillis
        self.describe = describe
        self.schedule = schedule
        self.onClose = onClose
    }

    /// Returns true once an open session owns the element, even if the sender
    /// is still starting. Completion means the sender finished this attempt.
    @discardableResult
    func enqueue(_ element: Element) -> Bool {
        var actions: [() -> Void] = []
        let accepted = withLock {
            guard !closed else { return false }
            idleTimerToken = nil
            queue.append(element)
            if sender == nil {
                scheduleStartupTimerLocked(for: queue[0], actions: &actions)
            } else {
                selectDispatchLocked(actions: &actions)
            }
            return true
        }
        run(actions)
        return accepted
    }

    func markReady(sender: @escaping Sender) {
        var actions: [() -> Void] = []
        withLock {
            guard !closed else { return }
            self.sender = sender
            startupTimerToken = nil
            if queue.isEmpty {
                scheduleIdleTimerLocked(actions: &actions)
            } else {
                selectDispatchLocked(actions: &actions)
            }
        }
        run(actions)
    }

    func forceClose(reason: String) {
        var actions: [() -> Void] = []
        withLock {
            closeLocked(reason: .forced(reason), actions: &actions)
        }
        run(actions)
    }

    private func selectDispatchLocked(actions: inout [() -> Void]) {
        guard !closed,
              activeDispatchId == nil,
              !queue.isEmpty,
              let sender
        else {
            return
        }

        idleTimerToken = nil
        let element = queue.removeFirst()
        let dispatchId = UUID()
        activeDispatchId = dispatchId
        scheduleCallbackTimerLocked(
            for: element,
            dispatchId: dispatchId,
            actions: &actions
        )
        actions.append { [weak self] in
            guard let self,
                  self.isCurrentDispatch(dispatchId)
            else { return }
            sender(element) { [weak self] in
                self?.complete(dispatchId: dispatchId) ?? false
            }
        }
    }

    @discardableResult
    private func complete(dispatchId: UUID) -> Bool {
        var actions: [() -> Void] = []
        let completed = withLock {
            guard !closed, activeDispatchId == dispatchId else { return false }
            activeDispatchId = nil
            callbackTimerToken = nil
            if queue.isEmpty {
                scheduleIdleTimerLocked(actions: &actions)
            } else {
                selectDispatchLocked(actions: &actions)
            }
            return true
        }
        run(actions)
        return completed
    }

    private func scheduleStartupTimerLocked(
        for element: Element,
        actions: inout [() -> Void]
    ) {
        guard startupTimerToken == nil else { return }
        let token = UUID()
        startupTimerToken = token
        let description = describe(element)
        actions.append { [weak self] in
            guard let self else { return }
            self.schedule(self.startupTimeoutMillis) { [weak self] in
                self?.timerFired(
                    kind: .startup,
                    token: token,
                    description: description
                )
            }
        }
    }

    private func scheduleCallbackTimerLocked(
        for element: Element,
        dispatchId: UUID,
        actions: inout [() -> Void]
    ) {
        let token = UUID()
        callbackTimerToken = token
        let description = describe(element)
        actions.append { [weak self] in
            guard let self else { return }
            self.schedule(self.callbackTimeoutMillis) { [weak self] in
                self?.timerFired(
                    kind: .callback(dispatchId: dispatchId),
                    token: token,
                    description: description
                )
            }
        }
    }

    private func scheduleIdleTimerLocked(actions: inout [() -> Void]) {
        guard idleTimerToken == nil else { return }
        let token = UUID()
        idleTimerToken = token
        actions.append { [weak self] in
            guard let self else { return }
            self.schedule(self.idleGraceMillis) { [weak self] in
                self?.timerFired(kind: .idle, token: token, description: "")
            }
        }
    }

    private func timerFired(
        kind: TimerKind,
        token: UUID,
        description: String
    ) {
        var actions: [() -> Void] = []
        withLock {
            guard !closed else { return }
            switch kind {
            case .startup:
                guard startupTimerToken == token,
                      sender == nil,
                      !queue.isEmpty
                else { return }
                closeLocked(
                    reason: .startupTimeout(description),
                    actions: &actions
                )
            case .callback(let dispatchId):
                guard callbackTimerToken == token,
                      activeDispatchId == dispatchId
                else { return }
                closeLocked(
                    reason: .callbackTimeout(description),
                    actions: &actions
                )
            case .idle:
                guard idleTimerToken == token,
                      activeDispatchId == nil,
                      queue.isEmpty
                else { return }
                closeLocked(reason: .idle, actions: &actions)
            }
        }
        run(actions)
    }

    private func closeLocked(
        reason: CloseReason,
        actions: inout [() -> Void]
    ) {
        guard !closed else { return }
        closed = true
        queue.removeAll()
        sender = nil
        activeDispatchId = nil
        startupTimerToken = nil
        callbackTimerToken = nil
        idleTimerToken = nil
        actions.append { [onClose] in onClose(reason) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func isCurrentDispatch(_ dispatchId: UUID) -> Bool {
        withLock {
            !closed && activeDispatchId == dispatchId
        }
    }

    private func run(_ actions: [() -> Void]) {
        actionLock.lock()
        defer { actionLock.unlock() }
        actions.forEach { $0() }
    }
}
