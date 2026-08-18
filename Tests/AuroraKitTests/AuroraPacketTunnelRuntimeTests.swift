import Foundation
import XCTest
@testable import AuroraKit

final class AuroraPacketTunnelRuntimeTests: XCTestCase {
    func testPacketTunnelRuntimeConnectsAndPumpsPacketBatch() async throws {
        let packetFlow = MockPacketFlow(
            batches: [
                AuroraPacketFlowBatch(
                    packets: [Data([0x45, 0x00, 0x00, 0x14])],
                    protocolNumbers: [2]
                ),
            ]
        )
        let core = MockPacketTunnelCore(outboundPackets: [
            AuroraPacketFlowBatch(
                packets: [Data([0x45, 0x00, 0x00, 0x15])],
                protocolNumbers: [2]
            ),
        ])
        let configuration = AuroraConfiguration(
            endpoint: URL(string: "https://relay.example:9443")!,
            routePolicy: "balanced"
        )
        let runtime = AuroraPacketTunnelRuntime(
            configuration: configuration,
            packetFlow: packetFlow,
            core: core
        )

        try await runtime.start()
        let processed = try await runtime.processNextBatch()

        let connectedEndpoint = await core.connectedEndpoint
        let ingestedPackets = await core.ingestedPackets
        let writtenBatches = await packetFlow.writtenBatches
        XCTAssertTrue(processed)
        XCTAssertEqual(connectedEndpoint, "https://relay.example:9443")
        XCTAssertEqual(ingestedPackets, [Data([0x45, 0x00, 0x00, 0x14])])
        XCTAssertEqual(writtenBatches.map(\.packets), [[Data([0x45, 0x00, 0x00, 0x15])]])
        XCTAssertEqual(writtenBatches.map(\.protocolNumbers), [[2]])
    }

