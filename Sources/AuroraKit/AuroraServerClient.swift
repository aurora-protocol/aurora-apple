import Foundation

public protocol AuroraServerClient: Sendable {
    func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus
}

public struct URLSessionAuroraServerClient: AuroraServerClient, AuroraPacketExchangeClient, AuroraIssuerClient, @unchecked Sendable {
    private static let maximumStatusResponseBytes = 64 << 10
    private static let maximumPacketBatchResponseBytes = 64 * (2 + 4 + 65_535) + 2
    private static let maximumCarrierResponseBytes = 1 << 20

    let session: URLSession
    private let noRedirectDelegate: AuroraNoRedirectSessionDelegate?

    public init() {
        let configuration = Self.defaultSessionConfiguration()
        let delegate = AuroraNoRedirectSessionDelegate()
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.noRedirectDelegate = delegate
    }

    public init(session: URLSession) {
        self.session = session
        noRedirectDelegate = nil
    }

    public func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus {
        let url = endpoint.appendingPathComponent("healthz")
        let (data, _) = try await responseData(
            for: URLRequest(url: url),
            maximumResponseBytes: Self.maximumStatusResponseBytes,
            accepting: { $0.statusCode == 200 }
        )
        return try JSONDecoder().decode(AuroraServerStatus.self, from: data)
    }

    public func exchangePacketBatch(endpoint: URL, batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        let url = endpoint
            .appendingPathComponent("assets")
            .appendingPathComponent("app.bin")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = try AuroraPacketBatchCodec.encode(batch)

        let (data, _) = try await responseData(
            for: request,
            maximumResponseBytes: Self.maximumPacketBatchResponseBytes,
            accepting: {
                $0.statusCode == 200 && Self.isPacketExchangeContentType($0.value(forHTTPHeaderField: "Content-Type"))
            }
        )
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

    func carrierResponse(endpoint: URL, body: Data) async throws -> Data {
        let url = endpoint
            .appendingPathComponent("assets")
            .appendingPathComponent("app.bin")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, _) = try await responseData(
            for: request,
            maximumResponseBytes: Self.maximumCarrierResponseBytes,
            accepting: { $0.statusCode == 200 }
        )
        return data
    }

    private func responseData(
        for request: URLRequest,
        maximumResponseBytes: Int,
        accepting: (HTTPURLResponse) -> Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.expectedContentLength <= Int64(maximumResponseBytes),
              accepting(http)
        else {
            throw AuroraClientError.unavailable
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw AuroraClientError.unavailable
            }
            data.append(byte)
        }
        return (data, http)
    }

    private static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return configuration
    }
}

public enum AuroraClientError: Error, Equatable {
    case unavailable
    case invalidHex
    case invalidIssueRequest(String)
    case invalidIssuerResponse(String)
    case invalidAdmissionProof(String)
}
