import Foundation
import XCTest
@testable import AuroraKit

actor MockTunnelManager: AuroraTunnelManager {
    enum Event: Equatable {
        case install(endpoint: String, routePolicy: String)
        case start
        case stop
    }

    private(set) var events: [Event] = []

    func install(configuration: AuroraConfiguration) async throws {
        events.append(.install(
            endpoint: configuration.endpoint.absoluteString,
            routePolicy: configuration.routePolicy
        ))
    }

    func start() async throws {
        events.append(.start)
    }

    func stop() async {
        events.append(.stop)
    }

    func status() async -> AuroraTunnelConnectionStatus {
        .disconnected
    }
}

actor MockPacketFlow: AuroraPacketFlow {
    private var batches: [AuroraPacketFlowBatch]
    private let writeResult: Bool
    private(set) var writtenBatches: [AuroraPacketFlowBatch] = []

    init(batches: [AuroraPacketFlowBatch], writeResult: Bool = true) {
        self.batches = batches
        self.writeResult = writeResult
    }

    func readPacketBatch() async -> AuroraPacketFlowBatch? {
        guard !batches.isEmpty else {
            return nil
        }
        return batches.removeFirst()
    }

    func writePacketBatch(_ batch: AuroraPacketFlowBatch) async -> Bool {
        writtenBatches.append(batch)
        return writeResult
    }
}

actor MockBlockingPacketFlow: AuroraPacketFlow {
    private var continuation: CheckedContinuation<AuroraPacketFlowBatch?, Never>?
    private let writeResult: Bool
    private(set) var writtenBatches: [AuroraPacketFlowBatch] = []
    private(set) var pendingReadReleaseCount = 0

    init(writeResult: Bool = true) {
        self.writeResult = writeResult
    }

    func readPacketBatch() async -> AuroraPacketFlowBatch? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func writePacketBatch(_ batch: AuroraPacketFlowBatch) async -> Bool {
        writtenBatches.append(batch)
        return writeResult
    }

    func releasePendingRead() async {
        guard continuation != nil else {
            return
        }
        pendingReadReleaseCount += 1
        resume(nil)
    }

    func finish() {
        resume(nil)
    }

    func resume(_ batch: AuroraPacketFlowBatch?) {
        continuation?.resume(returning: batch)
        continuation = nil
    }

    var hasPendingRead: Bool {
        continuation != nil
    }
}

actor MockBlockingWritePacketFlow: AuroraPacketFlow {
    private var batches: [AuroraPacketFlowBatch]
    private var pendingWrite: AuroraPacketFlowBatch?
    private var writeContinuation: CheckedContinuation<Bool, Never>?
    private(set) var writtenBatches: [AuroraPacketFlowBatch] = []

    init(batches: [AuroraPacketFlowBatch]) {
        self.batches = batches
    }

    func readPacketBatch() async -> AuroraPacketFlowBatch? {
        guard !batches.isEmpty else {
            return nil
        }
        return batches.removeFirst()
    }

    func writePacketBatch(_ batch: AuroraPacketFlowBatch) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingWrite = batch
            writeContinuation = continuation
        }
    }

    var hasPendingWrite: Bool {
        writeContinuation != nil
    }

    func resumeWrite(success: Bool) {
        if success, let pendingWrite {
            writtenBatches.append(pendingWrite)
        }
        pendingWrite = nil
        writeContinuation?.resume(returning: success)
        writeContinuation = nil
    }
}

actor MockBlockingConnectPacketTunnelCore: AuroraPacketTunnelCore {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var connected = false
    private(set) var establishedCloseCount = 0

    var hasPendingConnect: Bool {
        continuation != nil
    }

    func connect(configuration: AuroraConfiguration) async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        connected = true
    }

    func resumeConnect() {
        continuation?.resume()
        continuation = nil
    }

    func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        AuroraPacketFlowBatch(packets: [], protocolNumbers: [])
    }

    func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {}

    func submitDNSMessage(_ message: AuroraDNSMessage) async throws {}

    func submitSocketEvent(_ event: AuroraSocketEvent) async throws {}

    func close() async {
        if connected {
            establishedCloseCount += 1
        }
        connected = false
    }
}