    func testPacketTunnelRuntimeWritesNativeCoreOutputWithoutLocalIngress() async throws {
        let packetFlow = MockPacketFlow(batches: [])
        let core = MockStreamingPacketTunnelCore(output: AuroraPacketFlowBatch(
            packets: [Data([0x60, 0x00, 0x00, 0x00])],
            protocolNumbers: [30]
        ))
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        try await runtime.start()
        await runtime.activatePacketFlow()
        for _ in 0..<20 {
            if !(await packetFlow.writtenBatches).isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let written = await packetFlow.writtenBatches
        await runtime.stop()

        XCTAssertEqual(written.map(\.protocolNumbers), [[30]])
    }

    func testPacketTunnelRuntimeDefersNativeOutputUntilPacketFlowActivation() async throws {
        let packetFlow = MockPacketFlow(batches: [])
        let core = MockStreamingPacketTunnelCore(output: AuroraPacketFlowBatch(
            packets: [Data([0x60, 0x00, 0x00, 0x00])],
            protocolNumbers: [30]
        ))
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        try await runtime.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        let written = await packetFlow.writtenBatches
        await runtime.stop()

        XCTAssertTrue(written.isEmpty)
    }

    func testPacketTunnelRuntimeDropsOutboundBatchWithMismatchedProtocolFamily() async throws {
        let packetFlow = MockPacketFlow(
            batches: [
                AuroraPacketFlowBatch(
                    packets: [Data([0x45, 0x00, 0x00, 0x14])],
                    protocolNumbers: [2]
                ),
            ]
        )
        let core = MockPacketTunnelCore(outboundPackets: [
            AuroraPacketFlowBatch(
                packets: [Data([0x45, 0x00, 0x00, 0x15])],
                protocolNumbers: [30]
            ),
        ])
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        try await runtime.start()
        let processed = try await runtime.processNextBatch()

        let writtenBatches = await packetFlow.writtenBatches
        XCTAssertTrue(processed)
        XCTAssertEqual(writtenBatches, [])
    }

    func testPacketTunnelRuntimeForwardsNetworkPathChangesAndClose() async throws {
        let packetFlow = MockPacketFlow(batches: [])
        let core = MockPacketTunnelCore()
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        await runtime.notifyNetworkPathChange(
            AuroraNetworkPathChange(interface: "wifi", expensive: false, constrained: false)
        )
        await runtime.stop()

        let pathChanges = await core.pathChanges
        let closed = await core.closed
        XCTAssertEqual(pathChanges, [
            AuroraNetworkPathChange(interface: "wifi", expensive: false, constrained: false),
        ])
        XCTAssertTrue(closed)
    }

    func testNetworkPathTransitionTrackerRequestsOnlyActionableChanges() async {
        let tracker = AuroraNetworkPathTransitionTracker()
        let wifi = AuroraNetworkPathChange(interface: "wifi", expensive: false, constrained: false)
        let unavailableWiFi = AuroraNetworkPathChange(
            interface: "wifi",
            expensive: false,
            constrained: false,
            available: false
        )
        let cellular = AuroraNetworkPathChange(interface: "cellular", expensive: true, constrained: false)

        let actions = [
            await tracker.record(wifi),
            await tracker.record(wifi),
            await tracker.record(unavailableWiFi),
            await tracker.record(unavailableWiFi),
            await tracker.record(wifi),
            await tracker.record(cellular),
        ]
        XCTAssertEqual(actions, [.none, .none, .suspend, .none, .recover, .recover])

        await tracker.deferUntilStartupCompletes(.recover)
        let deferredAction = await tracker.takeDeferredAction()
        let clearedAction = await tracker.takeDeferredAction()
        XCTAssertEqual(deferredAction, .recover)
        XCTAssertEqual(clearedAction, .none)
    }

    func testAsyncSerialQueueDrainsOperationsInSubmissionOrder() async {
        let queue = AuroraAsyncSerialQueue()
        let recorder = MockAsyncOperationRecorder()

        await queue.enqueue {
            await recorder.append("first")
        }
        await queue.enqueue {
            await recorder.append("second")
        }
        await queue.waitForQuiescence()

        let values = await recorder.values
        XCTAssertEqual(values, ["first", "second"])
    }

    func testAsyncSerialQueueDrainsLargeBacklogWithinBoundedTime() async {
        let queue = AuroraAsyncSerialQueue()
        let gate = AsyncOperationGate()
        let counter = AsyncOperationCounter()
        let operationCount = 100_000

        await queue.enqueue {
            await gate.wait()
        }
        await gate.waitUntilBlocked()
        for _ in 0..<operationCount {
            await queue.enqueue {
                counter.increment()
            }
        }

        let clock = ContinuousClock()
        let started = clock.now
        await gate.release()
        await queue.waitForQuiescence()
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(counter.value, operationCount)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testPacketTunnelRuntimeSuspendsAndRecoversRecoverableCore() async throws {
        let packetFlow = MockPacketFlow(batches: [])
        let core = MockRecoverablePacketTunnelCore()
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        try await runtime.start()
        let suspended = await runtime.suspendForNetworkPathChange()
        let recovered = try await runtime.reconnectAfterNetworkPathChange()
        let connectCount = await core.connectCount
        let closeCount = await core.closeCount

        XCTAssertTrue(suspended)
        XCTAssertTrue(recovered)
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(closeCount, 1)

        await runtime.stop()
        let finalCloseCount = await core.closeCount
        XCTAssertEqual(finalCloseCount, 2)
    }

    func testPacketTunnelRuntimeLeavesNonRecoverableCoreActiveOnNetworkPathChange() async throws {
        let packetFlow = MockPacketFlow(batches: [])
        let core = MockPacketTunnelCore()
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        try await runtime.start()
        let suspended = await runtime.suspendForNetworkPathChange()
        let recovered = try await runtime.reconnectAfterNetworkPathChange()
        let closed = await core.closed
        XCTAssertFalse(suspended)
        XCTAssertFalse(recovered)
        XCTAssertFalse(closed)

        await runtime.stop()
    }

    func testPacketTunnelRuntimeDropsStaleIngressCompletionDuringNetworkRecovery() async throws {
        let packetFlow = MockPacketFlow(batches: [
            AuroraPacketFlowBatch(
                packets: [Data([0x45, 0x00, 0x00, 0x14])],
                protocolNumbers: [2]
            ),
        ])
        let core = MockBlockingRecoverablePacketTunnelCore()
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        try await runtime.start()
        let processingTask = Task { try await runtime.processNextBatch() }
        for _ in 0..<20 {
            if await core.hasPendingIngress {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let hasPendingIngress = await core.hasPendingIngress
        XCTAssertTrue(hasPendingIngress)

        let suspended = await runtime.suspendForNetworkPathChange()
        await core.resumeIngress(with: AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x15])],
            protocolNumbers: [2]
        ))

        let processed = try await processingTask.value
        let writtenBatches = await packetFlow.writtenBatches
        let recovered = try await runtime.reconnectAfterNetworkPathChange()
        XCTAssertTrue(suspended)
        XCTAssertTrue(processed)
        XCTAssertTrue(writtenBatches.isEmpty)
        XCTAssertTrue(recovered)
        await runtime.stop()
    }

