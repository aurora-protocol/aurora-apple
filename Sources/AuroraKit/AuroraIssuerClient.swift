import Foundation

#if canImport(Security)
import Security
#endif

public protocol AuroraIssuerClient: Sendable {
    func fetchIssuerMetadata(endpoint: URL) async throws -> AuroraIssuerMetadataEnvelope
    func issueBlindRSAAdmissionToken(
        endpoint: URL,
        request: AuroraBlindRSAIssueRequest
    ) async throws -> AuroraIssuedAdmissionToken
    func spendAdmissionToken(endpoint: URL, admissionProof: Data) async throws -> Data
}

public struct AuroraIssuerMetadataEnvelope: Equatable, Sendable {
    public var issuerMetadata: Data
    public var issuerMetadataHash: Data

    public init(issuerMetadata: Data, issuerMetadataHash: Data) {
        self.issuerMetadata = issuerMetadata
        self.issuerMetadataHash = issuerMetadataHash
    }
}

public struct AuroraBlindRSAIssueRequest: Equatable, Sendable {
    public var tokenNonce: Data
    public var redemptionContextHash: Data
    public var expiryUnix: Int64

    public init(tokenNonce: Data, redemptionContextHash: Data, expiryUnix: Int64) {
        self.tokenNonce = tokenNonce
        self.redemptionContextHash = redemptionContextHash
        self.expiryUnix = expiryUnix
    }
}

public struct AuroraIssuedAdmissionToken: Equatable, Sendable {
    public var admissionProof: Data
    public var relayBucketID: Data
    public var tokenAuthenticator: Data
    public var issuerMetadataHash: Data
    public var expiryUnix: Int64

    public init(
        admissionProof: Data,
        relayBucketID: Data,
        tokenAuthenticator: Data,
        issuerMetadataHash: Data = Data(),
        expiryUnix: Int64
    ) {
        self.admissionProof = admissionProof
        self.relayBucketID = relayBucketID
        self.tokenAuthenticator = tokenAuthenticator
        self.issuerMetadataHash = issuerMetadataHash
        self.expiryUnix = expiryUnix
    }

    public var relayBucketIDHex: String {
        relayBucketID.auroraHexString
    }

    public var redactedDiagnosticLine: String {
        AuroraRedactor.redact(
            "relay_bucket_id=\(relayBucketIDHex) admission_proof=<redacted> token_authenticator=<redacted> expires_at_unix=\(expiryUnix)"
        )
    }
}

// Issuance rides the cover-neutral carrier (Section 27.2 cover-issuance): the
// adapter performs only the HTTP POST of opaque octet-stream bodies. The
// portable core (AuroraCore) builds every request and parses every response,
// including AdmissionProof decoding and binding validation, so no Aurora wire
// logic lives in Swift (Section 35.10).
public extension URLSessionAuroraServerClient {
    func fetchIssuerMetadata(endpoint: URL) async throws -> AuroraIssuerMetadataEnvelope {
        guard let request = AuroraCore.encodeMetadataRequest() else {
            throw AuroraClientError.invalidIssuerResponse("failed to encode metadata request")
        }
        let response = try await carrierExchange(endpoint: endpoint, body: request)
        guard let envelope = AuroraCore.decodeMetadataResponse(response) else {
            throw AuroraClientError.invalidIssuerResponse("invalid issuer metadata response")
        }
        return AuroraIssuerMetadataEnvelope(
            issuerMetadata: envelope.issuerMetadata,
            issuerMetadataHash: envelope.issuerMetadataHash
        )
    }