actor MockTerminationRecorder {
    private(set) var recordedFailures: [AuroraPacketTunnelRuntimeTermination] = []

    func record(_ failure: AuroraPacketTunnelRuntimeTermination) {
        recordedFailures.append(failure)
    }
}

actor MockAsyncOperationRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

actor AsyncOperationGate {
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        guard !released else {
            return
        }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
            let waiters = startedWaiters
            startedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilBlocked() async {
        guard blockedContinuation == nil else {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let continuation = blockedContinuation
        blockedContinuation = nil
        continuation?.resume()
    }
}

final class AsyncOperationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

actor MockAsyncResult<Value: Sendable> {
    private var value: Value?
    private var waiter: CheckedContinuation<Value?, Never>?

    func record(_ value: Value) {
        self.value = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    func wait(timeoutNanoseconds: UInt64) async -> Value? {
        if let value {
            return value
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await self?.expireWaiter()
            }
        }
    }

    private func expireWaiter() {
        waiter?.resume(returning: nil)
        waiter = nil
    }
}

actor MockPacketTunnelCore: AuroraPacketTunnelCore {
    private var outboundPackets: [AuroraPacketFlowBatch]
    private let ingestError: (any Error)?
    private(set) var connectedEndpoint: String?
    private(set) var ingestedPackets: [Data] = []
    private(set) var pathChanges: [AuroraNetworkPathChange] = []
    private(set) var dnsMessages: [AuroraDNSMessage] = []
    private(set) var socketEvents: [AuroraSocketEvent] = []
    private(set) var closed = false

    init(outboundPackets: [AuroraPacketFlowBatch] = [], ingestError: (any Error)? = nil) {
        self.outboundPackets = outboundPackets
        self.ingestError = ingestError
    }

    func connect(configuration: AuroraConfiguration) async throws {
        connectedEndpoint = configuration.endpoint.absoluteString
    }

    func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        if let ingestError {
            throw ingestError
        }
        ingestedPackets.append(contentsOf: batch.packets)
        guard !outboundPackets.isEmpty else {
            return AuroraPacketFlowBatch(packets: [], protocolNumbers: [])
        }
        return outboundPackets.removeFirst()
    }

    func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {
        pathChanges.append(change)
    }

    func submitDNSMessage(_ message: AuroraDNSMessage) async throws {
        dnsMessages.append(message)
    }

    func submitSocketEvent(_ event: AuroraSocketEvent) async throws {
        socketEvents.append(event)
    }

    func close() async {
        closed = true
    }
}

actor MockRecoverablePacketTunnelCore: AuroraPacketTunnelCore, AuroraPacketTunnelRecoverableCore {
    private let failAfterFirstConnect: Bool
    private(set) var connectCount = 0
    private(set) var closeCount = 0

    init(failAfterFirstConnect: Bool = false) {
        self.failAfterFirstConnect = failAfterFirstConnect
    }

    func connect(configuration: AuroraConfiguration) async throws {
        connectCount += 1
        if failAfterFirstConnect, connectCount > 1 {
            throw AuroraNativeTunnelError.unavailable
        }
    }

    func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        AuroraPacketFlowBatch(packets: [], protocolNumbers: [])
    }

    func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {}

    func submitDNSMessage(_ message: AuroraDNSMessage) async throws {}

    func submitSocketEvent(_ event: AuroraSocketEvent) async throws {}

    func close() async {
        closeCount += 1
    }
}

