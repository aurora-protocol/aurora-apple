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

public extension URLSessionAuroraServerClient {
    func fetchIssuerMetadata(endpoint: URL) async throws -> AuroraIssuerMetadataEnvelope {
        let url = endpoint
            .appendingPathComponent("issuer")
            .appendingPathComponent("issuer-metadata")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuroraClientError.unavailable
        }
        let envelope = try JSONDecoder().decode(IssuerMetadataResponse.self, from: data)
        let issuerMetadata = try Data(auroraHexString: envelope.issuerMetadata)
        let issuerMetadataHash = try Data(auroraHexString: envelope.issuerMetadataHash)
        guard !issuerMetadata.isEmpty else {
            throw AuroraClientError.invalidIssuerResponse("issuer metadata is empty")
        }
        guard issuerMetadataHash.count == 48 else {
            throw AuroraClientError.invalidIssuerResponse("issuer metadata hash length \(issuerMetadataHash.count), want 48")
        }
        return AuroraIssuerMetadataEnvelope(
            issuerMetadata: issuerMetadata,
            issuerMetadataHash: issuerMetadataHash
        )
    }

    func issueBlindRSAAdmissionToken(
        endpoint: URL,
        request: AuroraBlindRSAIssueRequest
    ) async throws -> AuroraIssuedAdmissionToken {
        try request.validate()
        let url = endpoint
            .appendingPathComponent("issuer")
            .appendingPathComponent("blind-rsa")
            .appendingPathComponent("issue")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(BlindRSAIssueBody(request: request))

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuroraClientError.unavailable
        }
        let envelope = try JSONDecoder().decode(BlindRSAIssueResponse.self, from: data)
        let admissionProof = try Data(auroraHexString: envelope.admissionProof)
        let fields = try AuroraAdmissionProofParser.parse(admissionProof)
        return AuroraIssuedAdmissionToken(
            admissionProof: admissionProof,
            relayBucketID: fields.relayBucketID,
            tokenAuthenticator: fields.tokenAuthenticator,
            issuerMetadataHash: fields.issuerMetadataHash,
            expiryUnix: fields.expiryUnix
        )
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

private struct IssuerMetadataResponse: Decodable {
    var issuerMetadata: String
    var issuerMetadataHash: String

    enum CodingKeys: String, CodingKey {
        case issuerMetadata = "issuer_metadata"
        case issuerMetadataHash = "issuer_metadata_hash"
    }
}

private struct BlindRSAIssueBody: Encodable {
    var tokenNonce: String
    var redemptionContextHash: String
    var expiryUnix: Int64

    init(request: AuroraBlindRSAIssueRequest) {
        tokenNonce = request.tokenNonce.auroraHexString
        redemptionContextHash = request.redemptionContextHash.auroraHexString
        expiryUnix = request.expiryUnix
    }

    enum CodingKeys: String, CodingKey {
        case tokenNonce = "token_nonce"
        case redemptionContextHash = "redemption_context_hash"
        case expiryUnix = "expiry_unix"
    }
}

private struct BlindRSAIssueResponse: Decodable {
    var admissionProof: String

    enum CodingKeys: String, CodingKey {
        case admissionProof = "admission_proof"
    }
}

private struct AuroraAdmissionProofFields {
    var relayBucketID: Data
    var tokenAuthenticator: Data
    var issuerMetadataHash: Data
    var expiryUnix: Int64
}

private struct AuroraTokenMetadataFields {
    var tokenType: UInt64
    var tokenKeyID: Data
    var issuerMetadataHash: Data
}

private enum AuroraAdmissionProofParser {
    private static let proofVersion: UInt64 = 0x000200
    private static let blindRSAProofType: UInt64 = 0x0002

