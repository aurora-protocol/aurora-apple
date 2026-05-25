import Foundation

public struct AuroraConfiguration: Equatable, Sendable {
    public var endpoint: URL
    public var routePolicy: String

    public init(endpoint: URL, routePolicy: String = "balanced") {
        self.endpoint = endpoint
        self.routePolicy = routePolicy
    }

    public static func validatedEndpoint(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil
        else {
            return nil
        }
        return url
    }
}

public struct AuroraServerStatus: Codable, Equatable, Sendable {
    public var ready: Bool
    public var issuer: Bool
    public var cover: Bool

    public init(ready: Bool, issuer: Bool, cover: Bool) {
        self.ready = ready
        self.issuer = issuer
        self.cover = cover
    }

    public var summary: String {
        ready ? "ready" : "unavailable"
    }
}
