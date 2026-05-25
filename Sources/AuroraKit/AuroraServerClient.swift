import Foundation

public protocol AuroraServerClient: Sendable {
    func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus
}

public struct URLSessionAuroraServerClient: AuroraServerClient {
    public init() {}

    public func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus {
        let url = endpoint.appendingPathComponent("healthz")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuroraClientError.unavailable
        }
        return try JSONDecoder().decode(AuroraServerStatus.self, from: data)
    }
}

public enum AuroraClientError: Error, Equatable {
    case unavailable
}
