import Foundation

public final class AuroraPacketTunnelLifecycle: @unchecked Sendable {
    private enum State {
        case idle
        case starting(UInt64)
        case started(UInt64)
        case stopping
    }

    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var state: State = .idle

    public init() {}

    public func beginStartup() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        state = .starting(generation)
        return generation
    }

    public func completeStartup(_ expectedGeneration: UInt64, delivering completion: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .starting(expectedGeneration) = state else {
            return false
        }
        state = .started(expectedGeneration)
        completion()
        return true
    }

    public func cancelStartup(_ expectedGeneration: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard case .starting(expectedGeneration) = state else {
            return
        }
        state = .stopping
    }

    public func requestStop(_ stopping: () -> Void = {}) {
        lock.lock()
        defer { lock.unlock() }
        state = .stopping
        stopping()
    }

    public func claimTerminalFailure(_ expectedGeneration: UInt64, delivering cancellation: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .started(expectedGeneration) = state else {
            return false
        }
        state = .stopping
        cancellation()
        return true
    }

    public func beginPathObservation(_ expectedGeneration: UInt64, activating observer: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .starting(expectedGeneration) = state else {
            return false
        }
        observer()
        return true
    }

    public func isStarted(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .started(expectedGeneration) = state else {
            return false
        }
        return true
    }
}

public enum AuroraNetworkPathTransitionAction: Equatable, Sendable {
    case none
    case suspend
    case recover
}

public actor AuroraNetworkPathTransitionTracker {
    private var lastChange: AuroraNetworkPathChange?
    private var deferredAction: AuroraNetworkPathTransitionAction = .none

    public init() {}

    public func record(_ change: AuroraNetworkPathChange) -> AuroraNetworkPathTransitionAction {
        let previous = lastChange
        lastChange = change
        guard let previous else {
            return change.available ? .none : .suspend
        }
        guard previous != change else {
            return .none
        }
        return change.available ? .recover : .suspend
    }

    public func deferUntilStartupCompletes(_ action: AuroraNetworkPathTransitionAction) {
        guard action != .none else {
            return
        }
        deferredAction = action
    }

    public func takeDeferredAction() -> AuroraNetworkPathTransitionAction {
        defer { deferredAction = .none }
        return deferredAction
    }
}

public actor AuroraAsyncSerialQueue {
    private typealias Operation = @Sendable () async -> Void

    private var pendingOperations: [Operation?] = []
    private var nextOperationIndex = 0
    private var isDraining = false
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        pendingOperations.append(operation)
        guard !isDraining else {
            return
        }
        isDraining = true
        Task { [weak self] in
            await self?.drain()
        }
    }

    public func waitForQuiescence() async {
        guard isDraining || nextOperationIndex < pendingOperations.count else {
            return
        }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    private func drain() async {
        while nextOperationIndex < pendingOperations.count {
            guard let operation = pendingOperations[nextOperationIndex] else {
                nextOperationIndex += 1
                continue
            }
            pendingOperations[nextOperationIndex] = nil
            nextOperationIndex += 1
            await operation()
        }
        isDraining = false
        nextOperationIndex = 0
        pendingOperations.removeAll(keepingCapacity: false)
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

public final class AuroraPacketTunnelStartupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UInt64?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func begin(_ generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        activeGeneration = generation
    }

    public func finish(_ generation: UInt64) {
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return
        }
        activeGeneration = nil
        let queuedWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in queuedWaiters {
            waiter.resume()
        }
    }

    public func waitForQuiescence() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard activeGeneration != nil else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
