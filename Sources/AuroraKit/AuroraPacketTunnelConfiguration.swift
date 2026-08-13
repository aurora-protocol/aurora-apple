import Foundation
import Network

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct AuroraIPv4Route: Equatable, Sendable {
    public var destinationAddress: String
    public var subnetMask: String

    public init(destinationAddress: String, subnetMask: String) {
        self.destinationAddress = destinationAddress
        self.subnetMask = subnetMask
    }
}

public struct AuroraIPv6Route: Equatable, Sendable {
    public var destinationAddress: String
    public var networkPrefixLength: Int

    public init(destinationAddress: String, networkPrefixLength: Int) {
        self.destinationAddress = destinationAddress
        self.networkPrefixLength = networkPrefixLength
    }
}

public enum AuroraPacketTunnelConfigurationError: Error, Equatable, Sendable {
    case unresolvedTunnelEndpoint
    case invalidNetworkSettings
}

public struct AuroraPacketTunnelConfiguration: Equatable, Sendable {
    public var endpoint: URL
    public var tunnelRemoteAddress: String
    public var ipv4Address: String
    public var ipv4SubnetMask: String
    public var ipv6Address: String
    public var ipv6NetworkPrefixLength: Int
    public var mtu: Int
    public var dnsServers: [String]
    public var includeDefaultIPv4Route: Bool
    public var excludedIPv4Routes: [AuroraIPv4Route]
    public var includeDefaultIPv6Route: Bool
    public var excludedIPv6Routes: [AuroraIPv6Route]
    public var captureAllDNSDomains: Bool

    public init(
        configuration: AuroraConfiguration,
        tunnelRemoteAddress: String = "",
        ipv4Address: String = "10.77.0.2",
        ipv4SubnetMask: String = "255.255.255.255",
        ipv6Address: String = "fd77::2",
        ipv6NetworkPrefixLength: Int = 128,
        mtu: Int = 1280,
        dnsServers: [String] = ["100.64.0.1", "fd77::1"],
        includeDefaultIPv4Route: Bool = true,
        excludedIPv4Routes: [AuroraIPv4Route]? = nil,
        includeDefaultIPv6Route: Bool = true,
        excludedIPv6Routes: [AuroraIPv6Route]? = nil,
        captureAllDNSDomains: Bool = true
    ) {
        self.endpoint = configuration.endpoint
        self.tunnelRemoteAddress = Self.resolveRemoteAddress(
            explicitAddress: tunnelRemoteAddress,
            endpoint: configuration.endpoint
        )
        self.ipv4Address = ipv4Address
        self.ipv4SubnetMask = ipv4SubnetMask
        self.ipv6Address = ipv6Address
        self.ipv6NetworkPrefixLength = ipv6NetworkPrefixLength
        self.mtu = mtu
        self.dnsServers = dnsServers
        self.includeDefaultIPv4Route = includeDefaultIPv4Route
        self.excludedIPv4Routes = excludedIPv4Routes ?? Self.defaultExcludedIPv4Routes(
            explicitAddress: tunnelRemoteAddress,
            endpoint: configuration.endpoint
        )
        self.includeDefaultIPv6Route = includeDefaultIPv6Route
        self.excludedIPv6Routes = excludedIPv6Routes ?? Self.defaultExcludedIPv6Routes(
            explicitAddress: tunnelRemoteAddress,
            endpoint: configuration.endpoint
        )
        self.captureAllDNSDomains = captureAllDNSDomains
    }

