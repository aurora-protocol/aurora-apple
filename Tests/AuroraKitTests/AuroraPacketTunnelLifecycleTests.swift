import Foundation
import XCTest
@testable import AuroraKit

final class AuroraPacketTunnelLifecycleTests: XCTestCase {
    func testPacketTunnelLifecycleRejectsStartupSuccessAfterStop() {
        let lifecycle = AuroraPacketTunnelLifecycle()
        let generation = lifecycle.beginStartup()

        lifecycle.requestStop()

        XCTAssertFalse(lifecycle.completeStartup(generation, delivering: {}))
        XCTAssertFalse(lifecycle.claimTerminalFailure(generation, delivering: {}))
    }

    func testPacketTunnelLifecycleSuppressesFailuresAfterIntentionalStop() {
        let lifecycle = AuroraPacketTunnelLifecycle()
        let generation = lifecycle.beginStartup()

        XCTAssertTrue(lifecycle.completeStartup(generation, delivering: {}))
        lifecycle.requestStop()
        XCTAssertFalse(lifecycle.claimTerminalFailure(generation, delivering: {}))
    }

    func testPacketTunnelLifecycleRejectsStaleGeneration() {
        let lifecycle = AuroraPacketTunnelLifecycle()
        let staleGeneration = lifecycle.beginStartup()
        let currentGeneration = lifecycle.beginStartup()

        XCTAssertFalse(lifecycle.completeStartup(staleGeneration, delivering: {}))
        XCTAssertTrue(lifecycle.completeStartup(currentGeneration, delivering: {}))
        XCTAssertFalse(lifecycle.claimTerminalFailure(staleGeneration, delivering: {}))
        XCTAssertTrue(lifecycle.claimTerminalFailure(currentGeneration, delivering: {}))
    }

    func testPacketTunnelLifecycleSerializesStopWithStartupDelivery() {
        let lifecycle = AuroraPacketTunnelLifecycle()
        let generation = lifecycle.beginStartup()
        let deliveryEntered = DispatchSemaphore(value: 0)
        let allowDeliveryToReturn = DispatchSemaphore(value: 0)
        let startupFinished = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = lifecycle.completeStartup(generation, delivering: {
                deliveryEntered.signal()
                allowDeliveryToReturn.wait()
            })
            startupFinished.signal()
        }
        XCTAssertEqual(deliveryEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            lifecycle.requestStop()
            stopFinished.signal()
        }
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 0.1), .timedOut)

        allowDeliveryToReturn.signal()
        XCTAssertEqual(startupFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(lifecycle.claimTerminalFailure(generation, delivering: {}))
    }

    func testPacketTunnelLifecycleSerializesStopWithTerminalFailureDelivery() {
        let lifecycle = AuroraPacketTunnelLifecycle()
        let generation = lifecycle.beginStartup()
        XCTAssertTrue(lifecycle.completeStartup(generation, delivering: {}))
        let deliveryEntered = DispatchSemaphore(value: 0)
        let allowDeliveryToReturn = DispatchSemaphore(value: 0)
        let terminalFailureFinished = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = lifecycle.claimTerminalFailure(generation, delivering: {
                deliveryEntered.signal()
                allowDeliveryToReturn.wait()
            })
            terminalFailureFinished.signal()
        }
        XCTAssertEqual(deliveryEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            lifecycle.requestStop()
            stopFinished.signal()
        }
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 0.1), .timedOut)

        allowDeliveryToReturn.signal()
        XCTAssertEqual(terminalFailureFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(lifecycle.claimTerminalFailure(generation, delivering: {}))
    }

    func testPacketTunnelLifecycleRejectsPathObservationAfterStop() {
        let lifecycle = AuroraPacketTunnelLifecycle()
        let generation = lifecycle.beginStartup()
        var activated = false

        lifecycle.requestStop()

        XCTAssertFalse(lifecycle.beginPathObservation(generation, activating: {
            activated = true
        }))
        XCTAssertFalse(activated)
    }

    func testPacketTunnelStartupGateWaitsForSetupQuiescence() async throws {
        let gate = AuroraPacketTunnelStartupGate()
        gate.begin(1)
        let waitFinished = DispatchSemaphore(value: 0)

        Task {
            await gate.waitForQuiescence()
            waitFinished.signal()
        }
        XCTAssertEqual(waitFinished.wait(timeout: .now() + 0.1), .timedOut)

        gate.finish(1)
        XCTAssertEqual(waitFinished.wait(timeout: .now() + 1), .success)
        await gate.waitForQuiescence()
    }

}
