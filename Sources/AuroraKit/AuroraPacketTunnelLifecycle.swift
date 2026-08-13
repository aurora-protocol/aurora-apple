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
