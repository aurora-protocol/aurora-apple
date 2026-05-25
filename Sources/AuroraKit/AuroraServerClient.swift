import Foundation

public protocol AuroraServerClient: Sendable {
    func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus
}

public struct URLSessionAuroraServerClient: AuroraServerClient, AuroraPacketExchangeClient, AuroraIssuerClient, @unchecked Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus {
        let url = endpoint.appendingPathComponent("healthz")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuroraClientError.unavailable
        }
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              Self.isPacketExchangeContentType(http.value(forHTTPHeaderField: "Content-Type"))
        else {
            throw AuroraClientError.unavailable
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

public enum AuroraClientError: Error, Equatable {
    case unavailable
    case invalidHex
    case invalidIssueRequest(String)
    case invalidIssuerResponse(String)
    case invalidAdmissionProof(String)
}