    func testPacketTunnelRuntimeDropsStaleNativeOutputDuringNetworkRecovery() async throws {
        let packetFlow = MockPacketFlow(batches: [])
        let core = MockBlockingRecoverableOutputCore()
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        try await runtime.start()
        await runtime.activatePacketFlow()
        for _ in 0..<20 {
            if await core.hasPendingOutboundRead {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let hasPendingOutboundRead = await core.hasPendingOutboundRead
        XCTAssertTrue(hasPendingOutboundRead)

        let suspended = await runtime.suspendForNetworkPathChange()
        await core.resumeOutbound(with: AuroraPacketFlowBatch(
            packets: [Data([0x60, 0x00, 0x00, 0x00])],
            protocolNumbers: [30]
        ))
        try await Task.sleep(nanoseconds: 20_000_000)

        let writtenBatches = await packetFlow.writtenBatches
        let recovered = try await runtime.reconnectAfterNetworkPathChange()
        XCTAssertTrue(suspended)
        XCTAssertTrue(writtenBatches.isEmpty)
        XCTAssertTrue(recovered)
        await runtime.stop()
    }

    func testPacketTunnelRuntimeReportsFailedNetworkRecoveryOnce() async throws {
        let packetFlow = MockPacketFlow(batches: [])
        let core = MockRecoverablePacketTunnelCore(failAfterFirstConnect: true)
        let failures = MockTerminationRecorder()
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core,
            onTerminalFailure: { failure in
                Task {
                    await failures.record(failure)
                }
            }
        )

        try await runtime.start()
        let suspended = await runtime.suspendForNetworkPathChange()
        XCTAssertTrue(suspended)
        do {
            _ = try await runtime.reconnectAfterNetworkPathChange()
            XCTFail("network recovery unexpectedly succeeded")
        } catch {
            XCTAssertNotNil(error)
        }

        for _ in 0..<20 {
            if !(await failures.recordedFailures).isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let recordedFailures = await failures.recordedFailures
        XCTAssertEqual(recordedFailures, [.networkPathRecoveryFailed])
        await runtime.stop()
    }

    func testPacketTunnelRuntimeForwardsDNSMessagesAndSocketEvents() async throws {
        let packetFlow = MockPacketFlow(batches: [])
        let core = MockPacketTunnelCore()
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )
        var dnsMessage = Data([0x12, 0x34, 0x01, 0x00])
        var socketPayload = Data([0x05, 0x06, 0x07])

        try await runtime.submitDNSMessage(AuroraDNSMessage(flowID: 91, message: dnsMessage))
        try await runtime.submitSocketEvent(AuroraSocketEvent(
            eventType: "connect",
            flowID: 4,
            remoteAddress: "203.0.113.7",
            remotePort: 443,
            payload: socketPayload
        ))
        dnsMessage[0] = 0
        socketPayload[0] = 0

        let dnsMessages = await core.dnsMessages
        let socketEvents = await core.socketEvents
        XCTAssertEqual(dnsMessages, [
            AuroraDNSMessage(flowID: 91, message: Data([0x12, 0x34, 0x01, 0x00])),
        ])
        XCTAssertEqual(socketEvents, [
            AuroraSocketEvent(
                eventType: "connect",
                flowID: 4,
                remoteAddress: "203.0.113.7",
                remotePort: 443,
                payload: Data([0x05, 0x06, 0x07])
            ),
        ])
    }

}
