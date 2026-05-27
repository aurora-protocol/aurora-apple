import Foundation
import AuroraCoreFFI

/// Thin Swift bridge over the embedded portable Aurora core (AuroraCore.xcframework).
///
/// Per Aurora spec Section 35.10, wire encoding, AdmissionProof handling, and
/// the cover-issuance carrier codec are portable-core responsibilities. The
/// adapter never reimplements them in Swift; it calls into the core here and
/// only performs network I/O elsewhere.
enum AuroraCore {
    /// Cover-carrier surface path. In production this is derived from the
    /// verified CoverTemplate/RelayDescriptor; the prototype pins the default.
    static let carrierPath = "/assets/app.bin"

    private enum Op: Int32 {
        case encodeMetadataRequest = 1
        case encodeIssueRequest = 2
        case encodeSpendRequest = 3
        case decodeMetadataResponse = 4
        case decodeIssueResponse = 5
        case decodeSpendResponse = 6
        case parseAdmissionProof = 7
    }

    private enum Status: UInt8 {
        case ok = 0x00
        case conflict = 0x01
        case error = 0x02
    }

    private struct Result {
        var status: Status
        var payload: Data
    }

    enum SpendOutcome: Equatable {
        case spent(Data)
        case conflict
    }

    struct ParsedAdmissionProof: Equatable {
        var relayBucketID: Data
        var tokenAuthenticator: Data
        var issuerMetadataHash: Data
        var expiryUnix: Int64
    }

    struct MetadataEnvelope: Equatable {
        var issuerMetadata: Data
        var issuerMetadataHash: Data
    }

    // MARK: - Public operations

    static func encodeMetadataRequest() -> Data? {
        okPayload(call(.encodeMetadataRequest))
    }

    static func encodeIssueRequest(tokenNonce: Data, redemptionContextHash: Data, expiryUnix: Int64) -> Data? {
        guard tokenNonce.count == 32, redemptionContextHash.count == 48, expiryUnix > 0 else {
            return nil
        }
        return okPayload(call(.encodeIssueRequest, input: tokenNonce + redemptionContextHash, arg: UInt64(expiryUnix)))
    }

    static func encodeSpendRequest(admissionProof: Data) -> Data? {
        guard !admissionProof.isEmpty else { return nil }
        return okPayload(call(.encodeSpendRequest, input: admissionProof))
    }

    static func decodeMetadataResponse(_ body: Data) -> MetadataEnvelope? {
        guard let payload = okPayload(call(.decodeMetadataResponse, input: body)),
              let parsed = try? JSONDecoder().decode(MetadataResponseJSON.self, from: payload),
              let metadata = try? Data(auroraHexString: parsed.issuerMetadata),
              let hash = try? Data(auroraHexString: parsed.issuerMetadataHash),
              !metadata.isEmpty, hash.count == 48
        else { return nil }
        return MetadataEnvelope(issuerMetadata: metadata, issuerMetadataHash: hash)
    }

    static func decodeIssueResponse(_ body: Data) -> Data? {
        okPayload(call(.decodeIssueResponse, input: body))
    }

    static func decodeSpendResponse(_ body: Data) -> SpendOutcome? {
        guard let result = call(.decodeSpendResponse, input: body) else { return nil }
        switch result.status {
        case .ok where result.payload.count == 48:
            return .spent(result.payload)
        case .conflict:
            return .conflict
        default:
            return nil
        }
    }

    static func parseAdmissionProof(_ proof: Data) -> ParsedAdmissionProof? {
        guard let payload = okPayload(call(.parseAdmissionProof, input: proof)),
              let parsed = try? JSONDecoder().decode(AdmissionProofJSON.self, from: payload),
              let relayBucketID = try? Data(auroraHexString: parsed.relayBucketID),
              let tokenAuthenticator = try? Data(auroraHexString: parsed.tokenAuthenticator),
              let issuerMetadataHash = try? Data(auroraHexString: parsed.issuerMetadataHash),
              parsed.expiryUnix <= UInt64(Int64.max)
        else { return nil }
        return ParsedAdmissionProof(
            relayBucketID: relayBucketID,
            tokenAuthenticator: tokenAuthenticator,
            issuerMetadataHash: issuerMetadataHash,
            expiryUnix: Int64(parsed.expiryUnix)
        )
    }

    // MARK: - ABI plumbing

    private static func okPayload(_ result: Result?) -> Data? {
        guard let result, result.status == .ok else { return nil }
        return result.payload
    }

    private static func call(_ op: Op, input: Data = Data(), arg: UInt64 = 0) -> Result? {
        var outLen: Int32 = 0
        let raw: UnsafeMutablePointer<UInt8>?
        if input.isEmpty {
            raw = AuroraCoreCall(op.rawValue, nil, 0, arg, &outLen)
        } else {
            raw = input.withUnsafeBytes { buffer -> UnsafeMutablePointer<UInt8>? in
                let base = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return AuroraCoreCall(op.rawValue, UnsafeMutablePointer(mutating: base), Int32(input.count), arg, &outLen)
            }
        }
        guard let ptr = raw else { return nil }
        defer { AuroraCoreFree(ptr) }
        guard outLen >= 1, let status = Status(rawValue: ptr[0]) else { return nil }
        let payload = outLen > 1 ? Data(bytes: ptr + 1, count: Int(outLen) - 1) : Data()
        return Result(status: status, payload: payload)
    }

    private struct MetadataResponseJSON: Decodable {
        var issuerMetadata: String
        var issuerMetadataHash: String

        enum CodingKeys: String, CodingKey {
            case issuerMetadata = "issuer_metadata"
            case issuerMetadataHash = "issuer_metadata_hash"
        }
    }

    private struct AdmissionProofJSON: Decodable {
        var relayBucketID: String
        var tokenAuthenticator: String
        var issuerMetadataHash: String
        var expiryUnix: UInt64

        enum CodingKeys: String, CodingKey {
            case relayBucketID = "relay_bucket_id"
            case tokenAuthenticator = "token_authenticator"
            case issuerMetadataHash = "issuer_metadata_hash"
            case expiryUnix = "expiry_unix"
        }
    }
}
