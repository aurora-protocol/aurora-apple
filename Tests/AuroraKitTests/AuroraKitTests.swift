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

    func testTunnelProfileBuildsProviderConfigurationPayload() throws {
        let endpoint = URL(string: "https://relay.example:9443")!
        let profile = AuroraTunnelProfile(
            configuration: AuroraConfiguration(endpoint: endpoint, routePolicy: "adversarial-dpi"),
            providerBundleIdentifier: "org.aurora-protocol.aurora.ios.packet-tunnel"
        )

        XCTAssertEqual(profile.localizedDescription, "Aurora")
        XCTAssertEqual(profile.providerBundleIdentifier, "org.aurora-protocol.aurora.ios.packet-tunnel")
        XCTAssertEqual(profile.serverAddress, "https://relay.example:9443")
        XCTAssertEqual(profile.providerConfiguration["endpoint"], "https://relay.example:9443")
        XCTAssertEqual(profile.providerConfiguration["routePolicy"], "adversarial-dpi")
    }

    func testTunnelProfileParsesProviderConfigurationPayload() throws {
        let configuration = try XCTUnwrap(AuroraTunnelProfile.configuration(from: [
            "endpoint": "https://relay.example:9443",
            "routePolicy": "balanced",
        ]))

        XCTAssertEqual(configuration.endpoint.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(configuration.routePolicy, "balanced")
    }

    func testTunnelProfileRejectsInvalidProviderConfigurationEndpoint() throws {
        XCTAssertNil(AuroraTunnelProfile.configuration(from: [
            "endpoint": "not a server",
            "routePolicy": "balanced",
        ]))
    }

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
        XCTAssertTrue(project.contains("- target: AuroraPacketTunnel_iOS\n        embed: true"))
        XCTAssertTrue(project.contains("- target: AuroraPacketTunnel_macOS\n        embed: true"))
    }

    func testProjectDeclaresPacketTunnelEntitlements() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let entitlementPaths = [
            "Apps/iOS/AuroraIOS.entitlements",
            "Apps/macOS/AuroraMac.entitlements",
            "SharedNetworkExtension/AuroraPacketTunnel-iOS.entitlements",
            "SharedNetworkExtension/AuroraPacketTunnel-macOS.entitlements",
        ]

        for path in entitlementPaths {
            let entitlement = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(entitlement.contains("com.apple.developer.networking.networkextension"), "\(path) missing Network Extension entitlement")
            XCTAssertTrue(entitlement.contains("packet-tunnel-provider"), "\(path) missing packet tunnel entitlement value")
        }
    }
}

private struct MockServerClient: AuroraServerClient {
    var status: AuroraServerStatus

    func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus {
        status
    }
}

private actor MockTunnelManager: AuroraTunnelManager {
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

private actor MockPacketFlow: AuroraPacketFlow {
    private var batches: [AuroraPacketFlowBatch]
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
        writtenBatches.append(batch)
        return true
    }
}

private actor MockPacketTunnelCore: AuroraPacketTunnelCore {
    private var outboundPackets: [AuroraPacketFlowBatch]
    private(set) var connectedEndpoint: String?
    private(set) var ingestedPackets: [Data] = []
    private(set) var pathChanges: [AuroraNetworkPathChange] = []
    private(set) var closed = false

    init(outboundPackets: [AuroraPacketFlowBatch] = []) {
        self.outboundPackets = outboundPackets
    }

    func connect(configuration: AuroraConfiguration) async throws {
        connectedEndpoint = configuration.endpoint.absoluteString
    }

    func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        ingestedPackets.append(contentsOf: batch.packets)
        guard !outboundPackets.isEmpty else {
            return AuroraPacketFlowBatch(packets: [], protocolNumbers: [])
        }
        return outboundPackets.removeFirst()
    }

    func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {
        pathChanges.append(change)
    }

    func close() async {
        closed = true
    }
}
