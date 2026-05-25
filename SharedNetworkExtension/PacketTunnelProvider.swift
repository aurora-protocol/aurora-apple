import AuroraKit
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let configuration = AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!)
    private let serverClient = URLSessionAuroraServerClient()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let endpoint = configuration.endpoint
        let serverClient = serverClient

        completionHandler(nil)

        Task {
            _ = try? await serverClient.fetchStatus(endpoint: endpoint)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
