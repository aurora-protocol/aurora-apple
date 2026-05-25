import Foundation

public struct AuroraIPv4Route: Equatable, Sendable {
    public var destinationAddress: String
    public var subnetMask: String

    public init(destinationAddress: String, subnetMask: String) {
        self.destinationAddress = destinationAddress
        self.subnetMask = subnetMask
    }
}

public struct AuroraPacketTunnelConfiguration: Equatable, Sendable {
    public var endpoint: URL
    public var tunnelRemoteAddress: String
    public var ipv4Address: String
    public var ipv4SubnetMask: String
    public var mtu: Int
    public var dnsServers: [String]
    public var includeDefaultIPv4Route: Bool
    public var excludedIPv4Routes: [AuroraIPv4Route]
    public var captureAllDNSDomains: Bool

    public init(
        configuration: AuroraConfiguration,
        tunnelRemoteAddress: String = "",
        ipv4Address: String = "10.77.0.2",
        ipv4SubnetMask: String = "255.255.255.255",
        mtu: Int = 1280,
        dnsServers: [String] = ["100.64.0.1"],
        includeDefaultIPv4Route: Bool = true,
        excludedIPv4Routes: [AuroraIPv4Route]? = nil,
        captureAllDNSDomains: Bool = true
    ) {
        self.endpoint = configuration.endpoint
        self.tunnelRemoteAddress = Self.resolveRemoteAddress(
            explicitAddress: tunnelRemoteAddress,
            endpoint: configuration.endpoint
        )
        self.ipv4Address = ipv4Address
        self.ipv4SubnetMask = ipv4SubnetMask
        self.mtu = mtu
        self.dnsServers = dnsServers
        self.includeDefaultIPv4Route = includeDefaultIPv4Route
        self.excludedIPv4Routes = excludedIPv4Routes ?? Self.defaultExcludedIPv4Routes(
            explicitAddress: tunnelRemoteAddress,
            endpoint: configuration.endpoint
        )
        self.captureAllDNSDomains = captureAllDNSDomains
    }

    private static func resolveRemoteAddress(explicitAddress: String, endpoint: URL) -> String {
        let trimmed = explicitAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let host = endpoint.host(), !host.isEmpty {
            return host
        }
        return endpoint.absoluteString
    }

    private static func defaultExcludedIPv4Routes(explicitAddress: String, endpoint: URL) -> [AuroraIPv4Route] {
        let candidate = explicitAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if isIPv4Literal(candidate) {
            return [AuroraIPv4Route(destinationAddress: candidate, subnetMask: "255.255.255.255")]
        }
        guard let host = endpoint.host(), isIPv4Literal(host) else {
            return []
        }
        return [AuroraIPv4Route(destinationAddress: host, subnetMask: "255.255.255.255")]
    }

    private static func isIPv4Literal(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }
        return parts.allSatisfy { part in
            guard !part.isEmpty, let octet = Int(part), octet >= 0, octet <= 255 else {
                return false
            }
            return String(octet) == part
        }
    }
}
