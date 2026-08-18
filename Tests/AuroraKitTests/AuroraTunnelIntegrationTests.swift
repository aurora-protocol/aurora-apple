import Foundation
import XCTest
@testable import AuroraKit

final class AuroraTunnelIntegrationTests: XCTestCase {
    func testControllerInstallsAndStartsTunnelThroughInjectedManager() async {
        let tunnelManager = MockTunnelManager()
        let endpoint = URL(string: "https://relay.example:9443")!
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: endpoint, routePolicy: "balanced"),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            tunnelManager: tunnelManager
        )

        await controller.installTunnel()
        await controller.startTunnel()
        await controller.stopTunnel()

        let events = await tunnelManager.events
        let state = await controller.tunnelState
        XCTAssertEqual(events, [
            .install(endpoint: "https://relay.example:9443", routePolicy: "balanced"),
            .start,
            .stop,
        ])
        XCTAssertEqual(state, .disconnected)
    }

    func testControllerConnectTunnelChecksServerPacketExchangeThenInstallsAndStarts() async {
        let tunnelManager = MockTunnelManager()
        let issued = AuroraIssuedAdmissionToken(
            admissionProof: Data("secret-proof".utf8),
            relayBucketID: Data(repeating: 0x81, count: 16),
            tokenAuthenticator: Data("secret-token".utf8),
            expiryUnix: 1_800_000_000
        )
        let issuerClient = MockIssuerClient(issuedToken: issued)
        let packetClient = MockPacketExchangeClient(outboundBatch: AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [2]
        ))
        let endpoint = URL(string: "https://relay.example:9443")!
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: endpoint, routePolicy: "balanced"),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            packetClient: packetClient,
            issuerClient: issuerClient,
            tokenWallet: AuroraTokenWallet(credentialStore: MockSecureCredentialStore()),
            tunnelManager: tunnelManager
        )

        await controller.connectTunnel()

        let packetEndpoint = await packetClient.requestedEndpoint
        let issuerEndpoint = await issuerClient.requestedEndpoint
        let events = await tunnelManager.events
        let state = await controller.state
        let credentialState = await controller.credentialState
        let packetState = await controller.packetExchangeState
        let tunnelState = await controller.tunnelState
        XCTAssertEqual(issuerEndpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(packetEndpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(events, [
            .install(endpoint: "https://relay.example:9443", routePolicy: "balanced"),
            .start,
        ])
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(credentialState, .ready(relayBucketID: "81818181818181818181818181818181"))
        XCTAssertEqual(packetState, .ready(packetCount: 1))
        XCTAssertEqual(tunnelState, .connected)
    }

    func testControllerConnectsNativeProvisioningWithoutLegacyServerChecks() async throws {
        let credentialStore = MockSecureCredentialStore()
        let provisioningStore = AuroraNativeProvisioningStore(credentialStore: credentialStore, validator: MockNativeProvisioningValidator())
        try await provisioningStore.save(Data(repeating: 0xd2, count: 64))
        let tunnelManager = MockTunnelManager()
        let packetClient = MockPacketExchangeClient(error: AuroraClientError.unavailable)
        let issuerClient = MockIssuerClient(error: AuroraClientError.unavailable)
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            serverClient: FailingServerClient(),
            packetClient: packetClient,
            issuerClient: issuerClient,
            tunnelManager: tunnelManager,
            nativeProvisioningStore: provisioningStore
        )

        await controller.restoreNativeProvisioning()
        await controller.connectTunnel()

        let events = await tunnelManager.events
        let packetEndpoint = await packetClient.requestedEndpoint
        let issuerEndpoint = await issuerClient.requestedEndpoint
        let state = await controller.state
        let credentialState = await controller.credentialState
        let packetState = await controller.packetExchangeState
        let tunnelState = await controller.tunnelState
        XCTAssertEqual(events, [
            .install(endpoint: "https://relay.example:9443", routePolicy: "balanced"),
            .start,
        ])
        XCTAssertNil(packetEndpoint)
        XCTAssertNil(issuerEndpoint)
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(credentialState, .idle)
        XCTAssertEqual(packetState, .idle)
        XCTAssertEqual(tunnelState, .connected)
    }

    func testControllerConnectTunnelStopsBeforePacketExchangeWhenIssuerFails() async {
        let tunnelManager = MockTunnelManager()
        let packetClient = MockPacketExchangeClient(outboundBatch: AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [2]
        ))
        let endpoint = URL(string: "https://relay.example:9443")!
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: endpoint, routePolicy: "balanced"),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            packetClient: packetClient,
            issuerClient: MockIssuerClient(error: AuroraClientError.unavailable),
            tokenWallet: AuroraTokenWallet(credentialStore: MockSecureCredentialStore()),
            tunnelManager: tunnelManager
        )

        await controller.connectTunnel()

        let events = await tunnelManager.events
        let packetEndpoint = await packetClient.requestedEndpoint
        let state = await controller.state
        let credentialState = await controller.credentialState
        let packetState = await controller.packetExchangeState
        let tunnelState = await controller.tunnelState
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(packetEndpoint)
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(credentialState, .unavailable("credential unavailable"))
        XCTAssertEqual(packetState, .idle)
        XCTAssertEqual(tunnelState, .disconnected)
    }

    func testControllerConnectTunnelStopsBeforeInstallWhenPacketExchangeFails() async {
        let tunnelManager = MockTunnelManager()
        let issuerClient = MockIssuerClient(issuedToken: AuroraIssuedAdmissionToken(
            admissionProof: Data("secret-proof".utf8),
            relayBucketID: Data(repeating: 0x81, count: 16),
            tokenAuthenticator: Data("secret-token".utf8),
            expiryUnix: 1_800_000_000
        ))
        let endpoint = URL(string: "https://relay.example:9443")!
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: endpoint, routePolicy: "balanced"),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            packetClient: MockPacketExchangeClient(error: AuroraClientError.unavailable),
            issuerClient: issuerClient,
            tokenWallet: AuroraTokenWallet(credentialStore: MockSecureCredentialStore()),
            tunnelManager: tunnelManager
        )

        await controller.connectTunnel()

        let events = await tunnelManager.events
        let state = await controller.state
        let credentialState = await controller.credentialState
        let packetState = await controller.packetExchangeState
        let tunnelState = await controller.tunnelState
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(credentialState, .ready(relayBucketID: "81818181818181818181818181818181"))
        XCTAssertEqual(packetState, .unavailable("packet exchange unavailable"))
        XCTAssertEqual(tunnelState, .disconnected)
    }

}
