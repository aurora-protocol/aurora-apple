import AuroraKit
import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let configurationResolver = AuroraTunnelConfigurationResolver(
        fallbackConfiguration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
        profileStore: AuroraUserDefaultsProfileStore(
            appGroupIdentifier: AuroraAppleSharedContainer.appGroupIdentifier()
        )
    )
    private let serverClient = URLSessionAuroraServerClient()
    private let pathObserver = NetworkPathObserver()
    private var runtime: AuroraPacketTunnelRuntime?
    private var runtimeTask: Task<Void, Never>?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = StartTunnelCompletion(completionHandler)
        let configuration = resolvedConfiguration()
        let tunnelConfiguration = AuroraPacketTunnelConfiguration(configuration: configuration)
        let serverClient = serverClient
        let packetFlow = NetworkExtensionPacketFlow(packetFlow: packetFlow)
        let pathObserver = pathObserver
        let core: any AuroraPacketTunnelCore
        if configuration.nativeProvisioningIdentifier != nil {
            core = AuroraNativePacketTunnelCore()
        } else {
            core = AuroraServerBackedPacketTunnelCore(serverClient: serverClient)
        }
        let runtime = AuroraPacketTunnelRuntime(
            configuration: configuration,
            packetFlow: packetFlow,
            core: core
        )
        self.runtime = runtime

        runtimeTask = Task {
            do {
                try await runtime.start()
                try await applyTunnelNetworkSettings(networkSettings(for: tunnelConfiguration))
                await runtime.activatePacketFlow()
                pathObserver.start { change in
                    Task {
                        await runtime.notifyNetworkPathChange(change)
                    }
                }
                await runtime.notifyNetworkPathChange(pathObserver.currentChange())
                completion(nil)
                await runtime.runUntilStopped()
            } catch {
                pathObserver.stop()
                await runtime.stop()
                completion(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = StopTunnelCompletion(completionHandler)
        let runtime = runtime
        pathObserver.stop()
        runtimeTask?.cancel()
        runtimeTask = nil
        self.runtime = nil
        Task {
            await runtime?.stop()
            completion()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        let completion = StopTunnelCompletion(completionHandler)
        let runtime = runtime
        Task {
            await runtime?.notifyNetworkPathChange(
                AuroraNetworkPathChange(interface: "sleep", expensive: false, constrained: false)
            )
            completion()
        }
    }

    override func wake() {
        let runtime = runtime
        let pathObserver = pathObserver
        Task {
            await runtime?.notifyNetworkPathChange(pathObserver.currentChange())
        }
    }

    private func resolvedConfiguration() -> AuroraConfiguration {
        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        return configurationResolver.configuration(providerConfiguration: providerConfiguration)
    }

    private func applyTunnelNetworkSettings(_ settings: NEPacketTunnelNetworkSettings) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
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
        if !configuration.excludedIPv4Routes.isEmpty {
            ipv4.excludedRoutes = configuration.excludedIPv4Routes.map {
                NEIPv4Route(destinationAddress: $0.destinationAddress, subnetMask: $0.subnetMask)
            }
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

private final class StopTunnelCompletion: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func callAsFunction() {
        handler()
    }
}

private final class NetworkPathObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.aurora.packet-tunnel.path")
    private let lock = NSLock()
    private var monitor: NWPathMonitor?

    func start(_ handler: @escaping @Sendable (AuroraNetworkPathChange) -> Void) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            handler(Self.change(for: path))
        }
        lock.lock()
        self.monitor?.cancel()
        self.monitor = monitor
        lock.unlock()
        monitor.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let monitor = monitor
        self.monitor = nil
        lock.unlock()
        monitor?.cancel()
    }

    func currentChange() -> AuroraNetworkPathChange {
        lock.lock()
        let path = monitor?.currentPath
        lock.unlock()
        guard let path else {
            return AuroraNetworkPathChange(interface: "unknown", expensive: false, constrained: false)
        }
        return Self.change(for: path)
    }

    private static func change(for path: NWPath) -> AuroraNetworkPathChange {
        AuroraNetworkPathChange(
            interface: interfaceName(for: path),
            expensive: path.isExpensive,
            constrained: path.isConstrained
        )
    }

    private static func interfaceName(for path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) {
            return "wifi"
        }
        if path.usesInterfaceType(.cellular) {
            return "cellular"
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return "wired"
        }
        if path.usesInterfaceType(.loopback) {
            return "loopback"
        }
        if path.usesInterfaceType(.other) {
            return "other"
        }
        return "unknown"
    }
}

private final class NetworkExtensionPacketFlow: AuroraPacketFlow, @unchecked Sendable {
    private let packetFlow: NEPacketTunnelFlow

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }

    func readPacketBatch() async -> AuroraPacketFlowBatch? {
        await withCheckedContinuation { continuation in
            packetFlow.readPackets { packets, protocols in
                continuation.resume(
                    returning: AuroraPacketFlowBatch(
                        packets: packets,
                        protocolNumbers: protocols.map(\.intValue)
                    )
                )
            }
        }
    }

    func writePacketBatch(_ batch: AuroraPacketFlowBatch) async -> Bool {
        let protocols = batch.protocolNumbers.map { NSNumber(value: $0) }
        return packetFlow.writePackets(batch.packets, withProtocols: protocols)
    }
}
