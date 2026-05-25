import AuroraKit
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var controller: AuroraClientController?

    override func startTunnel(options: [String: NSObject]?) async throws {
        let endpoint = URL(string: "http://127.0.0.1:9443")!
        let controller = await AuroraClientController(configuration: AuroraConfiguration(endpoint: endpoint))
        self.controller = controller
        await controller.refreshStatus()
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        controller = nil
    }
}
