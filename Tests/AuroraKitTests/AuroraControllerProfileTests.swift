import Foundation
import XCTest
@testable import AuroraKit

final class AuroraControllerProfileTests: XCTestCase {
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

}
