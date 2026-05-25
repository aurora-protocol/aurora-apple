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

    func testRedactorRemovesCredentialAndReplayFields() {
        let raw = """
        access_hint_credential=secret-access replay_nonce=secret-replay bridge_bundle=secret-bundle relay_descriptor=secret-relay normal=ok
        """

        let redacted = AuroraRedactor.redact(raw)

        XCTAssertFalse(redacted.contains("secret-access"))
        XCTAssertFalse(redacted.contains("secret-replay"))
        XCTAssertFalse(redacted.contains("secret-bundle"))
        XCTAssertFalse(redacted.contains("secret-relay"))
        XCTAssertTrue(redacted.contains("normal=ok"))
    }

    func testTokenWalletStoresCredentialsInSecureStoreByRelayBucket() async throws {
        let store = MockSecureCredentialStore()
        let wallet = AuroraTokenWallet(credentialStore: store)
        let entry = AuroraTokenWalletEntry(
            relayBucketID: "bucket-a",
            accessHintCredential: Data("secret-access".utf8),
            admissionProof: Data("secret-proof".utf8),
            tokenAuthenticator: Data("secret-token".utf8),
            hintSecret: Data("secret-hint".utf8),
            bridgeBundle: Data("secret-bridge".utf8),
            relayDescriptor: Data("secret-relay".utf8),
            expiresAtUnix: 1_800_000_000
        )

        try await wallet.store(entry)

        let lastSave = await store.lastSave
        let saved = await store.savedData(service: AuroraTokenWallet.service, account: "relay-bucket:bucket-a")
        XCTAssertEqual(lastSave?.service, AuroraTokenWallet.service)
        XCTAssertEqual(lastSave?.account, "relay-bucket:bucket-a")
        XCTAssertNotNil(saved)
        let loaded = try await wallet.load(relayBucketID: "bucket-a")
        XCTAssertEqual(loaded, entry)
    }

    func testTokenWalletDiagnosticRedactsCredentialMaterial() {
        let entry = AuroraTokenWalletEntry(
            relayBucketID: "bucket-a",
            accessHintCredential: Data("secret-access".utf8),
            admissionProof: Data("secret-proof".utf8),
            tokenAuthenticator: Data("secret-token".utf8),
            hintSecret: Data("secret-hint".utf8),
            bridgeBundle: Data("secret-bridge".utf8),
            relayDescriptor: Data("secret-relay".utf8),
            expiresAtUnix: 1_800_000_000
        )

        let line = entry.redactedDiagnosticLine

        XCTAssertTrue(line.contains("relay_bucket_id=bucket-a"))
        XCTAssertTrue(line.contains("expires_at_unix=1800000000"))
        XCTAssertFalse(line.contains("secret-access"))
        XCTAssertFalse(line.contains("secret-proof"))
        XCTAssertFalse(line.contains("secret-token"))
        XCTAssertFalse(line.contains("secret-hint"))
        XCTAssertFalse(line.contains("secret-bridge"))
        XCTAssertFalse(line.contains("secret-relay"))
    }

    func testTokenWalletDeletesRelayBucketCredential() async throws {
        let store = MockSecureCredentialStore()
        let wallet = AuroraTokenWallet(credentialStore: store)
        let entry = AuroraTokenWalletEntry(
            relayBucketID: "bucket-a",
            accessHintCredential: Data("secret-access".utf8),
            admissionProof: Data("secret-proof".utf8),
            tokenAuthenticator: Data("secret-token".utf8),
            hintSecret: Data("secret-hint".utf8),
            bridgeBundle: nil,
            relayDescriptor: nil,
            expiresAtUnix: nil
        )

        try await wallet.store(entry)
        try await wallet.delete(relayBucketID: "bucket-a")

        let deleted = await store.deletedKeys
        XCTAssertEqual(deleted, [
            MockSecureCredentialStore.Key(service: AuroraTokenWallet.service, account: "relay-bucket:bucket-a"),
        ])
        let loaded = try await wallet.load(relayBucketID: "bucket-a")
        XCTAssertNil(loaded)
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

    func testControllerChecksPacketExchangeThroughInjectedClient() async {
        let packetClient = MockPacketExchangeClient(outboundBatch: AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x15])],
            protocolNumbers: [2]
        ))
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            packetClient: packetClient
        )

        await controller.checkPacketExchange()

        let requestedEndpoint = await packetClient.requestedEndpoint
        let requestedBatch = await packetClient.requestedBatch
        let state = await controller.packetExchangeState
        let exchanged = await controller.lastPacketExchange
        XCTAssertEqual(requestedEndpoint?.absoluteString, "http://127.0.0.1:9443")
        XCTAssertEqual(requestedBatch?.packets, [Data([0x45, 0x00, 0x00, 0x14])])
        XCTAssertEqual(requestedBatch?.protocolNumbers, [2])
        XCTAssertEqual(state, .ready(packetCount: 1))
        XCTAssertEqual(exchanged?.packets, [Data([0x45, 0x00, 0x00, 0x15])])
        XCTAssertEqual(exchanged?.protocolNumbers, [2])
    }

    func testControllerReportsPacketExchangeFailureWithoutChangingServerStatus() async {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            packetClient: MockPacketExchangeClient(error: AuroraClientError.unavailable)
        )

        await controller.refreshStatus()
        await controller.checkPacketExchange()

        let state = await controller.state
        let packetState = await controller.packetExchangeState
        let exchanged = await controller.lastPacketExchange
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(packetState, .unavailable("packet exchange unavailable"))
        XCTAssertNil(exchanged)
    }

    func testControllerRejectingInvalidEndpointClearsPacketExchangeResult() async {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            packetClient: MockPacketExchangeClient(outboundBatch: AuroraPacketFlowBatch(
                packets: [Data([0x45, 0x00, 0x00, 0x15])],
                protocolNumbers: [2]
            ))
        )
        await controller.checkPacketExchange()

        let updated = await controller.updateEndpoint("not a server")

        let packetState = await controller.packetExchangeState
        let exchanged = await controller.lastPacketExchange
        XCTAssertFalse(updated)
        XCTAssertEqual(packetState, .idle)
        XCTAssertNil(exchanged)
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

    func testPacketTunnelConfigurationExcludesIPv4RelayFromDefaultRoute() throws {
        let endpoint = URL(string: "https://203.0.113.7:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))

        XCTAssertEqual(tunnel.excludedIPv4Routes, [
            AuroraIPv4Route(destinationAddress: "203.0.113.7", subnetMask: "255.255.255.255"),
        ])
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

    func testPacketTunnelRuntimeClosesCoreWhenPacketPumpFails() async throws {
        let packetFlow = MockPacketFlow(
            batches: [
                AuroraPacketFlowBatch(
                    packets: [Data([0x45, 0x00, 0x00, 0x14])],
                    protocolNumbers: [2]
                ),
            ]
        )
        let core = MockPacketTunnelCore(ingestError: AuroraClientError.unavailable)
        let runtime = AuroraPacketTunnelRuntime(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            packetFlow: packetFlow,
            core: core
        )

        try await runtime.start()
        await runtime.runUntilStopped()

        let closed = await core.closed
        XCTAssertTrue(closed)
    }

    func testPacketBatchCodecMatchesServerVector() throws {
        let batch = AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [2]
        )

        let encoded = try AuroraPacketBatchCodec.encode(batch)
        let decoded = try AuroraPacketBatchCodec.decode(encoded)

        XCTAssertEqual(encoded.map { String(format: "%02x", $0) }.joined(), "000100020000000445000014")
        XCTAssertEqual(decoded, batch)
    }

    func testServerBackedPacketTunnelCoreExchangesPacketBatchWithServer() async throws {
        let statusClient = MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true))
        let packetClient = MockPacketExchangeClient(outboundBatch: AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x15])],
            protocolNumbers: [2]
        ))
        let core = AuroraServerBackedPacketTunnelCore(
            statusClient: statusClient,
            packetClient: packetClient
        )
        let configuration = AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!)
        let inbound = AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [2]
        )

        try await core.connect(configuration: configuration)
        let outbound = try await core.ingestPacketBatch(inbound)

        let requestedEndpoint = await packetClient.requestedEndpoint
        let requestedBatch = await packetClient.requestedBatch
        XCTAssertEqual(outbound.packets, [Data([0x45, 0x00, 0x00, 0x15])])
        XCTAssertEqual(outbound.protocolNumbers, [2])
        XCTAssertEqual(requestedEndpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(requestedBatch, inbound)
    }

    func testURLSessionServerClientPostsPacketBatchToPrivateCarrierSlot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PacketExchangeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = URLSessionAuroraServerClient(session: session)
        let inbound = AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [2]
        )
        let outbound = AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x15])],
            protocolNumbers: [2]
        )
        PacketExchangeURLProtocol.setResponse(try AuroraPacketBatchCodec.encode(outbound))

        let exchanged = try await client.exchangePacketBatch(
            endpoint: URL(string: "https://relay.example:9443")!,
            batch: inbound
        )

        let request = PacketExchangeURLProtocol.lastRequest
        let body = PacketExchangeURLProtocol.lastBody
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path, "/assets/app.bin")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(body, try AuroraPacketBatchCodec.encode(inbound))
        XCTAssertEqual(exchanged, outbound)
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

    func testControllerConnectTunnelChecksServerPacketExchangeThenInstallsAndStarts() async {
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
            tunnelManager: tunnelManager
        )

        await controller.connectTunnel()

        let packetEndpoint = await packetClient.requestedEndpoint
        let events = await tunnelManager.events
        let state = await controller.state
        let packetState = await controller.packetExchangeState
        let tunnelState = await controller.tunnelState
        XCTAssertEqual(packetEndpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(events, [
            .install(endpoint: "https://relay.example:9443", routePolicy: "balanced"),
            .start,
        ])
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(packetState, .ready(packetCount: 1))
        XCTAssertEqual(tunnelState, .connected)
    }

    func testControllerConnectTunnelStopsBeforeInstallWhenPacketExchangeFails() async {
        let tunnelManager = MockTunnelManager()
        let endpoint = URL(string: "https://relay.example:9443")!
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: endpoint, routePolicy: "balanced"),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            packetClient: MockPacketExchangeClient(error: AuroraClientError.unavailable),
            tunnelManager: tunnelManager
        )

        await controller.connectTunnel()

        let events = await tunnelManager.events
        let state = await controller.state
        let packetState = await controller.packetExchangeState
        let tunnelState = await controller.tunnelState
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(packetState, .unavailable("packet exchange unavailable"))
        XCTAssertEqual(tunnelState, .disconnected)
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

    func testIOSAppDeclaresCompleteOrientationSet() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let info = try String(contentsOf: root.appendingPathComponent("Apps/iOS/Info.plist"), encoding: .utf8)

        for orientation in [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ] {
            XCTAssertTrue(project.contains(orientation), "project.yml missing \(orientation)")
            XCTAssertTrue(info.contains(orientation), "iOS Info.plist missing \(orientation)")
        }
    }
}

