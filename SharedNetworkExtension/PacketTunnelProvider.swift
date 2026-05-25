import AuroraKit
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let configuration = AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!)
    private let serverClient = URLSessionAuroraServerClient()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = StartTunnelCompletion(completionHandler)
        let tunnelConfiguration = AuroraPacketTunnelConfiguration(configuration: configuration)
        let endpoint = tunnelConfiguration.endpoint
        let serverClient = serverClient

        setTunnelNetworkSettings(networkSettings(for: tunnelConfiguration)) { error in
            if let error {
                completion(error)
                return
            }
            completion(nil)
            Task {
                _ = try? await serverClient.fetchStatus(endpoint: endpoint)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    private func networkSettings(for configuration: AuroraPacketTunnelConfiguration) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: configuration.tunnelRemoteAddress)
        settings.mtu = NSNumber(value: configuration.mtu)

        let ipv4 = NEIPv4Settings(
            addresses: [configuration.ipv4Address],
            subnetMasks: [configuration.ipv4SubnetMask]
        )
        if configuration.includeDefaultIPv4Route {
            ipv4.includedRoutes = [NEIPv4Route.default()]
        }
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: configuration.dnsServers)
        if configuration.captureAllDNSDomains {
            dns.matchDomains = [""]
        }
        settings.dnsSettings = dns

        return settings
    }
}

private final class StartTunnelCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ error: Error?) {
        handler(error)
    }
}
