import Foundation
import XCTest
@testable import AuroraKit

final class AuroraPacketCodecAndServerClientTests: XCTestCase {
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

    /// The packet path calls validate in place of encoding a batch it discards,
    /// so validate has to enforce every rule itself. Each case states its own
    /// expected outcome rather than comparing against encode, which now
    /// delegates to validate and so cannot disagree with it.
    func testPacketBatchCodecValidateEnforcesBatchRules() throws {
        let ipv4 = Data([0x45, 0x00, 0x00, 0x14])
        let ipv6 = Data([0x60, 0x00, 0x00, 0x00])
        struct ValidationCase {
            let name: String
            let batch: AuroraPacketFlowBatch
            let valid: Bool
        }
        let cases: [ValidationCase] = [
            ValidationCase(name: "empty", batch: AuroraPacketFlowBatch(packets: [], protocolNumbers: []), valid: true),
            ValidationCase(name: "ipv4", batch: AuroraPacketFlowBatch(packets: [ipv4], protocolNumbers: [2]), valid: true),
            ValidationCase(name: "mixed", batch: AuroraPacketFlowBatch(packets: [ipv4, ipv6], protocolNumbers: [2, 30]), valid: true),
            ValidationCase(name: "at maximum", batch: AuroraPacketFlowBatch(
                packets: Array(repeating: ipv4, count: 64),
                protocolNumbers: Array(repeating: 2, count: 64)
            ), valid: true),
            ValidationCase(name: "count mismatch", batch: AuroraPacketFlowBatch(packets: [ipv4], protocolNumbers: [2, 30]), valid: false),
            ValidationCase(name: "family mismatch", batch: AuroraPacketFlowBatch(packets: [ipv4], protocolNumbers: [30]), valid: false),
            ValidationCase(name: "not ip", batch: AuroraPacketFlowBatch(
                packets: [Data([0x05, 0x00, 0x00, 0x14])],
                protocolNumbers: [0]
            ), valid: false),
            ValidationCase(name: "empty packet", batch: AuroraPacketFlowBatch(packets: [Data()], protocolNumbers: [2]), valid: false),
            ValidationCase(name: "above maximum", batch: AuroraPacketFlowBatch(
                packets: Array(repeating: ipv4, count: 65),
                protocolNumbers: Array(repeating: 2, count: 65)
            ), valid: false),
        ]

        for testCase in cases {
            let accepted = (try? AuroraPacketBatchCodec.validate(testCase.batch)) != nil
            XCTAssertEqual(accepted, testCase.valid, "validate accepted=\(accepted) for \(testCase.name)")
        }
    }

    func testPacketBatchCodecEncodeStillProducesTheSameBytes() throws {
        let batch = AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14]), Data([0x60, 0x00, 0x00, 0x00])],
            protocolNumbers: [2, 30]
        )
        let encoded = try AuroraPacketBatchCodec.encode(batch)
        XCTAssertEqual(try AuroraPacketBatchCodec.decode(encoded), batch)
        let hex = encoded.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "000200020000000445000014001e0000000460000000")
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

    func testURLSessionServerClientDefaultSessionIsPrivateAndBounded() {
        let client = URLSessionAuroraServerClient()
        let configuration = client.session.configuration

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
    }

    func testURLSessionServerClientRejectsOversizedPacketResponseAtHeaders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedPacketResponseURLProtocol.self]
        let client = URLSessionAuroraServerClient(session: URLSession(configuration: configuration))
        let completion = AsyncCompletionSignal()
        let inbound = AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [2]
        )
        let exchange = Task {
            defer {
                Task {
                    await completion.signal()
                }
            }
            _ = try? await client.exchangePacketBatch(
                endpoint: URL(string: "https://relay.example:9443")!,
                batch: inbound
            )
        }

        for _ in 0..<20 {
            if await completion.isSignaled {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let completedBeforeBody = await completion.isSignaled
        exchange.cancel()
        _ = await exchange.result

        XCTAssertTrue(completedBeforeBody)
    }

    func testURLSessionServerClientRejectsOversizedIssuerResponseAtHeaders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedIssuerResponseURLProtocol.self]
        let client = URLSessionAuroraServerClient(session: URLSession(configuration: configuration))
        let completion = AsyncCompletionSignal()
        let request = AuroraBlindRSAIssueRequest(
            tokenNonce: Data(repeating: 0xa1, count: 32),
            redemptionContextHash: Data(repeating: 0xb2, count: 48),
            expiryUnix: 1_800_000_000
        )
        let exchange = Task {
            defer {
                Task {
                    await completion.signal()
                }
            }
            _ = try? await client.issueBlindRSAAdmissionToken(
                endpoint: URL(string: "https://relay.example:9443")!,
                request: request
            )
        }

        for _ in 0..<20 {
            if await completion.isSignaled {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let completedBeforeBody = await completion.isSignaled
        exchange.cancel()
        _ = await exchange.result

        XCTAssertTrue(completedBeforeBody)
    }

    func testURLSessionServerClientRejectsOversizedIssuerResponseWithoutContentLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IssuerURLProtocol.self]
        let client = URLSessionAuroraServerClient(session: URLSession(configuration: configuration))
        IssuerURLProtocol.setResponses([
            IssuerURLProtocol.Response(
                path: "/assets/app.bin",
                contentType: "application/octet-stream",
                body: Data(repeating: 0xa1, count: (1 << 20) + 1)
            ),
        ])

        do {
            _ = try await client.fetchIssuerMetadata(endpoint: URL(string: "https://relay.example:9443")!)
            XCTFail("oversized issuer response unexpectedly succeeded")
        } catch {
            XCTAssertNotNil(error)
        }
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

}
