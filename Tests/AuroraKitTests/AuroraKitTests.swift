import Foundation
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

    func testKeychainCredentialStoreUsesUpdateBeforeAdd() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AuroraKit/AuroraTokenWallet.swift"), encoding: .utf8)
        let saveRange = try XCTUnwrap(source.range(of: "public func save(_ data: Data, service: String, account: String) async throws {"))
        let loadRange = try XCTUnwrap(source.range(of: "public func load(service: String, account: String) async throws -> Data? {"))
        let save = String(source[saveRange.lowerBound..<loadRange.lowerBound])

        XCTAssertTrue(save.contains("SecItemUpdate"), "Keychain save should update an existing item before attempting an add")
        XCTAssertFalse(save.contains("try await delete"), "Keychain save must not remove existing credentials before replacement succeeds")
    }

    func testKeychainCredentialStoreReplacesExistingValue() async throws {
        let store = AuroraKeychainCredentialStore(accessGroup: nil)
        let service = "org.aurora-protocol.aurora.tests.\(UUID().uuidString)"
        let account = UUID().uuidString

        do {
            try await store.save(Data([0x01]), service: service, account: account)
            try await store.save(Data([0x02]), service: service, account: account)
            let loaded = try await store.load(service: service, account: account)
            XCTAssertEqual(loaded, Data([0x02]))
        } catch {
            try? await store.delete(service: service, account: account)
            throw error
        }

        try await store.delete(service: service, account: account)
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

    func testControllerRequiresFullServerSurfaceBeforeReady() async {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: false))
        )

        await controller.refreshStatus()

        let state = await controller.state
        XCTAssertEqual(state, .unavailable("server unavailable"))
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

    func testControllerPersistsEndpointUpdatesAsSharedPortableProfile() async throws {
        let store = MockPortableProfileStore()
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            profileStore: store
        )

        let updated = await controller.updateEndpoint("https://relay.example:9443")

        let savedProfile = try XCTUnwrap(store.savedProfileText)
        let reparsed = try AuroraPortableProfile.parse(savedProfile)
        XCTAssertTrue(updated)
        XCTAssertEqual(reparsed.endpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(reparsed.localMode, "platform-vpn")
        XCTAssertFalse(savedProfile.contains("admission_proof"))
        XCTAssertFalse(savedProfile.contains("token_authenticator"))
        XCTAssertFalse(savedProfile.contains("hint_secret"))
    }

    func testControllerImportsNativeProvisioningIntoSecureStoreWithoutExportingIt() async throws {
        let credentialStore = MockSecureCredentialStore()
        let provisioningStore = AuroraNativeProvisioningStore(
            credentialStore: credentialStore,
            validator: MockNativeProvisioningValidator()
        )
        let profileStore = MockPortableProfileStore()
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            profileStore: profileStore,
            nativeProvisioningStore: provisioningStore
        )
        let provisioning = Data(repeating: 0xa7, count: 64)

        let imported = await controller.importNativeProvisioning(provisioning)
        let rejected = await controller.importNativeProvisioning(Data())

        let configuration = await controller.configuration
        let hasNativeProvisioning = await controller.hasNativeProvisioning
        let stored = await credentialStore.savedData(
            service: AuroraNativeProvisioningStore.service,
            account: AuroraNativeProvisioningStore.account(identifier: AuroraNativeProvisioningStore.defaultIdentifier)
        )
        let exported = await controller.exportPortableProfile()
        XCTAssertTrue(imported)
        XCTAssertFalse(rejected)
        XCTAssertEqual(configuration.nativeProvisioningIdentifier, AuroraNativeProvisioningStore.defaultIdentifier)
        XCTAssertTrue(hasNativeProvisioning)
        XCTAssertEqual(stored, provisioning)
        XCTAssertFalse(exported.contains("nativeProvisioningIdentifier"))
        XCTAssertFalse(exported.contains(provisioning.base64EncodedString()))
    }

    func testControllerRestoresAndRemovesNativeProvisioning() async throws {
        let credentialStore = MockSecureCredentialStore()
        let provisioningStore = AuroraNativeProvisioningStore(
            credentialStore: credentialStore,
            validator: MockNativeProvisioningValidator()
        )
        let provisioning = Data(repeating: 0xb8, count: 64)
        try await provisioningStore.save(provisioning)
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            nativeProvisioningStore: provisioningStore
        )

        await controller.restoreNativeProvisioning()
        let restored = await controller.configuration.nativeProvisioningIdentifier
        let availableAfterRestore = await controller.hasNativeProvisioning

        await controller.removeNativeProvisioning()
        let removed = await controller.configuration.nativeProvisioningIdentifier
        let availableAfterRemoval = await controller.hasNativeProvisioning
        let stored = try await provisioningStore.load()
        XCTAssertEqual(restored, AuroraNativeProvisioningStore.defaultIdentifier)
        XCTAssertTrue(availableAfterRestore)
        XCTAssertNil(removed)
        XCTAssertFalse(availableAfterRemoval)
        XCTAssertNil(stored)
    }

    func testEndpointValidationRejectsRemotePlainHTTPButAllowsLoopback() {
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "http://relay.example:9443"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "http://203.0.113.7:9443"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "http://127.example.com:9443"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "http://127.0.0.1.example:9443"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "http://127.256.0.1:9443"))
        XCTAssertNotNil(AuroraConfiguration.validatedEndpoint(from: "http://127.0.0.1:9443"))
        XCTAssertNotNil(AuroraConfiguration.validatedEndpoint(from: "http://[::1]:9443"))
        XCTAssertNotNil(AuroraConfiguration.validatedEndpoint(from: "https://relay.example:9443"))
    }

    func testEndpointValidationRequiresOriginOnlyURL() {
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "https://relay.example:9443/private"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "https://relay.example:9443/?debug=true"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "https://relay.example:9443/#fragment"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "https://user@relay.example:9443"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "https://user:pass@relay.example:9443"))
        XCTAssertNotNil(AuroraConfiguration.validatedEndpoint(from: "https://relay.example:9443/"))
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

    func testControllerImportsPortableProfileAndResetsDerivedState() async {
        let packetClient = MockPacketExchangeClient(outboundBatch: AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x15])],
            protocolNumbers: [2]
        ))
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            packetClient: packetClient
        )
        await controller.refreshStatus()
        await controller.checkPacketExchange()

        let imported = await controller.importPortableProfile("""
        [aurora]
        version = "2.0"
        profile = "adversarial-dpi"
        route = "split-2"
        speed = "balanced"

        [local]
        mode = "platform-vpn"
        dns = "through-aurora"

        [methods]
        allow_h2 = true
        allow_h1_ws = true
        allow_h3_ext_dgram = false
        allow_masque = false

        [security]
        require_pq = true
        require_split2_for_adversarial = true
        allow_lab_tokens = false

        [storage]
        replay_cache = "sqlite"

        [x.aurora.apple]
        endpoint = "https://relay.example:9443"
        """)

        let configuration = await controller.configuration
        let state = await controller.state
        let packetState = await controller.packetExchangeState
        let credentialState = await controller.credentialState
        let tunnelState = await controller.tunnelState
        let lastStatus = await controller.lastStatus
        let lastPacketExchange = await controller.lastPacketExchange
        let diagnostic = await controller.redactedDiagnosticLine
        XCTAssertTrue(imported)
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(configuration.routePolicy, "adversarial-dpi")
        XCTAssertNil(lastStatus)
        XCTAssertNil(lastPacketExchange)
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(packetState, .idle)
        XCTAssertEqual(credentialState, .idle)
        XCTAssertEqual(tunnelState, .disconnected)
        XCTAssertTrue(diagnostic.contains("profile_import=ready"))
    }

    func testControllerPersistsImportedPortableProfileAsSanitizedSharedProfile() async throws {
        let store = MockPortableProfileStore()
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            profileStore: store
        )

        let imported = await controller.importPortableProfile("""
        [aurora]
        version = "2.0"
        profile = "adversarial-dpi"
        route = "split-2"
        speed = "balanced"

        [local]
        mode = "platform-vpn"
        dns = "through-aurora"

        [methods]
        allow_h2 = true
        allow_h1_ws = true
        allow_h3_ext_dgram = false
        allow_masque = false

        [security]
        require_pq = true
        require_split2_for_adversarial = true
        allow_lab_tokens = false

        [storage]
        replay_cache = "sqlite"

        [x.aurora.apple]
        endpoint = "https://relay.example:9443"
        admission_proof = "secret-proof"
        token_authenticator = "secret-token"
        hint_secret = "secret-hint"

        [x.aurora.lab]
        replay_nonce = "secret-replay"
        bridge_bundle = "secret-bridge"
        relay_descriptor = "secret-relay"
        """)

        let savedProfile = try XCTUnwrap(store.savedProfileText)
        let reparsed = try AuroraPortableProfile.parse(savedProfile)
        XCTAssertTrue(imported)
        XCTAssertEqual(reparsed.endpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(reparsed.profile, "adversarial-dpi")
        XCTAssertTrue(savedProfile.contains("[aurora]"))
        XCTAssertTrue(savedProfile.contains("[x.aurora.apple]"))
        XCTAssertFalse(savedProfile.contains("secret-proof"))
        XCTAssertFalse(savedProfile.contains("secret-token"))
        XCTAssertFalse(savedProfile.contains("secret-hint"))
        XCTAssertFalse(savedProfile.contains("secret-replay"))
        XCTAssertFalse(savedProfile.contains("secret-bridge"))
        XCTAssertFalse(savedProfile.contains("secret-relay"))
        XCTAssertFalse(savedProfile.contains("admission_proof"))
        XCTAssertFalse(savedProfile.contains("token_authenticator"))
        XCTAssertFalse(savedProfile.contains("hint_secret"))
    }

    func testControllerLoadsStoredPortableProfileAndMigratesSanitizedProfile() async throws {
        let store = MockPortableProfileStore(initialProfileText: """
        [aurora]
        version = "2.0"
        profile = "adversarial-dpi"
        route = "split-2"
        speed = "balanced"

        [local]
        mode = "platform-vpn"
        dns = "through-aurora"

        [methods]
        allow_h2 = true
        allow_h1_ws = true
        allow_h3_ext_dgram = false
        allow_masque = false

        [security]
        require_pq = true
        require_split2_for_adversarial = true
        allow_lab_tokens = false

        [storage]
        replay_cache = "sqlite"

        [x.aurora.apple]
        endpoint = "https://relay.example:9443"
        admission_proof = "secret-proof"
        token_authenticator = "secret-token"
        hint_secret = "secret-hint"

        [x.aurora.lab]
        replay_nonce = "secret-replay"
        bridge_bundle = "secret-bridge"
        relay_descriptor = "secret-relay"
        """)
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            profileStore: store
        )

        let loaded = await controller.loadStoredPortableProfile()
        let configuration = await controller.configuration
        let state = await controller.state
        let migratedProfile = try XCTUnwrap(store.savedProfileText)

        XCTAssertTrue(loaded)
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(configuration.routePolicy, "adversarial-dpi")
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(migratedProfile.contains("secret-proof"))
        XCTAssertFalse(migratedProfile.contains("secret-token"))
        XCTAssertFalse(migratedProfile.contains("secret-hint"))
        XCTAssertFalse(migratedProfile.contains("secret-replay"))
        XCTAssertFalse(migratedProfile.contains("secret-bridge"))
        XCTAssertFalse(migratedProfile.contains("secret-relay"))
    }

    func testControllerRejectsInvalidPortableProfileWithoutChangingConfiguration() async {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true))
        )

        let imported = await controller.importPortableProfile("""
        [security]
        allow_plaintext_tokens = true
        """)
        let configuration = await controller.configuration
        let state = await controller.state

        XCTAssertFalse(imported)
        XCTAssertEqual(configuration.endpoint.absoluteString, "http://127.0.0.1:9443")
        XCTAssertEqual(state, .unavailable("invalid profile"))
    }

    func testControllerExportsPortableProfileWithoutCredentialMaterial() async throws {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(
                endpoint: URL(string: "https://relay.example:9443")!,
                routePolicy: "adversarial-dpi"
            ),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true))
        )

        let exported = await controller.exportPortableProfile(route: "split-2", localMode: "platform-vpn")
        let reparsed = try AuroraPortableProfile.parse(exported)

        XCTAssertTrue(exported.contains("[aurora]"))
        XCTAssertTrue(exported.contains("[x.aurora.apple]"))
        XCTAssertFalse(exported.contains("admission_proof"))
        XCTAssertFalse(exported.contains("token_authenticator"))
        XCTAssertFalse(exported.contains("hint_secret"))
        XCTAssertEqual(reparsed.endpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(reparsed.profile, "adversarial-dpi")
        XCTAssertEqual(reparsed.route, "split-2")
        XCTAssertEqual(reparsed.localMode, "platform-vpn")
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

    func testURLSessionIssuerClientFetchesMetadataAndIssuesAdmissionToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IssuerURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = URLSessionAuroraServerClient(session: session)
        let issuerMetadata = Data(repeating: 0x45, count: 32)
        let issuerMetadataHash = Data(repeating: 0x46, count: 48)
        let admissionProof = makeAdmissionProof(
            relayBucketID: Data(repeating: 0x81, count: 16),
            tokenAuthenticator: Data(repeating: 0x92, count: 256),
            expiryUnix: 1_800_000_000
        )
        let tokenNonce = Data(repeating: 0xa1, count: 32)
        let redemptionContextHash = Data(repeating: 0xb2, count: 48)
        IssuerURLProtocol.setResponses([
            IssuerURLProtocol.Response(
                path: "/assets/app.bin",
                contentType: "application/octet-stream",
                body: CarrierFixture.metadataResponse(metadata: issuerMetadata, hash: issuerMetadataHash)
            ),
            IssuerURLProtocol.Response(
                path: "/assets/app.bin",
                contentType: "application/octet-stream",
                body: CarrierFixture.issueResponse(admissionProof)
            ),
        ])

        let metadata = try await client.fetchIssuerMetadata(endpoint: URL(string: "https://relay.example:9443")!)
        let issued = try await client.issueBlindRSAAdmissionToken(
            endpoint: URL(string: "https://relay.example:9443")!,
            request: AuroraBlindRSAIssueRequest(
                tokenNonce: tokenNonce,
                redemptionContextHash: redemptionContextHash,
                expiryUnix: 1_800_000_000
            )
        )

        let requests = IssuerURLProtocol.recordedRequests
        XCTAssertEqual(metadata.issuerMetadata, issuerMetadata)
        XCTAssertEqual(metadata.issuerMetadataHash, issuerMetadataHash)
        XCTAssertEqual(issued.admissionProof, admissionProof)
        XCTAssertEqual(issued.relayBucketID, Data(repeating: 0x81, count: 16))
        XCTAssertEqual(issued.tokenAuthenticator, Data(repeating: 0x92, count: 256))
        XCTAssertEqual(issued.issuerMetadataHash, issuerMetadataHash)
        XCTAssertEqual(issued.expiryUnix, 1_800_000_000)
        // Issuance rides the cover carrier surface, never a public issuer path.
        XCTAssertEqual(requests.map { $0.request.url?.path }, ["/assets/app.bin", "/assets/app.bin"])
        XCTAssertEqual(requests.map { $0.request.httpMethod }, ["POST", "POST"])
        XCTAssertEqual(
            requests.map { $0.request.value(forHTTPHeaderField: "Content-Type") },
            ["application/octet-stream", "application/octet-stream"]
        )
        // Carrier request type bytes: 0x02 metadata, 0x04 blind-rsa issue.
        XCTAssertEqual(requests[0].body?.first, 0x02)
        let issueBody = try XCTUnwrap(requests[1].body)
        XCTAssertEqual(issueBody.first, 0x04)
        let issuePayload = issueBody.dropFirst()
        XCTAssertEqual(Data(issuePayload.prefix(32)), tokenNonce)
        XCTAssertEqual(Data(issuePayload.dropFirst(32).prefix(48)), redemptionContextHash)
    }

    func testURLSessionIssuerClientSpendsAdmissionToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IssuerURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = URLSessionAuroraServerClient(session: session)
        let admissionProof = Data(repeating: 0x6a, count: 96)
        let spentKey = Data(repeating: 0x7b, count: 48)
        IssuerURLProtocol.setResponses([
            IssuerURLProtocol.Response(
                path: "/assets/app.bin",
                contentType: "application/octet-stream",
                body: CarrierFixture.spendResponse(spentKey)
            ),
        ])

        let returnedSpentKey = try await client.spendAdmissionToken(
            endpoint: URL(string: "https://relay.example:9443")!,
            admissionProof: admissionProof
        )

        let requests = IssuerURLProtocol.recordedRequests
        XCTAssertEqual(returnedSpentKey, spentKey)
        XCTAssertEqual(requests.map { $0.request.url?.path }, ["/assets/app.bin"])
        XCTAssertEqual(requests[0].request.httpMethod, "POST")
        XCTAssertEqual(requests[0].request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        let spendBody = try XCTUnwrap(requests[0].body)
        // Carrier request type 0x06 token spend; payload is the opaque proof.
        XCTAssertEqual(spendBody.first, 0x06)
        XCTAssertEqual(Data(spendBody.dropFirst()), admissionProof)
    }

    func testControllerIssuesAdmissionTokenAndStoresItInWallet() async throws {
        let store = MockSecureCredentialStore()
        let wallet = AuroraTokenWallet(credentialStore: store)
        let issued = AuroraIssuedAdmissionToken(
            admissionProof: Data("secret-proof".utf8),
            relayBucketID: Data(repeating: 0x81, count: 16),
            tokenAuthenticator: Data("secret-token".utf8),
            expiryUnix: 1_800_000_000
        )
        let issuerClient = MockIssuerClient(issuedToken: issued)
        let request = AuroraBlindRSAIssueRequest(
            tokenNonce: Data(repeating: 0xa1, count: 32),
            redemptionContextHash: Data(repeating: 0xb2, count: 48),
            expiryUnix: 1_800_000_000
        )
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            issuerClient: issuerClient,
            tokenWallet: wallet
        )

        await controller.issueAdmissionToken(request: request)

        let state = await controller.credentialState
        let diagnostic = await controller.redactedDiagnosticLine
        let requestedEndpoint = await issuerClient.requestedEndpoint
        let requestedIssue = await issuerClient.requestedIssue
        let saved = try await wallet.load(relayBucketID: Data(repeating: 0x81, count: 16).auroraHexString)
        XCTAssertEqual(state, .ready(relayBucketID: Data(repeating: 0x81, count: 16).auroraHexString))
        XCTAssertEqual(requestedEndpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(requestedIssue, request)
        XCTAssertEqual(saved?.admissionProof, Data("secret-proof".utf8))
        XCTAssertEqual(saved?.tokenAuthenticator, Data("secret-token".utf8))
        XCTAssertEqual(saved?.expiresAtUnix, 1_800_000_000)
        XCTAssertFalse(diagnostic.contains("secret-proof"))
        XCTAssertFalse(diagnostic.contains("secret-token"))
        XCTAssertTrue(diagnostic.contains("relay_bucket_id=81818181818181818181818181818181"))
    }

    func testControllerReportsIssuerFailureWithoutLeakingRequestMaterial() async {
        let issuerClient = MockIssuerClient(error: AuroraClientError.unavailable)
        let request = AuroraBlindRSAIssueRequest(
            tokenNonce: Data(repeating: 0xa1, count: 32),
            redemptionContextHash: Data(repeating: 0xb2, count: 48),
            expiryUnix: 1_800_000_000
        )
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            issuerClient: issuerClient,
            tokenWallet: AuroraTokenWallet(credentialStore: MockSecureCredentialStore())
        )

        await controller.issueAdmissionToken(request: request)

        let state = await controller.credentialState
        let diagnostic = await controller.redactedDiagnosticLine
        XCTAssertEqual(state, .unavailable("credential unavailable"))
        XCTAssertFalse(diagnostic.contains(request.tokenNonce.auroraHexString))
        XCTAssertFalse(diagnostic.contains(request.redemptionContextHash.auroraHexString))
    }

    func testControllerRejectsIssuedTokenBoundToDifferentIssuerMetadata() async throws {
        let store = MockSecureCredentialStore()
        let wallet = AuroraTokenWallet(credentialStore: store)
        let issued = AuroraIssuedAdmissionToken(
            admissionProof: Data("secret-proof".utf8),
            relayBucketID: Data(repeating: 0x81, count: 16),
            tokenAuthenticator: Data("secret-token".utf8),
            issuerMetadataHash: Data(repeating: 0x47, count: 48),
            expiryUnix: 1_800_000_000
        )
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            issuerClient: MockIssuerClient(issuedToken: issued),
            tokenWallet: wallet
        )

        await controller.issueAdmissionToken(request: AuroraBlindRSAIssueRequest(
            tokenNonce: Data(repeating: 0xa1, count: 32),
            redemptionContextHash: Data(repeating: 0xb2, count: 48),
            expiryUnix: 1_800_000_000
        ))

        let state = await controller.credentialState
        let saved = try await wallet.load(relayBucketID: Data(repeating: 0x81, count: 16).auroraHexString)
        XCTAssertEqual(state, .unavailable("credential unavailable"))
        XCTAssertNil(saved)
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
        XCTAssertEqual(tunnel.ipv6Address, "fd77::2")
        XCTAssertEqual(tunnel.ipv6NetworkPrefixLength, 128)
        XCTAssertEqual(tunnel.mtu, 1280)
        XCTAssertEqual(tunnel.dnsServers, ["100.64.0.1", "fd77::1"])
        XCTAssertTrue(tunnel.includeDefaultIPv4Route)
        XCTAssertTrue(tunnel.includeDefaultIPv6Route)
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

    func testPacketTunnelConfigurationExcludesIPv6RelayFromDefaultRoute() throws {
        let endpoint = URL(string: "https://[2001:db8:100::7]:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))

        XCTAssertEqual(tunnel.tunnelRemoteAddress, "2001:db8:100::7")
        XCTAssertEqual(tunnel.excludedIPv6Routes, [
            AuroraIPv6Route(destinationAddress: "2001:db8:100::7", networkPrefixLength: 128),
        ])
    }

    func testPacketTunnelConfigurationAppliesResolvedRelayAddressesBeforeActivation() throws {
        let endpoint = URL(string: "https://relay.example:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))

        let resolved = try tunnel.applyingResolvedRemoteAddresses([
            "2001:db8:100::7",
            "203.0.113.7",
            "203.0.113.7",
        ])

        XCTAssertEqual(resolved.tunnelRemoteAddress, "2001:db8:100::7")
        XCTAssertEqual(resolved.excludedIPv4Routes, [
            AuroraIPv4Route(destinationAddress: "203.0.113.7", subnetMask: "255.255.255.255"),
        ])
        XCTAssertEqual(resolved.excludedIPv6Routes, [
            AuroraIPv6Route(destinationAddress: "2001:db8:100::7", networkPrefixLength: 128),
        ])
        XCTAssertNoThrow(try resolved.validatedForNetworkSettings())
    }

    func testPacketTunnelConfigurationRejectsUnresolvedAndInvalidIPv6Settings() throws {
        let endpoint = URL(string: "https://relay.example:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))
        XCTAssertThrowsError(try tunnel.validatedForNetworkSettings())

        var invalid = try tunnel.applyingResolvedRemoteAddresses(["203.0.113.7"])
        invalid.ipv6NetworkPrefixLength = 129
        XCTAssertThrowsError(try invalid.validatedForNetworkSettings())
    }

    func testTunnelEndpointResolverReturnsNumericLoopbackAddress() async throws {
        let endpoint = URL(string: "https://localhost:9443")!
        let resolver = AuroraTunnelEndpointResolver()
        let resolved = try await resolver.resolve(
            AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))
        )

        XCTAssertNotEqual(resolved.tunnelRemoteAddress, "localhost")
        XCTAssertNoThrow(try resolved.validatedForNetworkSettings())
        XCTAssertFalse(resolved.excludedIPv4Routes.isEmpty && resolved.excludedIPv6Routes.isEmpty)
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

    func testTunnelProfileCarriesOnlyNativeProvisioningKeychainReference() throws {
        let identifier = "production-slot"
        let profile = AuroraTunnelProfile(
            configuration: AuroraConfiguration(
                endpoint: URL(string: "https://relay.example:9443")!,
                nativeProvisioningIdentifier: identifier
            ),
            providerBundleIdentifier: "org.aurora-protocol.aurora.ios.packet-tunnel"
        )

        XCTAssertEqual(profile.providerConfiguration[AuroraTunnelProfile.nativeProvisioningIdentifierKey], identifier)
        XCTAssertFalse(profile.providerConfiguration.values.contains { $0.contains("access_hint") })
        let configuration = try XCTUnwrap(AuroraTunnelProfile.configuration(from: profile.providerConfiguration))
        XCTAssertEqual(configuration.nativeProvisioningIdentifier, identifier)
    }

    func testNativeProvisioningStoreKeepsOpaqueBundleInCredentialStore() async throws {
        let credentialStore = MockSecureCredentialStore()
        let validator = MockNativeProvisioningValidator()
        let store = AuroraNativeProvisioningStore(credentialStore: credentialStore, validator: validator)
        let provisioning = Data(repeating: 0x7a, count: 64)

        try await store.save(provisioning, identifier: "production-slot")

        let loaded = try await store.load(identifier: "production-slot")
        let stored = await credentialStore.savedData(
            service: AuroraNativeProvisioningStore.service,
            account: AuroraNativeProvisioningStore.account(identifier: "production-slot")
        )
        XCTAssertEqual(loaded, provisioning)
        XCTAssertEqual(
            stored,
            provisioning
        )
        let validatedSources = await validator.validatedSources
        XCTAssertEqual(validatedSources, [provisioning])
    }

    func testNativeProvisioningStoreRejectsInvalidSourceBeforeKeychainWrite() async throws {
        let credentialStore = MockSecureCredentialStore()
        let validator = MockNativeProvisioningValidator(error: AuroraNativeTunnelError.invalidProvisioning)
        let store = AuroraNativeProvisioningStore(credentialStore: credentialStore, validator: validator)
        let provisioning = Data(repeating: 0x7b, count: 64)

        do {
            try await store.save(provisioning, identifier: "production-slot")
            XCTFail("invalid provisioning source was saved")
        } catch {
            XCTAssertEqual(error as? AuroraNativeTunnelError, .invalidProvisioning)
        }

        let stored = await credentialStore.savedData(
            service: AuroraNativeProvisioningStore.service,
            account: AuroraNativeProvisioningStore.account(identifier: "production-slot")
        )
        XCTAssertNil(stored)
    }

    func testCoreNativeProvisioningValidatorRejectsMalformedSource() async {
        let validator = AuroraCoreNativeProvisioningValidator()

        do {
            try await validator.validate(source: Data([0x01]), now: Date())
            XCTFail("malformed provisioning source was accepted")
        } catch {
            XCTAssertEqual(error as? AuroraNativeTunnelError, .invalidProvisioning)
        }
    }

    func testNativePacketTunnelCoreUsesOpaqueCoreSessionAndIssuerTransport() async throws {
        let credentialStore = MockSecureCredentialStore()
        let provisioning = Data(repeating: 0x6b, count: 64)
        let reservation = AuroraNativeProvisioningReservation(
            provisioning: provisioning,
            spentHintKey: Data(repeating: 0x51, count: 48),
            relayBucketID: Data(repeating: 0x61, count: 16),
            accessHintExpiryUnix: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        )
        let provisioningStore = AuroraNativeProvisioningStore(
            credentialStore: credentialStore,
            validator: MockNativeProvisioningValidator(),
            reserver: MockNativeProvisioningReserver(reservations: [reservation])
        )
        try await provisioningStore.save(provisioning, identifier: "production-slot")
        let driver = MockNativeSessionDriver(
            work: AuroraNativeIssuerWork(
                handle: 41,
                issuerURL: URL(string: "https://issuer.example")!,
                issuerCarrierPath: "/assets/issue/41",
                requestBody: Data([0x01, 0x02, 0x03])
            ),
            ingressPackets: [Data([0x45, 0x00, 0x00, 0x14])],
            nextPacket: Data([0x60, 0x00, 0x00, 0x00])
        )
        let issuer = MockNativeIssuerTransport(response: Data([0xaa, 0xbb]))
        let core = AuroraNativePacketTunnelCore(
            provisioningStore: provisioningStore,
            sessionDriver: driver,
            issuerTransport: issuer
        )
        let configuration = AuroraConfiguration(
            endpoint: URL(string: "https://relay.example:9443")!,
            nativeProvisioningIdentifier: "production-slot"
        )

        try await core.connect(configuration: configuration)
        let immediate = try await core.ingestPacketBatch(AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [2]
        ))
        let remote = try await core.nextOutboundPacketBatch()
        await core.close()

        let beginProvisioning = await driver.beginProvisioning
        let completedHandle = await driver.completedHandle
        let completedResponse = await driver.completedResponse
        let ingressPackets = await driver.ingressPackets
        let closedHandles = await driver.closedHandles
        let requestedURL = await issuer.requestedURL
        let requestedBody = await issuer.requestedBody
        XCTAssertEqual(beginProvisioning, provisioning)
        XCTAssertEqual(completedHandle, 41)
        XCTAssertEqual(completedResponse, Data([0xaa, 0xbb]))
        XCTAssertEqual(ingressPackets, [Data([0x45, 0x00, 0x00, 0x14])])
        XCTAssertEqual(closedHandles, [41])
        XCTAssertEqual(requestedURL?.path, "/assets/issue/41")
        XCTAssertEqual(requestedBody, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(immediate.protocolNumbers, [2])
        XCTAssertEqual(remote.protocolNumbers, [30])
    }

    func testNativeProvisioningStorePersistsReservationsAcrossInstances() async throws {
        let credentials = MockSecureCredentialStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xa1, count: 64),
            spentHintKey: Data(repeating: 0x11, count: 48),
            relayBucketID: Data(repeating: 0x21, count: 16),
            accessHintExpiryUnix: 1_800_003_600
        )
        let second = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xa2, count: 64),
            spentHintKey: Data(repeating: 0x12, count: 48),
            relayBucketID: Data(repeating: 0x21, count: 16),
            accessHintExpiryUnix: 1_800_003_600
        )
        let firstReserver = MockNativeProvisioningReserver(reservations: [first])
        let store = AuroraNativeProvisioningStore(
            credentialStore: credentials,
            validator: MockNativeProvisioningValidator(),
            reserver: firstReserver
        )
        try await store.save(Data(repeating: 0xaa, count: 128), identifier: "recovery-slot")
        let firstResult = try await store.reserve(identifier: "recovery-slot", now: now)
        XCTAssertEqual(firstResult, first)

        let secondReserver = MockNativeProvisioningReserver(reservations: [second])
        let restoredStore = AuroraNativeProvisioningStore(
            credentialStore: credentials,
            validator: MockNativeProvisioningValidator(),
            reserver: secondReserver
        )
        let secondResult = try await restoredStore.reserve(identifier: "recovery-slot", now: now)
        XCTAssertEqual(secondResult, second)
        let secondReservedSpentHintKeys = await secondReserver.reservedSpentHintKeys
        XCTAssertEqual(secondReservedSpentHintKeys, [[first.spentHintKey]])

        let storedLedgerData = await credentials.savedData(
            service: AuroraNativeProvisioningStore.reservationService,
            account: AuroraNativeProvisioningStore.reservationAccount(identifier: "recovery-slot")
        )
        let ledgerData = try XCTUnwrap(storedLedgerData)
        let ledger = try JSONDecoder().decode(AuroraNativeProvisioningReservationLedger.self, from: ledgerData)
        XCTAssertEqual(ledger.entries.map(\.spentHintKey), [first.spentHintKey, second.spentHintKey])
        XCTAssertFalse(ledgerData.contains(Data(repeating: 0xaa, count: 8)))
    }

    func testNativeProvisioningStoreIgnoresStaleLedgerAfterReplacementCleanupFailure() async throws {
        let credentials = MockSecureCredentialStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xa1, count: 64),
            spentHintKey: Data(repeating: 0x11, count: 48),
            relayBucketID: Data(repeating: 0x21, count: 16),
            accessHintExpiryUnix: 1_800_003_600
        )
        let second = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xa2, count: 64),
            spentHintKey: Data(repeating: 0x12, count: 48),
            relayBucketID: Data(repeating: 0x22, count: 16),
            accessHintExpiryUnix: 1_800_003_600
        )
        let firstReserver = MockNativeProvisioningReserver(reservations: [first])
        let store = AuroraNativeProvisioningStore(
            credentialStore: credentials,
            validator: MockNativeProvisioningValidator(),
            reserver: firstReserver
        )
        try await store.save(Data(repeating: 0xaa, count: 128), identifier: "recovery-slot")
        _ = try await store.reserve(identifier: "recovery-slot", now: now)

        await credentials.failDeletes(
            service: AuroraNativeProvisioningStore.reservationService,
            account: AuroraNativeProvisioningStore.reservationAccount(identifier: "recovery-slot")
        )
        try await store.save(Data(repeating: 0xbb, count: 128), identifier: "recovery-slot")

        let secondReserver = MockNativeProvisioningReserver(reservations: [second])
        let restoredStore = AuroraNativeProvisioningStore(
            credentialStore: credentials,
            validator: MockNativeProvisioningValidator(),
            reserver: secondReserver
        )
        _ = try await restoredStore.reserve(identifier: "recovery-slot", now: now)

        let spentHintKeys = await secondReserver.reservedSpentHintKeys
        XCTAssertEqual(spentHintKeys, [[]])
    }

    func testNativeProvisioningStoreMigratesUnboundLedgerConservatively() async throws {
        let credentials = MockSecureCredentialStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacySpentHintKey = Data(repeating: 0x11, count: 48)
        let next = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xa2, count: 64),
            spentHintKey: Data(repeating: 0x12, count: 48),
            relayBucketID: Data(repeating: 0x22, count: 16),
            accessHintExpiryUnix: 1_800_003_600
        )
        let store = AuroraNativeProvisioningStore(
            credentialStore: credentials,
            validator: MockNativeProvisioningValidator(),
            reserver: MockNativeProvisioningReserver(reservations: [])
        )
        try await store.save(Data(repeating: 0xaa, count: 128), identifier: "recovery-slot")

        let legacyLedger = LegacyNativeProvisioningReservationLedger(entries: [
            .init(spentHintKey: legacySpentHintKey, accessHintExpiryUnix: 1_800_003_600),
        ])
        try await credentials.save(
            JSONEncoder().encode(legacyLedger),
            service: AuroraNativeProvisioningStore.reservationService,
            account: AuroraNativeProvisioningStore.reservationAccount(identifier: "recovery-slot")
        )

        let reserver = MockNativeProvisioningReserver(reservations: [next])
        let restoredStore = AuroraNativeProvisioningStore(
            credentialStore: credentials,
            validator: MockNativeProvisioningValidator(),
            reserver: reserver
        )
        _ = try await restoredStore.reserve(identifier: "recovery-slot", now: now)

        let spentHintKeys = await reserver.reservedSpentHintKeys
        XCTAssertEqual(spentHintKeys, [[legacySpentHintKey]])
        let savedLedgerData = await credentials.savedData(
            service: AuroraNativeProvisioningStore.reservationService,
            account: AuroraNativeProvisioningStore.reservationAccount(identifier: "recovery-slot")
        )
        let ledgerData = try XCTUnwrap(savedLedgerData)
        let ledger = try JSONDecoder().decode(AuroraNativeProvisioningReservationLedger.self, from: ledgerData)
        XCTAssertEqual(ledger.sourceDigest?.count, 32)
        XCTAssertEqual(ledger.entries.map(\.spentHintKey), [legacySpentHintKey, next.spentHintKey])
    }

    func testNativePacketTunnelCoreUsesFreshReservationAfterReconnect() async throws {
        let credentials = MockSecureCredentialStore()
        let first = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xb1, count: 64),
            spentHintKey: Data(repeating: 0x31, count: 48),
            relayBucketID: Data(repeating: 0x41, count: 16),
            accessHintExpiryUnix: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        )
        let second = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xb2, count: 64),
            spentHintKey: Data(repeating: 0x32, count: 48),
            relayBucketID: Data(repeating: 0x41, count: 16),
            accessHintExpiryUnix: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        )
        let reserver = MockNativeProvisioningReserver(reservations: [first, second])
        let store = AuroraNativeProvisioningStore(
            credentialStore: credentials,
            validator: MockNativeProvisioningValidator(),
            reserver: reserver
        )
        try await store.save(Data(repeating: 0xbb, count: 128), identifier: "recovery-slot")
        let driver = MockNativeSessionDriver(
            work: AuroraNativeIssuerWork(
                handle: 51,
                issuerURL: URL(string: "https://issuer.example")!,
                issuerCarrierPath: "/assets/issue/51",
                requestBody: Data([0x01])
            ),
            ingressPackets: [],
            nextPacket: Data([0x60, 0x00, 0x00, 0x00])
        )
        let core = AuroraNativePacketTunnelCore(
            provisioningStore: store,
            sessionDriver: driver,
            issuerTransport: MockNativeIssuerTransport(response: Data([0xaa]))
        )
        let configuration = AuroraConfiguration(
            endpoint: URL(string: "https://relay.example:9443")!,
            nativeProvisioningIdentifier: "recovery-slot"
        )

        try await core.connect(configuration: configuration)
        await core.close()
        try await core.connect(configuration: configuration)
        await core.close()

        let begunProvisionings = await driver.begunProvisionings
        let reservedSpentHintKeys = await reserver.reservedSpentHintKeys
        XCTAssertEqual(begunProvisionings, [first.provisioning, second.provisioning])
        XCTAssertEqual(reservedSpentHintKeys, [[], [first.spentHintKey]])
    }

    func testNativeIssuerRedirectDelegateRejectsRedirects() {
        let sourceURL = URL(string: "https://issuer.example/assets/issue/41")!
        let redirectedURL = URL(string: "https://redirect.example/assets/issue/41")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: sourceURL)
        let response = HTTPURLResponse(
            url: sourceURL,
            statusCode: 307,
            httpVersion: nil,
            headerFields: ["Location": redirectedURL.absoluteString]
        )!
        let decision = NativeIssuerRedirectDecision()

        AuroraNoRedirectSessionDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectedURL)
        ) { request in
            decision.set(request)
        }

        XCTAssertNil(decision.value)
    }

    func testNativeIssuerTransportRejectsOversizedResponseBeforeCoreCompletion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IssuerURLProtocol.self]
        let transport = URLSessionAuroraNativeIssuerTransport(configuration: configuration)
        IssuerURLProtocol.setResponses([
            IssuerURLProtocol.Response(
                path: "/assets/issue/41",
                contentType: "application/octet-stream",
                body: Data(repeating: 0xa1, count: (1 << 20) + 1)
            ),
        ])

        do {
            _ = try await transport.postIssuerWork(
                url: URL(string: "https://issuer.example/assets/issue/41")!,
                body: Data([0x01, 0x02, 0x03])
            )
            XCTFail("oversized native issuer response unexpectedly succeeded")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testTunnelProfileRejectsInvalidProviderConfigurationEndpoint() throws {
        XCTAssertNil(AuroraTunnelProfile.configuration(from: [
            "endpoint": "not a server",
            "routePolicy": "balanced",
        ]))
    }

    func testTunnelConfigurationResolverPrefersProviderConfiguration() throws {
        let store = MockPortableProfileStore(initialProfileText: """
        [aurora]
        version = "2.0"
        profile = "adversarial-dpi"
        route = "split-2"
        speed = "balanced"

        [local]
        mode = "platform-vpn"
        dns = "through-aurora"

        [methods]
        allow_h2 = true
        allow_h1_ws = true
        allow_h3_ext_dgram = false
        allow_masque = false

        [security]
        require_pq = true
        require_split2_for_adversarial = true
        allow_lab_tokens = false

        [storage]
        replay_cache = "sqlite"

        [x.aurora.apple]
        endpoint = "https://stored.example:9443"
        """)
        let resolver = AuroraTunnelConfigurationResolver(
            fallbackConfiguration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            profileStore: store
        )

        let configuration = resolver.configuration(providerConfiguration: [
            AuroraTunnelProfile.endpointKey: "https://provider.example:9443",
            AuroraTunnelProfile.routePolicyKey: "balanced",
        ])

        XCTAssertEqual(configuration.endpoint.absoluteString, "https://provider.example:9443")
        XCTAssertEqual(configuration.routePolicy, "balanced")
    }

    func testTunnelConfigurationResolverLoadsStoredPortableProfileAndMigratesSanitizedProfile() throws {
        let store = MockPortableProfileStore(initialProfileText: """
        [aurora]
        version = "2.0"
        profile = "adversarial-dpi"
        route = "split-2"
        speed = "balanced"

        [local]
        mode = "platform-vpn"
        dns = "through-aurora"

        [methods]
        allow_h2 = true
        allow_h1_ws = true
        allow_h3_ext_dgram = false
        allow_masque = false

        [security]
        require_pq = true
        require_split2_for_adversarial = true
        allow_lab_tokens = false

        [storage]
        replay_cache = "sqlite"

        [x.aurora.apple]
        endpoint = "https://stored.example:9443"
        admission_proof = "secret-proof"
        token_authenticator = "secret-token"
        hint_secret = "secret-hint"
        """)
        let resolver = AuroraTunnelConfigurationResolver(
            fallbackConfiguration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            profileStore: store
        )

        let configuration = resolver.configuration(providerConfiguration: nil)
        let migratedProfile = try XCTUnwrap(store.savedProfileText)

        XCTAssertEqual(configuration.endpoint.absoluteString, "https://stored.example:9443")
        XCTAssertEqual(configuration.routePolicy, "adversarial-dpi")
        XCTAssertFalse(migratedProfile.contains("secret-proof"))
        XCTAssertFalse(migratedProfile.contains("secret-token"))
        XCTAssertFalse(migratedProfile.contains("secret-hint"))
        XCTAssertFalse(migratedProfile.contains("admission_proof"))
        XCTAssertFalse(migratedProfile.contains("token_authenticator"))
        XCTAssertFalse(migratedProfile.contains("hint_secret"))
    }

    func testPortableProfileParsesConfigFloorAndAppleEndpointExtension() throws {
        let profile = try AuroraPortableProfile.parse("""
        [aurora]
        version = "2.0"
        profile = "adversarial-dpi"
        route = "split-2"
        speed = "balanced"

        [local]
        mode = "platform-vpn"
        dns = "through-aurora"

        [methods]
        allow_h2 = true
        allow_h1_ws = true
        allow_h3_ext_dgram = false
        allow_masque = false

        [security]
        require_pq = true
        require_split2_for_adversarial = true
        allow_lab_tokens = false

        [storage]
        replay_cache = "sqlite"

        [x.aurora.apple]
        endpoint = "https://relay.example:9443"
        """)

        XCTAssertEqual(profile.version, "2.0")
        XCTAssertEqual(profile.profile, "adversarial-dpi")
        XCTAssertEqual(profile.route, "split-2")
        XCTAssertEqual(profile.localMode, "platform-vpn")
        XCTAssertEqual(profile.endpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(profile.configuration(defaultEndpoint: URL(string: "https://fallback.example")!).routePolicy, "adversarial-dpi")
    }

    func testPortableProfileExportRoundTripsAppleEndpointWithoutSecrets() throws {
        let profile = AuroraPortableProfile(
            configuration: AuroraConfiguration(
                endpoint: URL(string: "https://relay.example:9443")!,
                routePolicy: "adversarial-dpi"
            ),
            route: "split-2",
            localMode: "platform-vpn"
        )

        let exported = profile.tomlString()
        let reparsed = try AuroraPortableProfile.parse(exported)

        XCTAssertTrue(exported.contains("[aurora]"))
        XCTAssertTrue(exported.contains("[x.aurora.apple]"))
        XCTAssertFalse(exported.contains("admission_proof"))
        XCTAssertFalse(exported.contains("token_authenticator"))
        XCTAssertFalse(exported.contains("hint_secret"))
        XCTAssertEqual(reparsed.endpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(reparsed.profile, "adversarial-dpi")
        XCTAssertEqual(reparsed.route, "split-2")
        XCTAssertEqual(reparsed.localMode, "platform-vpn")
    }

    func testUserDefaultsProfileStoreSanitizesBeforeSaving() throws {
        let suiteName = "org.aurora-protocol.aurora.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AuroraUserDefaultsProfileStore(
            appGroupIdentifier: suiteName,
            defaults: defaults
        )

        try store.savePortableProfile("""
        [aurora]
        version = "2.0"
        profile = "adversarial-dpi"
        route = "split-2"
        speed = "balanced"

        [local]
        mode = "platform-vpn"
        dns = "through-aurora"

        [methods]
        allow_h2 = true
        allow_h1_ws = true
        allow_h3_ext_dgram = false
        allow_masque = false

        [security]
        require_pq = true
        require_split2_for_adversarial = true
        allow_lab_tokens = false

        [storage]
        replay_cache = "sqlite"

        [x.aurora.apple]
        endpoint = "https://relay.example:9443"
        admission_proof = "secret-proof"
        token_authenticator = "secret-token"
        hint_secret = "secret-hint"
        """)

        let saved = try XCTUnwrap(try store.loadPortableProfile())
        XCTAssertTrue(saved.contains("[x.aurora.apple]"))
        XCTAssertFalse(saved.contains("secret-proof"))
        XCTAssertFalse(saved.contains("secret-token"))
        XCTAssertFalse(saved.contains("secret-hint"))
        XCTAssertFalse(saved.contains("admission_proof"))
        XCTAssertFalse(saved.contains("token_authenticator"))
        XCTAssertFalse(saved.contains("hint_secret"))
    }

    func testPortableProfileRejectsUnknownSecurityKeys() {
        XCTAssertThrowsError(try AuroraPortableProfile.parse("""
        [security]
        allow_plaintext_tokens = "yes"

        [x.aurora.apple]
        endpoint = "https://relay.example:9443"
        """)) { error in
            XCTAssertEqual(error as? AuroraPortableProfileError, .unknownKey(section: "security", key: "allow_plaintext_tokens"))
        }
    }

    func testPortableProfileRequiresLabProfileForLabTokens() throws {
        XCTAssertThrowsError(try AuroraPortableProfile.parse("""
        [aurora]
        profile = "adversarial-dpi"

        [security]
        allow_lab_tokens = true
        """)) { error in
            XCTAssertEqual(
                error as? AuroraPortableProfileError,
                .invalidValue(section: "security", key: "allow_lab_tokens", value: "true")
            )
        }

        let profile = try AuroraPortableProfile.parse("""
        [aurora]
        profile = "lab"

        [security]
        allow_lab_tokens = true
        """)
        XCTAssertTrue(profile.allowLabTokens)
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

    func testPacketBatchCodecRejectsProtocolNumberMismatch() throws {
        let encodedMismatch = Data([
            0x00, 0x01,
            0x00, 0x1e,
            0x00, 0x00, 0x00, 0x04,
            0x45, 0x00, 0x00, 0x14,
        ])

        XCTAssertThrowsError(try AuroraPacketBatchCodec.decode(encodedMismatch))
        XCTAssertThrowsError(try AuroraPacketBatchCodec.encode(AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [30]
        )))
        XCTAssertThrowsError(try AuroraPacketBatchCodec.encode(AuroraPacketFlowBatch(
            packets: [Data([0x05, 0x00, 0x00, 0x14])],
            protocolNumbers: [0]
        )))
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

    func testServerBackedPacketTunnelCoreRequiresFullServerSurface() async throws {
        let statusClient = MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: false))
        let packetClient = MockPacketExchangeClient(outboundBatch: AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x15])],
            protocolNumbers: [2]
        ))
        let core = AuroraServerBackedPacketTunnelCore(
            statusClient: statusClient,
            packetClient: packetClient
        )

        do {
            try await core.connect(configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!))
            XCTFail("connect should fail without full server surface")
        } catch {
            XCTAssertEqual(error as? AuroraClientError, .unavailable)
        }

        let packetEndpoint = await packetClient.requestedEndpoint
        XCTAssertNil(packetEndpoint)
    }

    func testServerBackedPacketTunnelCoreSpendsAdmissionTokenBeforePacketExchange() async throws {
        let statusClient = MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true))
        let packetClient = MockPacketExchangeClient(outboundBatch: AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x15])],
            protocolNumbers: [2]
        ))
        let store = MockSecureCredentialStore()
        let wallet = AuroraTokenWallet(credentialStore: store)
        let issued = AuroraIssuedAdmissionToken(
            admissionProof: Data("secret-proof".utf8),
            relayBucketID: Data(repeating: 0x81, count: 16),
            tokenAuthenticator: Data("secret-token".utf8),
            issuerMetadataHash: Data(repeating: 0x46, count: 48),
            expiryUnix: 1_800_000_000
        )
        let issuerClient = MockIssuerClient(issuedToken: issued)
        let core = AuroraServerBackedPacketTunnelCore(
            statusClient: statusClient,
            packetClient: packetClient,
            issuerClient: issuerClient,
            tokenWallet: wallet
        )
        let configuration = AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!)
        let inbound = AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [2]
        )

        try await core.connect(configuration: configuration)
        _ = try await core.ingestPacketBatch(inbound)

        let requestedIssue = await issuerClient.requestedIssue
        let requestedSpendEndpoint = await issuerClient.requestedSpendEndpoint
        let spentAdmissionProofs = await issuerClient.spentAdmissionProofs
        let saved = try await wallet.load(relayBucketID: Data(repeating: 0x81, count: 16).auroraHexString)
        XCTAssertEqual(requestedIssue?.tokenNonce.count, 32)
        XCTAssertEqual(requestedIssue?.redemptionContextHash.count, 48)
        XCTAssertEqual(requestedSpendEndpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(spentAdmissionProofs, [Data("secret-proof".utf8)])
        XCTAssertEqual(saved?.admissionProof, Data("secret-proof".utf8))
        XCTAssertEqual(saved?.tokenAuthenticator, Data("secret-token".utf8))
        XCTAssertEqual(saved?.expiresAtUnix, 1_800_000_000)
    }

    func testServerBackedPacketTunnelCoreDoesNotConnectWhenIssuerFails() async throws {
        let statusClient = MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true))
        let packetClient = MockPacketExchangeClient(outboundBatch: AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x15])],
            protocolNumbers: [2]
        ))
        let core = AuroraServerBackedPacketTunnelCore(
            statusClient: statusClient,
            packetClient: packetClient,
            issuerClient: MockIssuerClient(error: AuroraClientError.unavailable),
            tokenWallet: AuroraTokenWallet(credentialStore: MockSecureCredentialStore())
        )

        do {
            try await core.connect(configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!))
            XCTFail("connect should fail when issuer token issuance fails")
        } catch {
            XCTAssertEqual(error as? AuroraClientError, .unavailable)
        }

        let packetEndpoint = await packetClient.requestedEndpoint
        XCTAssertNil(packetEndpoint)
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

    func testURLSessionServerClientAcceptsPacketContentTypeParameters() async throws {
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
        PacketExchangeURLProtocol.setResponse(
            try AuroraPacketBatchCodec.encode(outbound),
            contentType: "application/octet-stream; charset=binary"
        )

        let exchanged = try await client.exchangePacketBatch(
            endpoint: URL(string: "https://relay.example:9443")!,
            batch: inbound
        )

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
        let provisioningStore = AuroraNativeProvisioningStore(
            credentialStore: credentialStore,
            validator: MockNativeProvisioningValidator()
        )
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

    func testProjectBuildsSharedPacketTunnelTargets() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let workflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        let readinessScript = try String(
            contentsOf: root.appendingPathComponent("scripts/aurora-apple-check.sh"),
            encoding: .utf8
        )

        for target in ["AuroraPacketTunnel_iOS", "AuroraPacketTunnel_macOS"] {
            XCTAssertTrue(project.contains("\(target):"), "project.yml missing \(target)")
            XCTAssertTrue(readinessScript.contains("-scheme \(target)"), "Apple readiness script does not build \(target)")
        }
        XCTAssertTrue(workflow.contains("scripts/aurora-apple-check.sh"), "CI workflow does not run the Apple readiness script")
        XCTAssertTrue(project.contains("type: app-extension"))
        XCTAssertTrue(project.contains("com.apple.networkextension.packet-tunnel"))
        XCTAssertTrue(project.contains("SharedNetworkExtension"))
        XCTAssertTrue(project.contains("- target: AuroraPacketTunnel_iOS\n        embed: true"))
        XCTAssertTrue(project.contains("- target: AuroraPacketTunnel_macOS\n        embed: true"))
    }

    func testAppleReadinessScriptCoversPackageAndPlatformBuilds() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = root.appendingPathComponent("scripts/aurora-apple-check.sh")
        let workflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let script: String

        if FileManager.default.fileExists(atPath: scriptURL.path) {
            script = try String(contentsOf: scriptURL, encoding: .utf8)
            let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertNotEqual(permissions & 0o111, 0, "Apple readiness script should be executable")
        } else {
            XCTFail("Apple readiness script missing")
            script = ""
        }

        XCTAssertTrue(workflow.contains("scripts/aurora-apple-check.sh"), "CI should call the shared Apple readiness script")
        let workflowSecurityPolicy = try workflowSecurityPolicy(at: root.appendingPathComponent(".github/workflows/ci.yml"))
        XCTAssertEqual(workflowSecurityPolicy.contentsPermission, "read", "CI should grant only repository read access")
        XCTAssertEqual(workflowSecurityPolicy.checkoutDisablesCredentialPersistence, [true, true], "CI checkouts should not persist credentials")
        let approvedActionReferences = [
            "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09",
            "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09",
            "actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e",
        ]
        XCTAssertEqual(
            workflowSecurityPolicy.actionReferences.sorted(),
            approvedActionReferences.sorted(),
            "CI should use only approved immutable action pins"
        )
        XCTAssertTrue(workflow.contains("go-version-file: aurora-core/go.mod"), "CI should use the checked-out core Go version")
        XCTAssertTrue(workflow.contains("cache-dependency-path: aurora-core/go.sum"), "CI should cache the checked-out core dependencies")
        XCTAssertTrue(workflow.contains("ref: 24b6fe6bedce0cf61b39558505448913fe79768c"), "CI should build against the current core validation ABI")
        XCTAssertTrue(readme.contains("scripts/aurora-apple-check.sh"), "README should document the shared Apple readiness script")
        XCTAssertTrue(script.contains("swift test"), "Apple readiness script should run Swift package tests")
        XCTAssertTrue(script.contains("CODE_SIGNING_ALLOWED=NO"), "Apple readiness script should use unsigned local builds")

        for scheme in ["AuroraMac", "AuroraIOS", "AuroraPacketTunnel_macOS", "AuroraPacketTunnel_iOS"] {
            XCTAssertTrue(script.contains("-scheme \(scheme)"), "Apple readiness script should build \(scheme)")
        }
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

    func testProjectDeclaresSharedAppGroupAndKeychainAccessGroups() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let entitlementPaths = [
            "Apps/iOS/AuroraIOS.entitlements",
            "Apps/macOS/AuroraMac.entitlements",
            "SharedNetworkExtension/AuroraPacketTunnel-iOS.entitlements",
            "SharedNetworkExtension/AuroraPacketTunnel-macOS.entitlements",
        ]
        let infoPaths = [
            "Apps/iOS/Info.plist",
            "Apps/macOS/Info.plist",
            "SharedNetworkExtension/Info-iOS.plist",
            "SharedNetworkExtension/Info-macOS.plist",
        ]

        for path in entitlementPaths {
            let entitlement = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(entitlement.contains("com.apple.security.application-groups"), "\(path) missing App Group entitlement")
            XCTAssertTrue(entitlement.contains("group.org.aurora-protocol.aurora.shared"), "\(path) missing shared App Group")
            XCTAssertTrue(entitlement.contains("keychain-access-groups"), "\(path) missing shared keychain access groups")
            XCTAssertTrue(entitlement.contains("$(AppIdentifierPrefix)org.aurora-protocol.aurora.shared"), "\(path) missing shared keychain group")
        }

        for path in infoPaths {
            let info = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(info.contains("AuroraAppGroupIdentifier"), "\(path) missing App Group runtime key")
            XCTAssertTrue(info.contains("group.org.aurora-protocol.aurora.shared"), "\(path) missing App Group runtime value")
            XCTAssertTrue(info.contains("AuroraKeychainAccessGroup"), "\(path) missing keychain runtime key")
            XCTAssertTrue(info.contains("$(AppIdentifierPrefix)org.aurora-protocol.aurora.shared"), "\(path) missing keychain runtime value")
        }
    }

    func testProjectGeneratorPreservesSharedStorageDeclarations() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)

        XCTAssertTrue(project.contains("com.apple.security.application-groups"), "project.yml missing App Group entitlement generation")
        XCTAssertTrue(project.contains("group.org.aurora-protocol.aurora.shared"), "project.yml missing shared App Group generation")
        XCTAssertTrue(project.contains("keychain-access-groups"), "project.yml missing keychain access group generation")
        XCTAssertTrue(project.contains("$(AppIdentifierPrefix)org.aurora-protocol.aurora.shared"), "project.yml missing shared keychain access group generation")
        XCTAssertTrue(project.contains("AuroraAppGroupIdentifier"), "project.yml missing App Group Info.plist generation")
        XCTAssertTrue(project.contains("AuroraKeychainAccessGroup"), "project.yml missing keychain Info.plist generation")
    }

    func testSharedUIExposesPortableProfileImportExport() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/AuroraUI/AuroraStatusView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(view.contains("TextEditor"), "status view missing portable profile editor")
        XCTAssertTrue(view.contains("Import Profile"), "status view missing import action")
        XCTAssertTrue(view.contains("Export Profile"), "status view missing export action")
        XCTAssertTrue(view.contains("importPortableProfile"), "status view does not call controller profile import")
        XCTAssertTrue(view.contains("exportPortableProfile"), "status view does not call controller profile export")
        XCTAssertTrue(view.contains("loadStoredPortableProfile"), "status view does not load stored portable profiles")
    }

    func testSharedUIExposesBoundedNativeProvisioningEnrollment() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/AuroraUI/AuroraStatusView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(view.contains("fileImporter"), "status view missing provisioning file importer")
        XCTAssertTrue(view.contains("Import Provisioning"), "status view missing provisioning import action")
        XCTAssertTrue(view.contains("Remove Provisioning"), "status view missing provisioning removal action")
        XCTAssertTrue(view.contains("importNativeProvisioning"), "status view does not import provisioning through the controller")
        XCTAssertTrue(view.contains("restoreNativeProvisioning"), "status view does not restore provisioning on launch")
        XCTAssertTrue(view.contains("removeNativeProvisioning"), "status view does not remove provisioning through the controller")
        XCTAssertTrue(view.contains("maximumBytes"), "status view must bound provisioning file input before loading it")
    }

    func testSharedUIExposesRedactedDiagnostics() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/AuroraUI/AuroraStatusView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(view.contains("Diagnostics"), "status view missing diagnostics section")
        XCTAssertTrue(view.contains("redactedDiagnosticLine"), "status view does not read controller redacted diagnostics")
        XCTAssertTrue(view.contains("monospaced"), "status view should render diagnostics as copy-stable text")
    }

    func testPacketTunnelProviderUsesSharedProfileStoreFallback() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let provider = try String(
            contentsOf: root.appendingPathComponent("SharedNetworkExtension/PacketTunnelProvider.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(provider.contains("AuroraTunnelConfigurationResolver"), "packet tunnel provider missing shared resolver")
        XCTAssertTrue(provider.contains("endpointResolver.resolve"), "packet tunnel provider does not resolve relay endpoints before installing routes")
        XCTAssertTrue(provider.contains("AuroraUserDefaultsProfileStore"), "packet tunnel provider missing App Group profile store")
        XCTAssertTrue(provider.contains("AuroraAppleSharedContainer.appGroupIdentifier()"), "packet tunnel provider missing App Group scope")
    }

    func testPacketTunnelProviderConnectsCoreBeforeInstallingNetworkSettings() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let provider = try String(
            contentsOf: root.appendingPathComponent("SharedNetworkExtension/PacketTunnelProvider.swift"),
            encoding: .utf8
        )

        let startRange = try XCTUnwrap(provider.range(of: "try await runtime.start()"))
        let resolutionRange = try XCTUnwrap(provider.range(of: "try await endpointResolver.resolve"))
        let settingsRange = try XCTUnwrap(provider.range(of: "try await applyTunnelNetworkSettings"))
        XCTAssertLessThan(
            resolutionRange.lowerBound,
            startRange.lowerBound,
            "packet tunnel provider should resolve relay addresses before starting the tunnel"
        )
        XCTAssertLessThan(
            startRange.lowerBound,
            settingsRange.lowerBound,
            "packet tunnel provider should connect the core before installing route and DNS settings"
        )
    }

    func testPacketTunnelProviderCancelsEstablishedTunnelOnRuntimeFailure() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let provider = try String(
            contentsOf: root.appendingPathComponent("SharedNetworkExtension/PacketTunnelProvider.swift"),
            encoding: .utf8
        )

        let completionRange = try XCTUnwrap(provider.range(of: "completion(nil)"))
        let runRange = try XCTUnwrap(provider.range(of: "await runtime.runUntilStopped()"))
        let stopRange = try XCTUnwrap(provider.range(of: "lifecycle.requestStop {"))
        let cancellationRange = try XCTUnwrap(provider.range(of: "runtimeTask?.cancel()"))
        let runtimeStopRange = try XCTUnwrap(provider.range(of: "await runtime?.stop()"))
        let setupWaitRange = try XCTUnwrap(provider.range(of: "await startupGate.waitForQuiescence()"))
        XCTAssertTrue(
            provider.contains("cancelTunnelWithError(failure)"),
            "provider should cancel an established tunnel when the runtime fails"
        )
        XCTAssertTrue(
            provider.contains("lifecycle.completeStartup(generation, delivering:"),
            "provider should atomically reject startup success after a stop request"
        )
        XCTAssertTrue(
            provider.contains("lifecycle.beginPathObservation(generation, activating:"),
            "a canceled startup should not start the path observer"
        )
        XCTAssertTrue(
            provider.contains("startupGate.begin(generation)"),
            "provider should track setup before starting asynchronous work"
        )
        XCTAssertFalse(
            provider.contains("await runtime.activatePacketFlow()"),
            "provider should not start the packet pump before startup completion"
        )
        XCTAssertGreaterThan(
            runRange.lowerBound,
            completionRange.lowerBound,
            "provider should enter the runtime pump only after the tunnel has become active"
        )
        XCTAssertGreaterThan(
            cancellationRange.lowerBound,
            stopRange.lowerBound,
            "provider should latch stop intent before cancelling its runtime task"
        )
        XCTAssertGreaterThan(
            setupWaitRange.lowerBound,
            runtimeStopRange.lowerBound,
            "provider should await setup quiescence before completing stop"
        )
    }

    func testPacketTunnelProviderRecoversNativeCarrierAfterNetworkPathChanges() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let provider = try String(
            contentsOf: root.appendingPathComponent("SharedNetworkExtension/PacketTunnelProvider.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            provider.contains("AuroraNetworkPathTransitionTracker"),
            "packet tunnel provider must distinguish initial, duplicate, unavailable, and changed paths"
        )
        XCTAssertTrue(
            provider.contains("AuroraAsyncSerialQueue"),
            "packet tunnel provider must serialize network-path recovery work"
        )
        XCTAssertTrue(
            provider.contains("runtime.suspendForNetworkPathChange()"),
            "packet tunnel provider must stop native carrier traffic before path recovery"
        )
        XCTAssertTrue(
            provider.contains("runtime.reconnectAfterNetworkPathChange()"),
            "packet tunnel provider must establish a fresh native carrier after a path change"
        )
        XCTAssertTrue(
            provider.contains("reasserting = true"),
            "packet tunnel provider must prevent packet forwarding while native recovery is in progress"
        )
        XCTAssertTrue(
            provider.contains("AuroraNetworkPathChange(interface: \"sleep\", expensive: false, constrained: false, available: false)"),
            "packet tunnel provider must suspend native carrier traffic before device sleep"
        )
        XCTAssertTrue(
            provider.contains("await enqueuePathChange(change)"),
            "packet tunnel provider must route path, sleep, and wake events through serialized recovery"
        )
    }

    func testPacketTunnelProviderInstallsIPv6Routes() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let provider = try String(
            contentsOf: root.appendingPathComponent("SharedNetworkExtension/PacketTunnelProvider.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(provider.contains("NEIPv6Settings"), "packet tunnel provider missing IPv6 settings")
        XCTAssertTrue(provider.contains("NEIPv6Route.default()"), "packet tunnel provider missing IPv6 default route")
        XCTAssertTrue(
            provider.contains("configuration.excludedIPv6Routes"),
            "packet tunnel provider missing IPv6 relay exclusions"
        )
    }

    func testAppsConstructControllersWithSharedAppGroupProfileStore() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appPaths = [
            "Apps/iOS/AuroraIOSApp.swift",
            "Apps/macOS/AuroraMacApp.swift",
        ]

        for path in appPaths {
            let app = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(app.contains("profileStore:"), "\(path) missing profile store injection")
            XCTAssertTrue(app.contains("AuroraUserDefaultsProfileStore"), "\(path) missing shared profile store")
            XCTAssertTrue(app.contains("AuroraAppleSharedContainer.appGroupIdentifier()"), "\(path) missing App Group profile store scope")
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

private struct WorkflowSecurityPolicy {
    let actionReferences: [String]
    let contentsPermission: String?
    let checkoutDisablesCredentialPersistence: [Bool]
}

private func workflowSecurityPolicy(at workflowURL: URL) throws -> WorkflowSecurityPolicy {
    let rubyURL = URL(fileURLWithPath: "/usr/bin/ruby")
    guard FileManager.default.isExecutableFile(atPath: rubyURL.path) else {
        throw NSError(domain: "AuroraKitTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ruby YAML parser is unavailable"])
    }

    let script = #"""
    require "json"
    require "yaml"

    def collect_workflow_policy(value, references, checkout_credential_persistence)
      case value
      when Hash
        uses = value["uses"]
        if uses.is_a?(String)
          references << uses
          if uses.start_with?("actions/checkout@")
            checkout_credential_persistence << (value.dig("with", "persist-credentials") == false)
          end
        end
        value.each_value { |child| collect_workflow_policy(child, references, checkout_credential_persistence) }
      when Array
        value.each { |child| collect_workflow_policy(child, references, checkout_credential_persistence) }
      end
    end

    workflow = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
    references = []
    checkout_credential_persistence = []
    collect_workflow_policy(workflow, references, checkout_credential_persistence)
    contents_permission = workflow.dig("permissions", "contents") if workflow.is_a?(Hash)
    STDOUT.write(JSON.generate({
      "actionReferences" => references,
      "contentsPermission" => contents_permission,
      "checkoutDisablesCredentialPersistence" => checkout_credential_persistence,
    }))
    """#
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = rubyURL
    process.arguments = ["-e", script, workflowURL.path]
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw NSError(domain: "AuroraKitTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let actionReferences = decoded["actionReferences"] as? [String],
        let checkoutDisablesCredentialPersistence = decoded["checkoutDisablesCredentialPersistence"] as? [Bool]
    else {
        throw NSError(domain: "AuroraKitTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ruby YAML parser returned an invalid workflow policy"])
    }

    return WorkflowSecurityPolicy(
        actionReferences: actionReferences,
        contentsPermission: decoded["contentsPermission"] as? String,
        checkoutDisablesCredentialPersistence: checkoutDisablesCredentialPersistence
    )
}

private final class MockPortableProfileStore: AuroraPortableProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var profileText: String?

    init(initialProfileText: String? = nil) {
        profileText = initialProfileText
    }

    var savedProfileText: String? {
        lock.lock()
        defer { lock.unlock() }
        return profileText
    }

    func loadPortableProfile() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return profileText
    }

    func savePortableProfile(_ profileText: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.profileText = profileText
    }
}

private struct MockServerClient: AuroraServerClient {
    var status: AuroraServerStatus

    func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus {
        status
    }
}

private struct FailingServerClient: AuroraServerClient {
    func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus {
        throw AuroraClientError.unavailable
    }
}

private actor MockIssuerClient: AuroraIssuerClient {
    private let issuedToken: AuroraIssuedAdmissionToken?
    private let error: (any Error)?
    private let spentKey: Data
    private(set) var requestedEndpoint: URL?
    private(set) var requestedIssue: AuroraBlindRSAIssueRequest?
    private(set) var requestedSpendEndpoint: URL?
    private(set) var spentAdmissionProofs: [Data] = []

    init(issuedToken: AuroraIssuedAdmissionToken, spentKey: Data = Data(repeating: 0x7b, count: 48)) {
        self.issuedToken = issuedToken
        self.spentKey = spentKey
        self.error = nil
    }

    init(error: any Error) {
        self.issuedToken = nil
        self.spentKey = Data(repeating: 0x7b, count: 48)
        self.error = error
    }

    func fetchIssuerMetadata(endpoint: URL) async throws -> AuroraIssuerMetadataEnvelope {
        AuroraIssuerMetadataEnvelope(
            issuerMetadata: Data(repeating: 0x45, count: 32),
            issuerMetadataHash: Data(repeating: 0x46, count: 48)
        )
    }

    func issueBlindRSAAdmissionToken(endpoint: URL, request: AuroraBlindRSAIssueRequest) async throws -> AuroraIssuedAdmissionToken {
        requestedEndpoint = endpoint
        requestedIssue = request
        if let error {
            throw error
        }
        return issuedToken ?? AuroraIssuedAdmissionToken(
            admissionProof: Data(),
            relayBucketID: Data(repeating: 0x81, count: 16),
            tokenAuthenticator: Data(),
            expiryUnix: request.expiryUnix
        )
    }

    func spendAdmissionToken(endpoint: URL, admissionProof: Data) async throws -> Data {
        requestedSpendEndpoint = endpoint
        spentAdmissionProofs.append(admissionProof)
        if let error {
            throw error
        }
        return spentKey
    }
}

private actor MockSecureCredentialStore: AuroraSecureCredentialStore {
    struct Key: Hashable {
        var service: String
        var account: String
    }

    private var entries: [Key: Data] = [:]
    private var failingDeletes = Set<Key>()
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
        guard !failingDeletes.contains(key) else {
            throw AuroraNativeTunnelError.unavailable
        }
        entries.removeValue(forKey: key)
        deletedKeys.append(key)
    }

    func failDeletes(service: String, account: String) {
        failingDeletes.insert(Key(service: service, account: account))
    }

    func savedData(service: String, account: String) -> Data? {
        entries[Key(service: service, account: account)]
    }
}

private struct LegacyNativeProvisioningReservationLedger: Codable {
    struct Entry: Codable {
        var spentHintKey: Data
        var accessHintExpiryUnix: UInt64
    }

    var entries: [Entry]
}

private actor MockNativeProvisioningReserver: AuroraNativeProvisioningReserver {
    private var reservations: [AuroraNativeProvisioningReservation]
    private(set) var reservedSpentHintKeys: [[Data]] = []

    init(reservations: [AuroraNativeProvisioningReservation]) {
        self.reservations = reservations
    }

    func reserve(
        source: Data,
        spentHintKeys: [Data],
        now: Date
    ) async throws -> AuroraNativeProvisioningReservation {
        guard !source.isEmpty, now.timeIntervalSince1970 > 0, !reservations.isEmpty else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        reservedSpentHintKeys.append(spentHintKeys)
        return reservations.removeFirst()
    }
}

private actor MockNativeProvisioningValidator: AuroraNativeProvisioningValidator {
    private let error: (any Error)?
    private(set) var validatedSources: [Data] = []

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func validate(source: Data, now: Date) async throws {
        guard !source.isEmpty, now.timeIntervalSince1970 > 0 else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        validatedSources.append(source)
        if let error {
            throw error
        }
    }
}

private final class IssuerURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var path: String
        var contentType: String
        var body: Data
    }

    struct RecordedRequest: Sendable {
        var request: URLRequest
        var body: Data?
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [Response] = []
        private var requests: [RecordedRequest] = []

        func setResponses(_ responses: [Response]) {
            lock.lock()
            defer { lock.unlock() }
            self.responses = responses
            requests = []
        }

        func record(request: URLRequest, body: Data?) -> Response {
            lock.lock()
            defer { lock.unlock() }
            requests.append(RecordedRequest(request: request, body: body))
            if !responses.isEmpty {
                return responses.removeFirst()
            }
            return Response(path: request.url?.path ?? "", contentType: "application/json", body: Data())
        }

        func recordedRequests() -> [RecordedRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private static let state = State()

    static var recordedRequests: [RecordedRequest] {
        state.recordedRequests()
    }

    static func setResponses(_ responses: [Response]) {
        state.setResponses(responses)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? PacketExchangeURLProtocol.readBodyStream(request.httpBodyStream)
        let configured = Self.state.record(request: request, body: body)
        let statusCode = request.url?.path == configured.path ? 200 : 404
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": configured.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: configured.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class NativeIssuerRedirectDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func set(_ request: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        self.request = request
    }

    var value: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
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

private actor MockNativeSessionDriver: AuroraNativeSessionDriver {
    private let work: AuroraNativeIssuerWork
    private let responses: [Data]
    private let remotePacket: Data
    private(set) var beginProvisioning: Data?
    private(set) var begunProvisionings: [Data] = []
    private(set) var completedHandle: UInt64?
    private(set) var completedResponse: Data?
    private(set) var ingressPackets: [Data] = []
    private(set) var closedHandles: [UInt64] = []

    init(work: AuroraNativeIssuerWork, ingressPackets: [Data], nextPacket: Data) {
        self.work = work
        responses = ingressPackets
        remotePacket = nextPacket
    }

    func begin(provisioning: Data) async throws -> AuroraNativeIssuerWork {
        beginProvisioning = provisioning
        begunProvisionings.append(provisioning)
        return work
    }

    func complete(handle: UInt64, issuerResponse: Data) async throws {
        completedHandle = handle
        completedResponse = issuerResponse
    }

    func ingress(handle: UInt64, packet: Data) async throws -> [Data] {
        guard handle == work.handle else {
            throw AuroraNativeTunnelError.coreOperationFailed
        }
        ingressPackets.append(packet)
        return responses
    }

    func nextLocalPacket(handle: UInt64) async throws -> Data {
        guard handle == work.handle else {
            throw AuroraNativeTunnelError.coreOperationFailed
        }
        return remotePacket
    }

    func close(handle: UInt64) async {
        closedHandles.append(handle)
    }
}

private actor MockNativeIssuerTransport: AuroraNativeIssuerTransport {
    private let response: Data
    private(set) var requestedURL: URL?
    private(set) var requestedBody: Data?

    init(response: Data) {
        self.response = response
    }

    func postIssuerWork(url: URL, body: Data) async throws -> Data {
        requestedURL = url
        requestedBody = body
        return response
    }
}

private final class PacketExchangeURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        var response = Data()
        var contentType = "application/octet-stream"
        var lastRequest: URLRequest?
        var lastBody: Data?

        func setResponse(_ data: Data, contentType: String) {
            lock.lock()
            defer { lock.unlock() }
            response = data
            self.contentType = contentType
            lastRequest = nil
            lastBody = nil
        }

        func record(request: URLRequest, body: Data?) -> (body: Data, contentType: String) {
            lock.lock()
            defer { lock.unlock() }
            lastRequest = request
            lastBody = body
            return (response, contentType)
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

    static func setResponse(_ data: Data, contentType: String = "application/octet-stream") {
        state.setResponse(data, contentType: contentType)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        let configured = Self.state.record(request: request, body: body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": configured.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: configured.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    fileprivate static func readBodyStream(_ stream: InputStream?) -> Data? {
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

// Builds cover-carrier server responses ([type][payload]) the way the portable
// core encodes them, so the transport tests can exercise the real carrier codec.
private enum CarrierFixture {
    static func metadataResponse(metadata: Data, hash: Data) -> Data {
        var out = Data([0x03])
        let len = UInt32(metadata.count)
        out.append(UInt8((len >> 24) & 0xff))
        out.append(UInt8((len >> 16) & 0xff))
        out.append(UInt8((len >> 8) & 0xff))
        out.append(UInt8(len & 0xff))
        out.append(metadata)
        out.append(hash)
        return out
    }

    static func issueResponse(_ admissionProof: Data) -> Data {
        Data([0x05]) + admissionProof
    }

    static func spendResponse(_ spentKey: Data) -> Data {
        Data([0x07]) + spentKey
    }
}

private func makeAdmissionProof(
    relayBucketID: Data,
    tokenAuthenticator: Data,
    expiryUnix: UInt64,
    issuerMetadataHash: Data = Data(repeating: 0x46, count: 48)
) -> Data {
    var proof = Data()
    let tokenKeyID = Data(repeating: 0x22, count: 32)
    proof.appendVarint(0x000200)
    proof.appendVarint(0x0002)
    proof.append(Data(repeating: 0x11, count: 16))
    proof.append(tokenKeyID)
    proof.append(relayBucketID)
    proof.append(Data(repeating: 0x33, count: 16))
    proof.appendUInt64(expiryUnix)
    proof.append(Data(repeating: 0x44, count: 32))
    proof.append(Data(repeating: 0x55, count: 48))
    proof.appendOpaque16(makeTokenMetadata(tokenKeyID: tokenKeyID, issuerMetadataHash: issuerMetadataHash))
    proof.appendOpaque16(tokenAuthenticator)
    proof.appendOpaque16(Data())
    proof.appendVarint(0)
    return proof
}

private func makeTokenMetadata(tokenKeyID: Data, issuerMetadataHash: Data) -> Data {
    var metadata = Data()
    metadata.appendUInt16(0x0002)
    metadata.append(Data(repeating: 0x66, count: 32))
    metadata.append(tokenKeyID)
    metadata.appendOpaque16(Data("issuer".utf8))
    metadata.appendOpaque16(Data("origin".utf8))
    metadata.append(issuerMetadataHash)
    return metadata
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt64(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xff))
        append(UInt8((value >> 48) & 0xff))
        append(UInt8((value >> 40) & 0xff))
        append(UInt8((value >> 32) & 0xff))
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendOpaque16(_ value: Data) {
        append(UInt8((value.count >> 8) & 0xff))
        append(UInt8(value.count & 0xff))
        append(value)
    }

    mutating func appendVarint(_ value: UInt64) {
        switch value {
        case 0...63:
            append(UInt8(value))
        case 64...16_383:
            let encoded = UInt16(value) | 0x4000
            append(UInt8((encoded >> 8) & 0xff))
            append(UInt8(encoded & 0xff))
        case 16_384...1_073_741_823:
            let encoded = UInt32(value) | 0x8000_0000
            append(UInt8((encoded >> 24) & 0xff))
            append(UInt8((encoded >> 16) & 0xff))
            append(UInt8((encoded >> 8) & 0xff))
            append(UInt8(encoded & 0xff))
        default:
            let encoded = value | 0xc000_0000_0000_0000
            appendUInt64(encoded)
        }
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

private actor MockBlockingPacketFlow: AuroraPacketFlow {
    private var continuation: CheckedContinuation<AuroraPacketFlowBatch?, Never>?
    private let writeResult: Bool
    private(set) var writtenBatches: [AuroraPacketFlowBatch] = []

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

private actor MockBlockingWritePacketFlow: AuroraPacketFlow {
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

private actor MockBlockingConnectPacketTunnelCore: AuroraPacketTunnelCore {
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

private actor MockTerminationRecorder {
    private(set) var recordedFailures: [AuroraPacketTunnelRuntimeTermination] = []

    func record(_ failure: AuroraPacketTunnelRuntimeTermination) {
        recordedFailures.append(failure)
    }
}

private actor MockAsyncOperationRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor MockPacketTunnelCore: AuroraPacketTunnelCore {
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

private actor MockRecoverablePacketTunnelCore: AuroraPacketTunnelCore, AuroraPacketTunnelRecoverableCore {
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

private actor MockBlockingRecoverablePacketTunnelCore: AuroraPacketTunnelCore, AuroraPacketTunnelRecoverableCore {
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

private actor MockBlockingRecoverableOutputCore: AuroraPacketTunnelCore, AuroraPacketTunnelOutputCore, AuroraPacketTunnelRecoverableCore {
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

private actor MockStreamingPacketTunnelCore: AuroraPacketTunnelCore, AuroraPacketTunnelOutputCore {
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

private actor MockFailingOutputPacketTunnelCore: AuroraPacketTunnelCore, AuroraPacketTunnelOutputCore {
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

private actor MockBlockingOutputPacketTunnelCore: AuroraPacketTunnelCore, AuroraPacketTunnelOutputCore {
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