    func issueBlindRSAAdmissionToken(
        endpoint: URL,
        request: AuroraBlindRSAIssueRequest
    ) async throws -> AuroraIssuedAdmissionToken {
        try request.validate()
        guard let body = AuroraCore.encodeIssueRequest(
            tokenNonce: request.tokenNonce,
            redemptionContextHash: request.redemptionContextHash,
            expiryUnix: request.expiryUnix
        ) else {
            throw AuroraClientError.invalidIssueRequest("failed to encode issue request")
        }
        let response = try await carrierExchange(endpoint: endpoint, body: body)
        guard let admissionProof = AuroraCore.decodeIssueResponse(response) else {
            throw AuroraClientError.invalidIssuerResponse("invalid issue response")
        }
        guard let fields = AuroraCore.parseAdmissionProof(admissionProof) else {
            throw AuroraClientError.invalidAdmissionProof("admission proof failed core validation")
        }
        return AuroraIssuedAdmissionToken(
            admissionProof: admissionProof,
            relayBucketID: fields.relayBucketID,
            tokenAuthenticator: fields.tokenAuthenticator,
            issuerMetadataHash: fields.issuerMetadataHash,
            expiryUnix: fields.expiryUnix
        )
    }

    func spendAdmissionToken(endpoint: URL, admissionProof: Data) async throws -> Data {
        guard !admissionProof.isEmpty else {
            throw AuroraClientError.invalidIssueRequest("admission proof is empty")
        }
        guard let body = AuroraCore.encodeSpendRequest(admissionProof: admissionProof) else {
            throw AuroraClientError.invalidIssueRequest("failed to encode spend request")
        }
        let response = try await carrierExchange(endpoint: endpoint, body: body)
        switch AuroraCore.decodeSpendResponse(response) {
        case .spent(let spentKey):
            return spentKey
        case .conflict:
            throw AuroraClientError.invalidIssuerResponse("token already spent")
        case .none:
            throw AuroraClientError.invalidIssuerResponse("invalid spend response")
        }
    }

    private func carrierExchange(endpoint: URL, body: Data) async throws -> Data {
        let url = endpoint
            .appendingPathComponent("assets")
            .appendingPathComponent("app.bin")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = body

        return try await AuroraBoundedHTTPResponse.read(
            session: session,
            request: request,
            maximumBytes: AuroraBoundedHTTPResponse.maximumIssuerResponseBytes
        ) { $0.statusCode == 200 }
    }
}

extension AuroraBlindRSAIssueRequest {
    static func random(nowUnix: Int64, lifetimeSeconds: Int64 = 300) throws -> AuroraBlindRSAIssueRequest {
        AuroraBlindRSAIssueRequest(
            tokenNonce: try AuroraRandom.data(count: 32),
            redemptionContextHash: try AuroraRandom.data(count: 48),
            expiryUnix: nowUnix + lifetimeSeconds
        )
    }

    func validate() throws {
        guard tokenNonce.count == 32 else {
            throw AuroraClientError.invalidIssueRequest("token nonce length \(tokenNonce.count), want 32")
        }
        guard redemptionContextHash.count == 48 else {
            throw AuroraClientError.invalidIssueRequest("redemption context hash length \(redemptionContextHash.count), want 48")
        }
        guard expiryUnix > 0 else {
            throw AuroraClientError.invalidIssueRequest("expiry must be positive")
        }
    }
}

enum AuroraRandom {
    static func data(count: Int) throws -> Data {
        guard count >= 0 else {
            throw AuroraClientError.invalidIssueRequest("random byte count is negative")
        }
        guard count > 0 else {
            return Data()
        }
        var data = Data(count: count)
        #if canImport(Security)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AuroraSecureCredentialStoreError.keychainStatus(status)
        }
        #else
        for index in data.indices {
            data[index] = UInt8.random(in: 0...UInt8.max)
        }
        #endif
        return data
    }
}

extension Data {
    init(auroraHexString hex: String) throws {
        guard hex.count.isMultiple(of: 2) else {
            throw AuroraClientError.invalidHex
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var pendingNibble: UInt8?
        for scalar in hex.unicodeScalars {
            guard let nibble = scalar.auroraHexValue else {
                throw AuroraClientError.invalidHex
            }
            if let high = pendingNibble {
                bytes.append((high << 4) | nibble)
                pendingNibble = nil
            } else {
                pendingNibble = nibble
            }
        }
        self.init(bytes)
    }

    var auroraHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension UnicodeScalar {
    var auroraHexValue: UInt8? {
        switch value {
        case 48...57:
            return UInt8(value - 48)
        case 65...70:
            return UInt8(value - 55)
        case 97...102:
            return UInt8(value - 87)
        default:
            return nil
        }
    }
}
