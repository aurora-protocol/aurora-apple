import AuroraKit
import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let configurationResolver = AuroraTunnelConfigurationResolver(
        fallbackConfiguration: AuroraConfiguration(endpoint: AuroraConfiguration.defaultLoopbackEndpoint),
        profileStore: AuroraUserDefaultsProfileStore(
            appGroupIdentifier: AuroraAppleSharedContainer.appGroupIdentifier()
        )
    )
    private let serverClient = URLSessionAuroraServerClient()
    private let endpointResolver = AuroraTunnelEndpointResolver()
    private let pathObserver = NetworkPathObserver()
    private let lifecycle = AuroraPacketTunnelLifecycle()
    private let startupGate = AuroraPacketTunnelStartupGate()
    private var runtime: AuroraPacketTunnelRuntime?
    private var runtimeTask: Task<Void, Never>?
    private var pathTransitionTracker: AuroraNetworkPathTransitionTracker?
    private var pathOperationQueue: AuroraAsyncSerialQueue?
    private var enqueuePathChange: (@Sendable (AuroraNetworkPathChange) async -> Void)?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = StartTunnelCompletion(completionHandler)
        let lifecycle = lifecycle
        let generation = lifecycle.beginStartup()
        let startupGate = startupGate
        startupGate.begin(generation)
        let configuration = resolvedConfiguration()
        let serverClient = serverClient
        let packetFlow = NetworkExtensionPacketFlow(packetFlow: packetFlow)
        let pathObserver = pathObserver
        let pathTransitionTracker = AuroraNetworkPathTransitionTracker()
        let pathOperationQueue = AuroraAsyncSerialQueue()
        if configuration.nativeProvisioningIdentifier != nil,
           !AuroraNativeProvisioningTrust.configureBundled() {
            lifecycle.cancelStartup(generation)
            completion(AuroraNativeTunnelError.invalidProvisioning)
            startupGate.finish(generation)
            return
        }
        let core: any AuroraPacketTunnelCore
        if configuration.nativeProvisioningIdentifier != nil {
            core = AuroraNativePacketTunnelCore()
        } else {
            core = AuroraServerBackedPacketTunnelCore(serverClient: serverClient)
        }
        let runtime = AuroraPacketTunnelRuntime(
            configuration: configuration,
            packetFlow: packetFlow,
            core: core,
            onTerminalFailure: { [weak self] failure in
                _ = lifecycle.claimTerminalFailure(generation, delivering: {
                    self?.cancelTunnelWithError(failure)
                })
            }
        )
        self.runtime = runtime
        self.pathTransitionTracker = pathTransitionTracker
        self.pathOperationQueue = pathOperationQueue
        let enqueuePathChange: @Sendable (AuroraNetworkPathChange) async -> Void = { [weak self, runtime] change in
            guard let self else {
                return
            }
            await pathOperationQueue.enqueue { [weak self, runtime] in
                await self?.handleNetworkPathChange(
                    change,
                    generation: generation,
                    configuration: configuration,
                    runtime: runtime,
                    tracker: pathTransitionTracker
                )
            }
        }
        self.enqueuePathChange = enqueuePathChange

        runtimeTask = Task {
            do {
                let tunnelConfiguration = try await endpointResolver.resolve(
                    AuroraPacketTunnelConfiguration(configuration: configuration)
                )
                try await runtime.start()
                try await applyTunnelNetworkSettings(networkSettings(for: tunnelConfiguration))
                guard lifecycle.beginPathObservation(generation, activating: {
                    pathObserver.start { change in
                        Task {
                            await enqueuePathChange(change)
                        }
                    }
                }) else {
                    throw CancellationError()
                }
                let initialPath = pathObserver.currentChange()
                await enqueuePathChange(initialPath)
                await pathOperationQueue.waitForQuiescence()
                guard lifecycle.completeStartup(generation, delivering: {
                    completion(nil)
                }) else {
                    throw CancellationError()
                }
                await pathOperationQueue.enqueue { [weak self, runtime] in
                    let action = await pathTransitionTracker.takeDeferredAction()
                    await self?.performNetworkPathTransition(
                        action,
                        generation: generation,
                        configuration: configuration,
                        runtime: runtime
                    )
                }
                await pathOperationQueue.waitForQuiescence()
                startupGate.finish(generation)
                await runtime.runUntilStopped()
            } catch {
                lifecycle.cancelStartup(generation)
                await runtime.stop()
                completion(error)
                startupGate.finish(generation)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = StopTunnelCompletion(completionHandler)
        lifecycle.requestStop {
            pathObserver.stop()
        }
        let startupGate = startupGate
        let runtime = runtime
        runtimeTask?.cancel()
        runtimeTask = nil
        self.runtime = nil
        pathTransitionTracker = nil
        pathOperationQueue = nil
        enqueuePathChange = nil
        Task {
            await runtime?.stop()
            await startupGate.waitForQuiescence()
            completion()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        let completion = StopTunnelCompletion(completionHandler)
        let enqueuePathChange = enqueuePathChange
        let runtime = runtime
        Task {
            let change = AuroraNetworkPathChange(interface: "sleep", expensive: false, constrained: false, available: false)
            if let enqueuePathChange {
                await enqueuePathChange(change)
            } else {
                await runtime?.notifyNetworkPathChange(change)
            }
            completion()
        }
    }

    override func wake() {
        let enqueuePathChange = enqueuePathChange
        let runtime = runtime
        let pathObserver = pathObserver
        Task {
            let change = pathObserver.currentChange()
            if let enqueuePathChange {
                await enqueuePathChange(change)
            } else {
                await runtime?.notifyNetworkPathChange(change)
            }
        }
    }

    private func resolvedConfiguration() -> AuroraConfiguration {
        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        return configurationResolver.configuration(providerConfiguration: providerConfiguration)
    }

    private func handleNetworkPathChange(
        _ change: AuroraNetworkPathChange,
        generation: UInt64,
        configuration: AuroraConfiguration,
        runtime: AuroraPacketTunnelRuntime,
        tracker: AuroraNetworkPathTransitionTracker
    ) async {
        let action = await tracker.record(change)
        await runtime.notifyNetworkPathChange(change)
        guard action != .none else {
            return
        }
        guard lifecycle.isStarted(generation) else {
            await tracker.deferUntilStartupCompletes(action)
            return
        }
        await performNetworkPathTransition(
            action,
            generation: generation,
            configuration: configuration,
            runtime: runtime
        )
    }

    private func performNetworkPathTransition(
        _ action: AuroraNetworkPathTransitionAction,
        generation: UInt64,
        configuration: AuroraConfiguration,
        runtime: AuroraPacketTunnelRuntime
    ) async {
        guard action != .none, lifecycle.isStarted(generation) else {
            return
        }
        let supportsRecovery = await runtime.supportsNetworkPathRecovery()
        switch action {
        case .none:
            return
        case .suspend:
            guard supportsRecovery else {
                return
            }
            reasserting = true
            _ = await runtime.suspendForNetworkPathChange()
        case .recover:
            if supportsRecovery {
                reasserting = true
                _ = await runtime.suspendForNetworkPathChange()
            }
            do {
                let tunnelConfiguration = try await endpointResolver.resolve(
                    AuroraPacketTunnelConfiguration(configuration: configuration)
                )
                guard lifecycle.isStarted(generation) else {
                    return
                }
                try await applyTunnelNetworkSettings(networkSettings(for: tunnelConfiguration))
                guard lifecycle.isStarted(generation) else {
                    return
                }
                if supportsRecovery {
                    let recovered = try await runtime.reconnectAfterNetworkPathChange()
                    if recovered {
                        reasserting = false
                    }
                }
            } catch {
                guard lifecycle.isStarted(generation) else {
                    return
                }
                await runtime.failNetworkPathRecovery()
            }
        }
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

        let ipv6 = NEIPv6Settings(
            addresses: [configuration.ipv6Address],
            networkPrefixLengths: [NSNumber(value: configuration.ipv6NetworkPrefixLength)]
        )
        if configuration.includeDefaultIPv6Route {
            ipv6.includedRoutes = [NEIPv6Route.default()]
        }
        if !configuration.excludedIPv6Routes.isEmpty {
            ipv6.excludedRoutes = configuration.excludedIPv6Routes.map {
                NEIPv6Route(
                    destinationAddress: $0.destinationAddress,
                    networkPrefixLength: NSNumber(value: $0.networkPrefixLength)
                )
            }
        }
        settings.ipv6Settings = ipv6

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
            return AuroraNetworkPathChange(interface: "unknown", expensive: false, constrained: false, available: false)
        }
        return Self.change(for: path)
    }

    private static func change(for path: NWPath) -> AuroraNetworkPathChange {
        AuroraNetworkPathChange(
            interface: interfaceName(for: path),
            expensive: path.isExpensive,
            constrained: path.isConstrained,
            available: path.status == .satisfied
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
    private let readLock = NSLock()
    private var readsReleased = false
    private var nextReadIdentifier: UInt64 = 0
    private var pendingRead: (identifier: UInt64, continuation: CheckedContinuation<AuroraPacketFlowBatch?, Never>)?

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }

    func readPacketBatch() async -> AuroraPacketFlowBatch? {
        await withCheckedContinuation { continuation in
            readLock.lock()
            guard !readsReleased, pendingRead == nil else {
                readLock.unlock()
                continuation.resume(returning: nil)
                return
            }
            nextReadIdentifier &+= 1
            if nextReadIdentifier == 0 {
                nextReadIdentifier = 1
            }
            let readIdentifier = nextReadIdentifier
            pendingRead = (identifier: readIdentifier, continuation: continuation)
            readLock.unlock()
            packetFlow.readPackets { packets, protocols in
                self.finishRead(
                    readIdentifier,
                    batch: AuroraPacketFlowBatch(
                        packets: packets,
                        protocolNumbers: protocols.map(\.intValue)
                    )
                )
            }
        }
    }

    func releasePendingRead() async {
        let continuation = readLock.withLock {
            readsReleased = true
            defer { pendingRead = nil }
            return pendingRead?.continuation
        }
        continuation?.resume(returning: nil)
    }

    func writePacketBatch(_ batch: AuroraPacketFlowBatch) async -> Bool {
        let protocols = batch.protocolNumbers.map { NSNumber(value: $0) }
        return packetFlow.writePackets(batch.packets, withProtocols: protocols)
    }

    private func finishRead(_ identifier: UInt64, batch: AuroraPacketFlowBatch) {
        readLock.lock()
        guard let pendingRead, pendingRead.identifier == identifier else {
            readLock.unlock()
            return
        }
        self.pendingRead = nil
        readLock.unlock()
        pendingRead.continuation.resume(returning: batch)
    }
}