    static func parse(_ data: Data) throws -> AuroraAdmissionProofFields {
        var reader = AuroraWireReader(data)
        let version = try reader.readVarint()
        let proofType = try reader.readVarint()
        guard version == proofVersion else {
            throw AuroraClientError.invalidAdmissionProof("unsupported proof version")
        }
        guard proofType == blindRSAProofType else {
            throw AuroraClientError.invalidAdmissionProof("unsupported proof type")
        }
        _ = try reader.readData(count: 16)
        let tokenKeyID = try reader.readData(count: 32)
        let relayBucketID = try reader.readData(count: 16)
        _ = try reader.readData(count: 16)
        let expiry = try reader.readUInt64()
        guard expiry <= UInt64(Int64.max) else {
            throw AuroraClientError.invalidAdmissionProof("expiry exceeds supported range")
        }
        _ = try reader.readData(count: 32)
        _ = try reader.readData(count: 48)
        let tokenPublicMetadata = try reader.readOpaque16()
        let tokenMetadata = try AuroraTokenMetadataParser.parse(tokenPublicMetadata)
        guard tokenMetadata.tokenType == blindRSAProofType else {
            throw AuroraClientError.invalidAdmissionProof("token metadata proof type mismatch")
        }
        guard tokenMetadata.tokenKeyID == tokenKeyID else {
            throw AuroraClientError.invalidAdmissionProof("token metadata key id mismatch")
        }
        let tokenAuthenticator = try reader.readOpaque16()
        _ = try reader.readOpaque16()
        let extensionCount = try reader.readVarint()
        guard extensionCount <= UInt64(reader.remainingBytes) else {
            throw AuroraClientError.invalidAdmissionProof("extension count exceeds proof length")
        }
        for _ in 0..<extensionCount {
            _ = try reader.readVarint()
            let critical = try reader.readUInt8()
            guard critical == 0 || critical == 1 else {
                throw AuroraClientError.invalidAdmissionProof("invalid extension critical flag")
            }
            _ = try reader.readOpaque24()
        }
        try reader.ensureFinished()
        guard !tokenAuthenticator.isEmpty else {
            throw AuroraClientError.invalidAdmissionProof("token authenticator is empty")
        }
        return AuroraAdmissionProofFields(
            relayBucketID: relayBucketID,
            tokenAuthenticator: tokenAuthenticator,
            issuerMetadataHash: tokenMetadata.issuerMetadataHash,
            expiryUnix: Int64(expiry)
        )
    }
}

private enum AuroraTokenMetadataParser {
    static func parse(_ data: Data) throws -> AuroraTokenMetadataFields {
        var reader = AuroraWireReader(data)
        let tokenType = UInt64(try reader.readUInt16())
        _ = try reader.readData(count: 32)
        let tokenKeyID = try reader.readData(count: 32)
        _ = try reader.readOpaque16()
        _ = try reader.readOpaque16()
        let issuerMetadataHash = try reader.readData(count: 48)
        try reader.ensureFinished()
        return AuroraTokenMetadataFields(
            tokenType: tokenType,
            tokenKeyID: tokenKeyID,
            issuerMetadataHash: issuerMetadataHash
        )
    }
}

private struct AuroraWireReader {
    private var bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var remainingBytes: Int {
        bytes.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        let out = try readData(count: 1)
        return out[0]
    }

    mutating func readUInt64() throws -> UInt64 {
        let data = try readData(count: 8)
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readVarint() throws -> UInt64 {
        let first = try readUInt8()
        switch first >> 6 {
        case 0:
            return UInt64(first)
        case 1:
            let second = try readUInt8()
            let value = UInt64(first & 0x3f) << 8 | UInt64(second)
            guard value > 63 else {
                throw AuroraClientError.invalidAdmissionProof("non-minimal varint")
            }
            return value
        case 2:
            let tail = try readData(count: 3)
            let value = UInt64(first & 0x3f) << 24
                | UInt64(tail[0]) << 16
                | UInt64(tail[1]) << 8
                | UInt64(tail[2])
            guard value > 16_383 else {
                throw AuroraClientError.invalidAdmissionProof("non-minimal varint")
            }
            return value
        default:
            let tail = try readData(count: 7)
            let value = UInt64(first & 0x3f) << 56
                | UInt64(tail[0]) << 48
                | UInt64(tail[1]) << 40
                | UInt64(tail[2]) << 32
                | UInt64(tail[3]) << 24
                | UInt64(tail[4]) << 16
                | UInt64(tail[5]) << 8
                | UInt64(tail[6])
            guard value > 1_073_741_823 else {
                throw AuroraClientError.invalidAdmissionProof("non-minimal varint")
            }
            return value
        }
    }

    mutating func readOpaque16() throws -> Data {
        let length = try readUInt16()
        return try readData(count: Int(length))
    }

    mutating func readOpaque24() throws -> Data {
        let data = try readData(count: 3)
        let length = Int(data[0]) << 16 | Int(data[1]) << 8 | Int(data[2])
        return try readData(count: length)
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= bytes.count else {
            throw AuroraClientError.invalidAdmissionProof("short proof")
        }
        let out = Data(bytes[offset..<(offset + count)])
        offset += count
        return out
    }

    mutating func ensureFinished() throws {
        guard offset == bytes.count else {
            throw AuroraClientError.invalidAdmissionProof("trailing proof bytes")
        }
    }

    mutating func readUInt16() throws -> UInt16 {
        let data = try readData(count: 2)
        return UInt16(data[0]) << 8 | UInt16(data[1])
    }
}

private enum AuroraRandom {
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
