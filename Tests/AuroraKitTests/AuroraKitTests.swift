import XCTest
@testable import AuroraKit

final class AuroraKitTests: XCTestCase {
    func testServerStatusDecodesHealthResponse() throws {
        let data = #"{"ready":true,"issuer":true,"cover":true}"#.data(using: .utf8)!
        let status = try JSONDecoder().decode(AuroraServerStatus.self, from: data)

        XCTAssertTrue(status.ready)
        XCTAssertTrue(status.issuer)
        XCTAssertTrue(status.cover)
        XCTAssertEqual(status.summary, "ready")
    }

    func testRedactorRemovesSensitiveFields() {
        let raw = """
        admission_proof=abcdef hint_secret=123456 token_authenticator=feedface normal=ok
        """

        let redacted = AuroraRedactor.redact(raw)

        XCTAssertFalse(redacted.contains("abcdef"))
        XCTAssertFalse(redacted.contains("123456"))
        XCTAssertFalse(redacted.contains("feedface"))
        XCTAssertTrue(redacted.contains("normal=ok"))
    }

    func testControllerRefreshesStatusThroughInjectedClient() async {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true))
        )

        await controller.refreshStatus()

        let state = await controller.state
        XCTAssertEqual(state, .ready)
    }

    func testControllerUpdatesEndpointFromValidatedUserInput() async {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true))
        )

        let updated = await controller.updateEndpoint("https://aurora.example:9443")
        let endpoint = await controller.configuration.endpoint
        let state = await controller.state

        XCTAssertTrue(updated)
        XCTAssertEqual(endpoint.absoluteString, "https://aurora.example:9443")
        XCTAssertEqual(state, .idle)
    }

    func testControllerRejectsInvalidEndpointInput() async {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true))
        )

        let updated = await controller.updateEndpoint("not a server")
        let endpoint = await controller.configuration.endpoint
        let state = await controller.state

        XCTAssertFalse(updated)
        XCTAssertEqual(endpoint.absoluteString, "http://127.0.0.1:9443")
        XCTAssertEqual(state, .unavailable("invalid server"))
    }

    func testPacketTunnelConfigurationBuildsNetworkExtensionFloor() throws {
        let endpoint = URL(string: "https://relay.example:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))

        XCTAssertEqual(tunnel.tunnelRemoteAddress, "relay.example")
        XCTAssertEqual(tunnel.ipv4Address, "10.77.0.2")
        XCTAssertEqual(tunnel.ipv4SubnetMask, "255.255.255.255")
        XCTAssertEqual(tunnel.mtu, 1280)
        XCTAssertEqual(tunnel.dnsServers, ["100.64.0.1"])
        XCTAssertTrue(tunnel.includeDefaultIPv4Route)
        XCTAssertTrue(tunnel.captureAllDNSDomains)
    }

    func testPacketTunnelConfigurationFallsBackToEndpointStringWhenHostIsMissing() throws {
        let endpoint = URL(string: "http://127.0.0.1:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(
            configuration: AuroraConfiguration(endpoint: endpoint),
            tunnelRemoteAddress: ""
        )

        XCTAssertEqual(tunnel.tunnelRemoteAddress, "127.0.0.1")
    }

    func testProjectBuildsSharedPacketTunnelTargets() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let workflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)

        for target in ["AuroraPacketTunnel_iOS", "AuroraPacketTunnel_macOS"] {
            XCTAssertTrue(project.contains("\(target):"), "project.yml missing \(target)")
            XCTAssertTrue(workflow.contains("-scheme \(target)"), "CI workflow does not build \(target)")
        }
        XCTAssertTrue(project.contains("type: app-extension"))
        XCTAssertTrue(project.contains("com.apple.networkextension.packet-tunnel"))
        XCTAssertTrue(project.contains("SharedNetworkExtension"))
    }
}

private struct MockServerClient: AuroraServerClient {
    var status: AuroraServerStatus

    func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus {
        status
    }
}
