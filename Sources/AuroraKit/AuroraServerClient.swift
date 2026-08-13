import Foundation

public protocol AuroraServerClient: Sendable {
    func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus
}

public struct URLSessionAuroraServerClient: AuroraServerClient, AuroraPacketExchangeClient, AuroraIssuerClient, @unchecked Sendable {
    let session: URLSession
    private let noRedirectDelegate: AuroraNoRedirectSessionDelegate?

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            noRedirectDelegate = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            let delegate = AuroraNoRedirectSessionDelegate()
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            noRedirectDelegate = delegate
        }
    }

    public func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus {
        let url = endpoint.appendingPathComponent("healthz")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let data = try await AuroraBoundedHTTPResponse.read(
            session: session,
            request: request,
            maximumBytes: AuroraBoundedHTTPResponse.maximumHealthResponseBytes
        ) { $0.statusCode == 200 }
        return try JSONDecoder().decode(AuroraServerStatus.self, from: data)
    }

    public func exchangePacketBatch(endpoint: URL, batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        let url = endpoint
            .appendingPathComponent("assets")
            .appendingPathComponent("app.bin")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try AuroraPacketBatchCodec.encode(batch)

        let data = try await AuroraBoundedHTTPResponse.read(
            session: session,
            request: request,
            maximumBytes: AuroraPacketBatchCodec.maximumEncodedBytes
        ) { http in
            http.statusCode == 200 &&
                Self.isPacketExchangeContentType(http.value(forHTTPHeaderField: "Content-Type"))
        }
        return try AuroraPacketBatchCodec.decode(data)
    }

    private static func isPacketExchangeContentType(_ raw: String?) -> Bool {
        guard let raw else {
            return false
        }
        let mediaType = raw
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "application/octet-stream"
    }
}

enum AuroraBoundedHTTPResponse {
    static let maximumHealthResponseBytes = 64 << 10
    static let maximumIssuerResponseBytes = 1 << 20

    static func read(
        session: URLSession,
        request: URLRequest,
        maximumBytes: Int,
        responseIsAccepted: (HTTPURLResponse) -> Bool
    ) async throws -> Data {
        guard maximumBytes > 0 else {
            throw AuroraClientError.unavailable
        }
        let (responseBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              responseIsAccepted(http),
              http.expectedContentLength <= Int64(maximumBytes)
        else {
            throw AuroraClientError.unavailable
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in responseBytes {
            guard data.count < maximumBytes else {
                throw AuroraClientError.unavailable
            }
            data.append(byte)
        }
        return data
    }
}

public enum AuroraClientError: Error, Equatable {
    case unavailable
    case invalidHex
    case invalidIssueRequest(String)
    case invalidIssuerResponse(String)
    case invalidAdmissionProof(String)
}
