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

public enum AuroraPacketBatchCodecError: Error, Equatable {
    case invalidBatch
}

public enum AuroraPacketBatchCodec {
    private static let maxPackets = 64
    private static let maxPacketBytes = 65_535

    public static func encode(_ batch: AuroraPacketFlowBatch) throws -> Data {
        guard batch.packets.count == batch.protocolNumbers.count,
              batch.packets.count <= maxPackets
        else {
            throw AuroraPacketBatchCodecError.invalidBatch
        }
        var out = Data()
        appendUInt16(UInt16(batch.packets.count), to: &out)
        for (packet, protocolNumber) in zip(batch.packets, batch.protocolNumbers) {
            guard !packet.isEmpty,
                  packet.count <= maxPacketBytes,
                  protocolNumber >= 0,
                  protocolNumber <= UInt16.max
            else {
                throw AuroraPacketBatchCodecError.invalidBatch
            }
            appendUInt16(UInt16(protocolNumber), to: &out)
            appendUInt32(UInt32(packet.count), to: &out)
            out.append(packet)
        }
        return out
    }

    public static func decode(_ data: Data) throws -> AuroraPacketFlowBatch {
        var offset = 0
        let count = Int(try readUInt16(from: data, offset: &offset))
        guard count <= maxPackets else {
            throw AuroraPacketBatchCodecError.invalidBatch
        }
        var packets: [Data] = []
        var protocolNumbers: [Int] = []
        packets.reserveCapacity(count)
        protocolNumbers.reserveCapacity(count)
        for _ in 0..<count {
            let protocolNumber = Int(try readUInt16(from: data, offset: &offset))
            let packetLength = Int(try readUInt32(from: data, offset: &offset))
            guard packetLength > 0,
                  packetLength <= maxPacketBytes,
                  data.count - offset >= packetLength
            else {
                throw AuroraPacketBatchCodecError.invalidBatch
            }
            packets.append(data.subdata(in: offset..<(offset + packetLength)))
            protocolNumbers.append(protocolNumber)
            offset += packetLength
        }
        guard offset == data.count else {
            throw AuroraPacketBatchCodecError.invalidBatch
        }
        return AuroraPacketFlowBatch(packets: packets, protocolNumbers: protocolNumbers)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func readUInt16(from data: Data, offset: inout Int) throws -> UInt16 {
        guard data.count - offset >= 2 else {
            throw AuroraPacketBatchCodecError.invalidBatch
        }
        let value = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        offset += 2
        return value
    }

    private static func readUInt32(from data: Data, offset: inout Int) throws -> UInt32 {
        guard data.count - offset >= 4 else {
            throw AuroraPacketBatchCodecError.invalidBatch
        }
        let value = (UInt32(data[offset]) << 24) |
            (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) |
            UInt32(data[offset + 3])
        offset += 4
        return value
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

public protocol AuroraPacketExchangeClient: Sendable {
    func exchangePacketBatch(endpoint: URL, batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch
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
    private let statusClient: any AuroraServerClient
    private let packetClient: any AuroraPacketExchangeClient
    private var configuration: AuroraConfiguration?
    private var latestPathChange: AuroraNetworkPathChange?

    public init(serverClient: any AuroraServerClient & AuroraPacketExchangeClient = URLSessionAuroraServerClient()) {
        self.statusClient = serverClient
        self.packetClient = serverClient
    }

    public init(
        statusClient: any AuroraServerClient,
        packetClient: any AuroraPacketExchangeClient
    ) {
        self.statusClient = statusClient
        self.packetClient = packetClient
    }

    public func connect(configuration: AuroraConfiguration) async throws {
        let status = try await statusClient.fetchStatus(endpoint: configuration.endpoint)
        guard status.ready else {
            throw AuroraClientError.unavailable
        }
        self.configuration = configuration
    }

    public func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        guard let configuration else {
            throw AuroraClientError.unavailable
        }
        return try await packetClient.exchangePacketBatch(endpoint: configuration.endpoint, batch: batch)
    }

    public func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {
        latestPathChange = change
    }

    public func close() async {
        configuration = nil
    }
}
