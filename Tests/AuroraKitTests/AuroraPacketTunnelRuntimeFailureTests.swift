import Foundation
import XCTest
@testable import AuroraKit

final class AuroraPacketTunnelRuntimeFailureTests: XCTestCase {
    func testPacketTunnelRuntimeReportsPacketPumpFailureAndClosesCore() async throws {
        let packetFlow = MockPacketFlow(
            batches: [
                AuroraPacketFlowBatch(
                    packets: [Data([0x45, 0x00, 0x00, 0x14])],
                    protocolNumbers: [2]
                ),
            ]
        )
        let core = MockPacketTunnelCore(ingestError: AuroraClientError.unavailable)
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
        let termination = await runtime.runUntilStopped()

        let closed = await core.closed
        for _ in 0..<20 {
            if !(await failures.recordedFailures).isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let recordedFailures = await failures.recordedFailures
        XCTAssertEqual(termination, .packetPumpFailed)
        XCTAssertEqual(recordedFailures, [.packetPumpFailed])
        XCTAssertTrue(closed)
    }

    func testPacketTunnelRuntimeReportsOutputPumpFailureOnce() async throws {
        let packetFlow = MockBlockingPacketFlow()
        let core = MockFailingOutputPacketTunnelCore()
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
        let terminationTask = Task {
            await runtime.runUntilStopped()
        }
        for _ in 0..<20 {
            if !(await failures.recordedFailures).isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await packetFlow.finish()

        let termination = await terminationTask.value
        let closed = await core.closed
        let recordedFailures = await failures.recordedFailures
        XCTAssertEqual(termination, .outputPumpFailed)
        XCTAssertEqual(recordedFailures, [.outputPumpFailed])
        XCTAssertTrue(closed)
    }

    func testPacketTunnelRuntimeReportsInboundPacketInjectionFailure() async throws {
        let packetFlow = MockPacketFlow(batches: [
            AuroraPacketFlowBatch(
                packets: [Data([0x45, 0x00, 0x00, 0x14])],
                protocolNumbers: [2]
            ),
        ], writeResult: false)
        let core = MockPacketTunnelCore(outboundPackets: [
            AuroraPacketFlowBatch(
                packets: [Data([0x45, 0x00, 0x00, 0x15])],
                protocolNumbers: [2]
            ),
        ])
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
        let processed = try await runtime.processNextBatch()
        let termination = await runtime.runUntilStopped()

        let closed = await core.closed
        for _ in 0..<20 {
            if !(await failures.recordedFailures).isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let recordedFailures = await failures.recordedFailures
        XCTAssertFalse(processed)
        XCTAssertEqual(termination, .packetInjectionFailed)
        XCTAssertEqual(recordedFailures, [.packetInjectionFailed])
        XCTAssertTrue(closed)
    }

    func testPacketTunnelRuntimeReportsNativeOutputPacketInjectionFailure() async throws {
        let packetFlow = MockBlockingPacketFlow(writeResult: false)
        let core = MockStreamingPacketTunnelCore(output: AuroraPacketFlowBatch(
            packets: [Data([0x60, 0x00, 0x00, 0x00])],
            protocolNumbers: [30]
        ))
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
        let terminationTask = Task {
            await runtime.runUntilStopped()
        }
        for _ in 0..<20 {
            if !(await failures.recordedFailures).isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await packetFlow.finish()

        let termination = await terminationTask.value
        let recordedFailures = await failures.recordedFailures
        XCTAssertEqual(termination, .packetInjectionFailed)
        XCTAssertEqual(recordedFailures, [.packetInjectionFailed])
    }

    func testPacketTunnelRuntimeDoesNotInjectPacketsAfterStopDuringPacketRead() async throws {
        let packetFlow = MockBlockingPacketFlow()
        let core = MockPacketTunnelCore(outboundPackets: [
            AuroraPacketFlowBatch(
                packets: [Data([0x45, 0x00, 0x00, 0x15])],
                protocolNumbers: [2]
            ),
        ])
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        try await runtime.start()
        let terminationTask = Task {
            await runtime.runUntilStopped()
        }
        for _ in 0..<20 {
            if await packetFlow.hasPendingRead {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await runtime.stop()
        await packetFlow.resume(AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [2]
        ))

        let termination = await terminationTask.value
        let ingestedPackets = await core.ingestedPackets
        let writtenBatches = await packetFlow.writtenBatches
        XCTAssertEqual(termination, .stopped)
        XCTAssertTrue(ingestedPackets.isEmpty)
        XCTAssertTrue(writtenBatches.isEmpty)
    }

    func testPacketTunnelRuntimeDoesNotInjectNativeOutputAfterStopDuringRead() async throws {
        let packetFlow = MockPacketFlow(batches: [])
        let core = MockBlockingOutputPacketTunnelCore()
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
        await runtime.stop()
        await core.resumeOutbound(AuroraPacketFlowBatch(
            packets: [Data([0x60, 0x00, 0x00, 0x00])],
            protocolNumbers: [30]
        ))
        try await Task.sleep(nanoseconds: 20_000_000)

        let writtenBatches = await packetFlow.writtenBatches
        XCTAssertTrue(writtenBatches.isEmpty)
    }

    func testPacketTunnelRuntimeDrainsInboundWriteBeforeStopCompletes() async throws {
        let packetFlow = MockBlockingWritePacketFlow(batches: [
            AuroraPacketFlowBatch(
                packets: [Data([0x45, 0x00, 0x00, 0x14])],
                protocolNumbers: [2]
            ),
        ])
        let core = MockPacketTunnelCore(outboundPackets: [
            AuroraPacketFlowBatch(
                packets: [Data([0x45, 0x00, 0x00, 0x15])],
                protocolNumbers: [2]
            ),
        ])
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        try await runtime.start()
        let processingTask = Task {
            try await runtime.processNextBatch()
        }
        for _ in 0..<20 {
            if await packetFlow.hasPendingWrite {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let stopFinished = DispatchSemaphore(value: 0)
        Task {
            await runtime.stop()
            stopFinished.signal()
        }
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 0.1), .timedOut)

        await packetFlow.resumeWrite(success: true)
        _ = try await processingTask.value
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 1), .success)
        try await Task.sleep(nanoseconds: 20_000_000)

        let writtenBatches = await packetFlow.writtenBatches
        XCTAssertEqual(writtenBatches.map(\.packets), [[Data([0x45, 0x00, 0x00, 0x15])]])
    }

    func testPacketTunnelRuntimeDrainsNativeOutputWriteBeforeStopCompletes() async throws {
        let packetFlow = MockBlockingWritePacketFlow(batches: [])
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
            if await packetFlow.hasPendingWrite {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let stopFinished = DispatchSemaphore(value: 0)
        Task {
            await runtime.stop()
            stopFinished.signal()
        }
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 0.1), .timedOut)

        await packetFlow.resumeWrite(success: true)
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 1), .success)
        try await Task.sleep(nanoseconds: 20_000_000)

        let writtenBatches = await packetFlow.writtenBatches
        XCTAssertEqual(writtenBatches.map(\.protocolNumbers), [[30]])
    }

