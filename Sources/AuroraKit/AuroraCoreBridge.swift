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
        case beginNativeSession = 16
        case completeNativeSession = 17
        case closeNativeSession = 10
        case ingressLocalPacket = 18
        case nextLocalPacket = 15
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

    struct NativeIssuerWork: Decodable, Equatable, Sendable {
        var handle: UInt64
        var issuerURL: URL
        var issuerCarrierPath: String
        var requestBody: Data

        enum CodingKeys: String, CodingKey {
            case handle
            case issuerURL = "issuer_url"
            case issuerCarrierPath = "issuer_carrier_path"
            case requestBodyBase64 = "request_body_base64"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            handle = try container.decode(UInt64.self, forKey: .handle)
            issuerURL = try container.decode(URL.self, forKey: .issuerURL)
            issuerCarrierPath = try container.decode(String.self, forKey: .issuerCarrierPath)
            let body = try container.decode(String.self, forKey: .requestBodyBase64)
            guard handle != 0,
                  issuerURL.scheme?.lowercased() == "https",
                  issuerURL.user == nil,
                  issuerURL.password == nil,
                  !issuerCarrierPath.isEmpty,
                  issuerCarrierPath.hasPrefix("/"),
                  let requestBody = Data(base64Encoded: body),
                  !requestBody.isEmpty
            else {
                throw DecodingError.dataCorruptedError(forKey: .handle, in: container, debugDescription: "invalid native issuer work")
            }
            self.requestBody = requestBody
        }
    }

    private struct NativeLocalPackets: Decodable {
        var packetsBase64: [String]

        enum CodingKeys: String, CodingKey {
            case packetsBase64 = "packets_base64"
        }
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

    static func beginNativeSession(provisioning: Data) -> AuroraNativeIssuerWork? {
        guard !provisioning.isEmpty,
              let payload = okPayload(call(.beginNativeSession, input: provisioning)),
              let work = try? JSONDecoder().decode(NativeIssuerWork.self, from: payload)
        else {
            return nil
        }
        return AuroraNativeIssuerWork(
            handle: work.handle,
            issuerURL: work.issuerURL,
            issuerCarrierPath: work.issuerCarrierPath,
            requestBody: work.requestBody
        )
    }

    static func completeNativeSession(handle: UInt64, issuerResponse: Data) -> Bool {
        guard handle != 0, !issuerResponse.isEmpty else {
            return false
        }
        return okPayload(call(.completeNativeSession, input: issuerResponse, arg: handle)) != nil
    }

    static func closeNativeSession(handle: UInt64) -> Bool {
        guard handle != 0 else {
            return false
        }
        return okPayload(call(.closeNativeSession, arg: handle)) != nil
    }

    static func ingressLocalPacket(handle: UInt64, packet: Data) -> [Data]? {
        guard handle != 0,
              !packet.isEmpty,
              let payload = okPayload(call(.ingressLocalPacket, input: packet, arg: handle))
        else {
            return nil
        }
        guard let encoded = try? JSONDecoder().decode(NativeLocalPackets.self, from: payload),
              encoded.packetsBase64.count <= 64
        else {
            return nil
        }
        let packets = encoded.packetsBase64.compactMap { Data(base64Encoded: $0) }
        guard packets.count == encoded.packetsBase64.count,
              packets.allSatisfy({ !$0.isEmpty && $0.count <= 65_535 })
        else {
            return nil
        }
        return packets
    }

    static func nextLocalPacket(handle: UInt64) -> Data? {
        guard handle != 0 else {
            return nil
        }
        return okPayload(call(.nextLocalPacket, arg: handle))
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