actor MockBlockingRecoverablePacketTunnelCore: AuroraPacketTunnelCore, AuroraPacketTunnelRecoverableCore {
    private var ingressContinuation: CheckedContinuation<AuroraPacketFlowBatch, Never>?
    private(set) var connectCount = 0

    var hasPendingIngress: Bool {
        ingressContinuation != nil
    }

    func connect(configuration: AuroraConfiguration) async throws {
        connectCount += 1
    }

    func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        await withCheckedContinuation { continuation in
            ingressContinuation = continuation
        }
    }

    func resumeIngress(with batch: AuroraPacketFlowBatch) {
        ingressContinuation?.resume(returning: batch)
        ingressContinuation = nil
    }

    func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {}

    func submitDNSMessage(_ message: AuroraDNSMessage) async throws {}

    func submitSocketEvent(_ event: AuroraSocketEvent) async throws {}

    func close() async {}
}

actor MockBlockingRecoverableOutputCore: AuroraPacketTunnelCore, AuroraPacketTunnelOutputCore, AuroraPacketTunnelRecoverableCore {
    private var outboundContinuation: CheckedContinuation<AuroraPacketFlowBatch, Never>?

    var hasPendingOutboundRead: Bool {
        outboundContinuation != nil
    }

    func connect(configuration: AuroraConfiguration) async throws {}

    func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        AuroraPacketFlowBatch(packets: [], protocolNumbers: [])
    }

    func nextOutboundPacketBatch() async throws -> AuroraPacketFlowBatch {
        await withCheckedContinuation { continuation in
            outboundContinuation = continuation
        }
    }

    func resumeOutbound(with batch: AuroraPacketFlowBatch) {
        outboundContinuation?.resume(returning: batch)
        outboundContinuation = nil
    }

    func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {}

    func submitDNSMessage(_ message: AuroraDNSMessage) async throws {}

    func submitSocketEvent(_ event: AuroraSocketEvent) async throws {}

    func close() async {}
}

actor MockStreamingPacketTunnelCore: AuroraPacketTunnelCore, AuroraPacketTunnelOutputCore {
    private let output: AuroraPacketFlowBatch
    private var sentOutput = false

    init(output: AuroraPacketFlowBatch) {
        self.output = output
    }

    func connect(configuration: AuroraConfiguration) async throws {}

    func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        AuroraPacketFlowBatch(packets: [], protocolNumbers: [])
    }

    func nextOutboundPacketBatch() async throws -> AuroraPacketFlowBatch {
        guard !sentOutput else {
            throw AuroraNativeTunnelError.unavailable
        }
        sentOutput = true
        return output
    }

    func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {}

    func submitDNSMessage(_ message: AuroraDNSMessage) async throws {}

    func submitSocketEvent(_ event: AuroraSocketEvent) async throws {}

    func close() async {}
}

actor MockFailingOutputPacketTunnelCore: AuroraPacketTunnelCore, AuroraPacketTunnelOutputCore {
    private(set) var closed = false

    func connect(configuration: AuroraConfiguration) async throws {}

    func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        AuroraPacketFlowBatch(packets: [], protocolNumbers: [])
    }

    func nextOutboundPacketBatch() async throws -> AuroraPacketFlowBatch {
        throw AuroraNativeTunnelError.unavailable
    }

    func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {}

    func submitDNSMessage(_ message: AuroraDNSMessage) async throws {}

    func submitSocketEvent(_ event: AuroraSocketEvent) async throws {}

    func close() async {
        closed = true
    }
}

actor MockBlockingOutputPacketTunnelCore: AuroraPacketTunnelCore, AuroraPacketTunnelOutputCore {
    private var continuation: CheckedContinuation<AuroraPacketFlowBatch, any Error>?

    var hasPendingOutboundRead: Bool {
        continuation != nil
    }

    func connect(configuration: AuroraConfiguration) async throws {}

    func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        AuroraPacketFlowBatch(packets: [], protocolNumbers: [])
    }

    func nextOutboundPacketBatch() async throws -> AuroraPacketFlowBatch {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resumeOutbound(_ batch: AuroraPacketFlowBatch) {
        continuation?.resume(returning: batch)
        continuation = nil
    }

    func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {}

    func submitDNSMessage(_ message: AuroraDNSMessage) async throws {}

    func submitSocketEvent(_ event: AuroraSocketEvent) async throws {}

    func close() async {}
}