    func testPacketTunnelRuntimeWaitsForCanceledStartAndClosesEstablishedCore() async throws {
        let packetFlow = MockPacketFlow(batches: [])
        let core = MockBlockingConnectPacketTunnelCore()
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        let startTask = Task { () -> Result<Void, any Error> in
            do {
                try await runtime.start()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        for _ in 0..<20 {
            if await core.hasPendingConnect {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let stopFinished = DispatchSemaphore(value: 0)
        Task {
            await runtime.stop()
            stopFinished.signal()
        }
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 0.1), .timedOut)

        await core.resumeConnect()
        let startResult = await startTask.value
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 1), .success)

        guard case .failure(let error) = startResult else {
            return XCTFail("canceled start unexpectedly succeeded")
        }
        XCTAssertTrue(error is CancellationError)
        let connected = await core.connected
        let establishedCloseCount = await core.establishedCloseCount
        XCTAssertFalse(connected)
        XCTAssertEqual(establishedCloseCount, 1)
    }

    func testPacketTunnelRuntimeDoesNotReportIntentionalStopAsFailure() async throws {
        let packetFlow = MockPacketFlow(batches: [])
        let core = MockPacketTunnelCore()
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
        await runtime.stop()
        let termination = await runtime.runUntilStopped()

        let closed = await core.closed
        let recordedFailures = await failures.recordedFailures
        XCTAssertEqual(termination, .stopped)
        XCTAssertTrue(recordedFailures.isEmpty)
        XCTAssertTrue(closed)
    }

    func testPacketTunnelRuntimeStopReleasesPendingPacketRead() async throws {
        let packetFlow = MockBlockingPacketFlow()
        let core = MockPacketTunnelCore()
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )
        try await runtime.start()
        let terminationResult = MockAsyncResult<AuroraPacketTunnelRuntimeTermination>()
        Task {
            await terminationResult.record(await runtime.runUntilStopped())
        }

        for _ in 0..<20 {
            if await packetFlow.hasPendingRead {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let hasPendingRead = await packetFlow.hasPendingRead
        XCTAssertTrue(hasPendingRead)

        await runtime.stop()

        guard let termination = await terminationResult.wait(timeoutNanoseconds: 1_000_000_000) else {
            await packetFlow.finish()
            return XCTFail("stopping the runtime left the packet read pending")
        }
        let pendingReadReleaseCount = await packetFlow.pendingReadReleaseCount
        XCTAssertEqual(termination, .stopped)
        XCTAssertEqual(pendingReadReleaseCount, 1)
    }

}
