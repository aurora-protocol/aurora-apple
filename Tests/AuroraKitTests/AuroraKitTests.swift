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
                path: "/issuer/issuer-metadata",
                contentType: "application/json",
                body: #"{"issuer_metadata":"\#(issuerMetadata.auroraHexString)","issuer_metadata_hash":"\#(issuerMetadataHash.auroraHexString)"}"#.data(using: .utf8)!
            ),
            IssuerURLProtocol.Response(
                path: "/issuer/blind-rsa/issue",
                contentType: "application/json",
                body: #"{"admission_proof":"\#(admissionProof.auroraHexString)"}"#.data(using: .utf8)!
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
        XCTAssertEqual(requests.map { $0.request.url?.path }, ["/issuer/issuer-metadata", "/issuer/blind-rsa/issue"])
        XCTAssertEqual(requests[0].request.httpMethod, "GET")
        XCTAssertEqual(requests[1].request.httpMethod, "POST")
        XCTAssertEqual(requests[1].request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let issueBody = try XCTUnwrap(requests[1].body)
        let issueJSON = try JSONSerialization.jsonObject(with: issueBody) as? [String: Any]
        XCTAssertEqual(issueJSON?["token_nonce"] as? String, tokenNonce.auroraHexString)
        XCTAssertEqual(issueJSON?["redemption_context_hash"] as? String, redemptionContextHash.auroraHexString)
        XCTAssertEqual(issueJSON?["expiry_unix"] as? Int, 1_800_000_000)
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

    func testServerBackedPacketTunnelCoreIssuesAdmissionTokenBeforePacketExchange() async throws {
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
        let saved = try await wallet.load(relayBucketID: Data(repeating: 0x81, count: 16).auroraHexString)
        XCTAssertEqual(requestedIssue?.tokenNonce.count, 32)
        XCTAssertEqual(requestedIssue?.redemptionContextHash.count, 48)
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
        XCTAssertTrue(provider.contains("AuroraUserDefaultsProfileStore"), "packet tunnel provider missing App Group profile store")
        XCTAssertTrue(provider.contains("AuroraAppleSharedContainer.appGroupIdentifier()"), "packet tunnel provider missing App Group scope")
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

private actor MockIssuerClient: AuroraIssuerClient {
    private let issuedToken: AuroraIssuedAdmissionToken?
    private let error: (any Error)?
    private(set) var requestedEndpoint: URL?
    private(set) var requestedIssue: AuroraBlindRSAIssueRequest?

    init(issuedToken: AuroraIssuedAdmissionToken) {
        self.issuedToken = issuedToken
        self.error = nil
    }

    init(error: any Error) {
        self.issuedToken = nil
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
