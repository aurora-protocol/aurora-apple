import Foundation

public struct AuroraPacketFlowBatch: Equatable, Sendable {
    public var packets: [Data]
    public var protocolNumbers: [Int]

    public init(packets: [Data], protocolNumbers: [Int]) {
        self.packets = packets
        self.protocolNumbers = protocolNumbers
    }

    public var isEmpty: Bool {
        packets.isEmpty
    }
}

public struct AuroraNetworkPathChange: Equatable, Sendable {
    public var interface: String
    public var expensive: Bool
    public var constrained: Bool

    public init(interface: String, expensive: Bool, constrained: Bool) {
        self.interface = interface
        self.expensive = expensive
        self.constrained = constrained
    }
}

public protocol AuroraPacketFlow: Sendable {
    func readPacketBatch() async -> AuroraPacketFlowBatch?
    func writePacketBatch(_ batch: AuroraPacketFlowBatch) async -> Bool
}

public protocol AuroraPacketTunnelCore: Sendable {
    func connect(configuration: AuroraConfiguration) async throws
    func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch
    func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async
    func close() async
}

public actor AuroraPacketTunnelRuntime {
    private let configuration: AuroraConfiguration
    private let packetFlow: any AuroraPacketFlow
    private let core: any AuroraPacketTunnelCore
    private var running = false

    public init(
        configuration: AuroraConfiguration,
        packetFlow: any AuroraPacketFlow,
        core: any AuroraPacketTunnelCore
    ) {
        self.configuration = configuration
        self.packetFlow = packetFlow
        self.core = core
    }

    public func start() async throws {
        try await core.connect(configuration: configuration)
        running = true
    }

    @discardableResult
    public func processNextBatch() async throws -> Bool {
        guard running, let inbound = await packetFlow.readPacketBatch() else {
            return false
        }
        guard inbound.packets.count == inbound.protocolNumbers.count else {
            return true
        }
        let outbound = try await core.ingestPacketBatch(inbound)
        if !outbound.isEmpty, outbound.packets.count == outbound.protocolNumbers.count {
            _ = await packetFlow.writePacketBatch(outbound)
        }
        return true
    }

    public func runUntilStopped() async {
        while running {
            do {
                let processed = try await processNextBatch()
                if !processed {
                    running = false
                }
            } catch {
                running = false
            }
        }
    }

    public func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {
        await core.notifyNetworkPathChange(change)
    }

    public func stop() async {
        running = false
        await core.close()
    }
}

public actor AuroraServerBackedPacketTunnelCore: AuroraPacketTunnelCore {
    private let serverClient: any AuroraServerClient
    private var configuration: AuroraConfiguration?
    private var latestPathChange: AuroraNetworkPathChange?

    public init(serverClient: any AuroraServerClient = URLSessionAuroraServerClient()) {
        self.serverClient = serverClient
    }

    public func connect(configuration: AuroraConfiguration) async throws {
        let status = try await serverClient.fetchStatus(endpoint: configuration.endpoint)
        guard status.ready else {
            throw AuroraClientError.unavailable
        }
        self.configuration = configuration
    }

    public func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        AuroraPacketFlowBatch(packets: [], protocolNumbers: [])
    }

    public func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {
        latestPathChange = change
    }

    public func close() async {
        configuration = nil
    }
}
