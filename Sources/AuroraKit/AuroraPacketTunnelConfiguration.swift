import Foundation

public struct AuroraPacketTunnelConfiguration: Equatable, Sendable {
    public var endpoint: URL
    public var tunnelRemoteAddress: String
    public var ipv4Address: String
    public var ipv4SubnetMask: String
    public var mtu: Int
    public var dnsServers: [String]
    public var includeDefaultIPv4Route: Bool
    public var captureAllDNSDomains: Bool

    public init(
        configuration: AuroraConfiguration,
        tunnelRemoteAddress: String = "",
        ipv4Address: String = "10.77.0.2",
        ipv4SubnetMask: String = "255.255.255.255",
        mtu: Int = 1280,
        dnsServers: [String] = ["100.64.0.1"],
        includeDefaultIPv4Route: Bool = true,
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
}