private struct MockServerClient: AuroraServerClient {
    var status: AuroraServerStatus

    func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus {
        status
    }
}

private actor MockSecureCredentialStore: AuroraSecureCredentialStore {
    struct Key: Hashable {
        var service: String
        var account: String
    }

    private var entries: [Key: Data] = [:]
    private(set) var lastSave: Key?
    private(set) var deletedKeys: [Key] = []

    func save(_ data: Data, service: String, account: String) async throws {
        let key = Key(service: service, account: account)
        entries[key] = data
        lastSave = key
    }

    func load(service: String, account: String) async throws -> Data? {
        entries[Key(service: service, account: account)]
    }

    func delete(service: String, account: String) async throws {
        let key = Key(service: service, account: account)
        entries.removeValue(forKey: key)
        deletedKeys.append(key)
    }

    func savedData(service: String, account: String) -> Data? {
        entries[Key(service: service, account: account)]
    }
}

private actor MockPacketExchangeClient: AuroraPacketExchangeClient {
    private let outboundBatch: AuroraPacketFlowBatch?
    private let error: (any Error)?
    private(set) var requestedEndpoint: URL?
    private(set) var requestedBatch: AuroraPacketFlowBatch?

    init(outboundBatch: AuroraPacketFlowBatch) {
        self.outboundBatch = outboundBatch
        self.error = nil
    }

    init(error: any Error) {
        self.outboundBatch = nil
        self.error = error
    }

    func exchangePacketBatch(endpoint: URL, batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        requestedEndpoint = endpoint
        requestedBatch = batch
        if let error {
            throw error
        }
        return outboundBatch ?? AuroraPacketFlowBatch(packets: [], protocolNumbers: [])
    }
}

private final class PacketExchangeURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        var response = Data()
        var lastRequest: URLRequest?
        var lastBody: Data?

        func setResponse(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            response = data
            lastRequest = nil
            lastBody = nil
        }

        func record(request: URLRequest, body: Data?) -> Data {
            lock.lock()
            defer { lock.unlock() }
            lastRequest = request
            lastBody = body
            return response
        }

        func request() -> URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return lastRequest
        }

        func body() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return lastBody
        }
    }

    private static let state = State()

    static var lastRequest: URLRequest? {
        state.request()
    }

    static var lastBody: Data? {
        state.body()
    }

    static func setResponse(_ data: Data) {
        state.setResponse(data)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        let responseBody = Self.state.record(request: request, body: body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/octet-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
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
    private let ingestError: (any Error)?
    private(set) var connectedEndpoint: String?
    private(set) var ingestedPackets: [Data] = []
    private(set) var pathChanges: [AuroraNetworkPathChange] = []
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

    func close() async {
        closed = true
    }
}