    private static func resolveRemoteAddress(explicitAddress: String, endpoint: URL) -> String {
        let trimmed = explicitAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return normalizedIPAddress(trimmed) ?? trimmed
        }
        if let host = endpoint.host(), !host.isEmpty {
            return normalizedIPAddress(host) ?? host
        }
        return endpoint.absoluteString
    }

    func applyingResolvedRemoteAddresses(_ addresses: [String]) throws -> Self {
        let resolved = Self.uniqueNumericAddresses(addresses)
        guard let remoteAddress = resolved.first else {
            throw AuroraPacketTunnelConfigurationError.unresolvedTunnelEndpoint
        }
        var configuration = self
        configuration.tunnelRemoteAddress = remoteAddress
        for address in resolved {
            if IPv4Address(address) != nil {
                let route = AuroraIPv4Route(destinationAddress: address, subnetMask: "255.255.255.255")
                if !configuration.excludedIPv4Routes.contains(route) {
                    configuration.excludedIPv4Routes.append(route)
                }
                continue
            }
            let route = AuroraIPv6Route(destinationAddress: address, networkPrefixLength: 128)
            if !configuration.excludedIPv6Routes.contains(route) {
                configuration.excludedIPv6Routes.append(route)
            }
        }
        return try configuration.validatedForNetworkSettings()
    }

    @discardableResult
    public func validatedForNetworkSettings() throws -> Self {
        guard Self.normalizedIPAddress(tunnelRemoteAddress) != nil,
              IPv4Address(ipv4Address) != nil,
              IPv4Address(ipv4SubnetMask) != nil,
              IPv6Address(ipv6Address) != nil,
              (0...128).contains(ipv6NetworkPrefixLength),
              (1280...9000).contains(mtu),
              !dnsServers.isEmpty,
              dnsServers.allSatisfy({ Self.normalizedIPAddress($0) != nil }),
              excludedIPv4Routes.allSatisfy({
                  IPv4Address($0.destinationAddress) != nil && IPv4Address($0.subnetMask) != nil
              }),
              excludedIPv6Routes.allSatisfy({
                  IPv6Address($0.destinationAddress) != nil && (0...128).contains($0.networkPrefixLength)
              }) else {
            throw AuroraPacketTunnelConfigurationError.invalidNetworkSettings
        }
        return self
    }

    static func normalizedIPAddress(_ value: String) -> String? {
        let candidate = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !candidate.isEmpty, IPv4Address(candidate) != nil || IPv6Address(candidate) != nil else {
            return nil
        }
        return candidate
    }

    private static func uniqueNumericAddresses(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.compactMap(normalizedIPAddress).filter { seen.insert($0).inserted }
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

    private static func defaultExcludedIPv6Routes(explicitAddress: String, endpoint: URL) -> [AuroraIPv6Route] {
        if let literal = normalizedIPv6Literal(explicitAddress) {
            return [AuroraIPv6Route(destinationAddress: literal, networkPrefixLength: 128)]
        }
        guard let host = endpoint.host(), let literal = normalizedIPv6Literal(host) else {
            return []
        }
        return [AuroraIPv6Route(destinationAddress: literal, networkPrefixLength: 128)]
    }

    private static func normalizedIPv6Literal(_ value: String) -> String? {
        let candidate = normalizedIPAddress(value) ?? ""
        guard !candidate.isEmpty, IPv6Address(candidate) != nil else {
            return nil
        }
        return candidate
    }
}

public final class AuroraTunnelEndpointResolver: @unchecked Sendable {
    public init() {}

    public func resolve(_ configuration: AuroraPacketTunnelConfiguration) async throws -> AuroraPacketTunnelConfiguration {
        try Task.checkCancellation()
        if let address = AuroraPacketTunnelConfiguration.normalizedIPAddress(configuration.tunnelRemoteAddress) {
            return try configuration.applyingResolvedRemoteAddresses([address])
        }
        let host = configuration.tunnelRemoteAddress
        let addresses = try await Task.detached(priority: .userInitiated) {
            try Self.lookupNumericAddresses(host)
        }.value
        try Task.checkCancellation()
        return try configuration.applyingResolvedRemoteAddresses(addresses)
    }

    private static func lookupNumericAddresses(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let result else {
            throw AuroraPacketTunnelConfigurationError.unresolvedTunnelEndpoint
        }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let current = cursor {
            let entry = current.pointee
            guard let socketAddress = entry.ai_addr else {
                cursor = entry.ai_next
                continue
            }
            switch Int32(entry.ai_family) {
            case AF_INET:
                let address = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in.self).pointee
                if let value = stringAddress(address.sin_addr) {
                    addresses.append(value)
                }
            case AF_INET6:
                let address = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in6.self).pointee
                if let value = stringAddress(address.sin6_addr) {
                    addresses.append(value)
                }
            default:
                break
            }
            cursor = entry.ai_next
        }
        guard !addresses.isEmpty else {
            throw AuroraPacketTunnelConfigurationError.unresolvedTunnelEndpoint
        }
        return addresses
    }

    private static func stringAddress(_ address: in_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return buffer.withUnsafeMutableBufferPointer { pointer in
            guard let value = inet_ntop(AF_INET, &address, pointer.baseAddress, socklen_t(pointer.count)) else {
                return nil
            }
            return String(cString: value)
        }
    }

    private static func stringAddress(_ address: in6_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return buffer.withUnsafeMutableBufferPointer { pointer in
            guard let value = inet_ntop(AF_INET6, &address, pointer.baseAddress, socklen_t(pointer.count)) else {
                return nil
            }
            return String(cString: value)
        }
    }
}
