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

public struct AuroraDNSMessage: Equatable, Sendable {
    public var flowID: UInt64
    public var message: Data

    public init(flowID: UInt64, message: Data) {
        self.flowID = flowID
        self.message = Data(message)
    }
}

public struct AuroraSocketEvent: Equatable, Sendable {
    public var eventType: String
    public var flowID: UInt64
    public var remoteAddress: String
    public var remotePort: UInt16
    public var payload: Data

    public init(
        eventType: String,
        flowID: UInt64,
        remoteAddress: String,
        remotePort: UInt16,
        payload: Data
    ) {
        self.eventType = eventType
        self.flowID = flowID
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.payload = Data(payload)
    }
}

public protocol AuroraPacketFlow: Sendable {
    func readPacketBatch() async -> AuroraPacketFlowBatch?
    func writePacketBatch(_ batch: AuroraPacketFlowBatch) async -> Bool
}

public protocol AuroraPacketTunnelCore: Sendable {
    func connect(configuration: AuroraConfiguration) async throws
    func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch
    func submitDNSMessage(_ message: AuroraDNSMessage) async throws
    func submitSocketEvent(_ event: AuroraSocketEvent) async throws
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
    private var connected = false
    private var coreClosed = false

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
        connected = true
        coreClosed = false
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
        await closeCoreIfConnected()
    }

    public func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {
        await core.notifyNetworkPathChange(change)
    }

    public func submitDNSMessage(_ message: AuroraDNSMessage) async throws {
        try await core.submitDNSMessage(message)
    }

    public func submitSocketEvent(_ event: AuroraSocketEvent) async throws {
        try await core.submitSocketEvent(event)
    }

    public func stop() async {
        running = false
        await closeCore()
    }

    private func closeCoreIfConnected() async {
        guard connected else {
            return
        }
        await closeCore()
    }

    private func closeCore() async {
        guard !coreClosed else {
            return
        }
        coreClosed = true
        connected = false
        await core.close()
    }
}

public actor AuroraServerBackedPacketTunnelCore: AuroraPacketTunnelCore {
    private let statusClient: any AuroraServerClient
    private let packetClient: any AuroraPacketExchangeClient
    private let issuerClient: (any AuroraIssuerClient)?
    private let tokenWallet: AuroraTokenWallet?
    private var configuration: AuroraConfiguration?
    private var latestPathChange: AuroraNetworkPathChange?
    private var latestDNSMessage: AuroraDNSMessage?
    private var latestSocketEvent: AuroraSocketEvent?

    public init(
        serverClient: any AuroraServerClient & AuroraPacketExchangeClient & AuroraIssuerClient = URLSessionAuroraServerClient(),
        tokenWallet: AuroraTokenWallet = AuroraTokenWallet()
    ) {
        self.statusClient = serverClient
        self.packetClient = serverClient
        self.issuerClient = serverClient
        self.tokenWallet = tokenWallet
    }

    public init(
        statusClient: any AuroraServerClient,
        packetClient: any AuroraPacketExchangeClient
    ) {
        self.statusClient = statusClient
        self.packetClient = packetClient
        self.issuerClient = nil
        self.tokenWallet = nil
    }

    public init(
        statusClient: any AuroraServerClient,
        packetClient: any AuroraPacketExchangeClient,
        issuerClient: any AuroraIssuerClient,
        tokenWallet: AuroraTokenWallet
    ) {
        self.statusClient = statusClient
        self.packetClient = packetClient
        self.issuerClient = issuerClient
        self.tokenWallet = tokenWallet
    }

    public func connect(configuration: AuroraConfiguration) async throws {
        let status = try await statusClient.fetchStatus(endpoint: configuration.endpoint)
        guard status.clientReady else {
            throw AuroraClientError.unavailable
        }
        try await issueAdmissionTokenIfConfigured(endpoint: configuration.endpoint)
        self.configuration = configuration
    }

    public func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        guard let configuration else {
            throw AuroraClientError.unavailable
        }
        return try await packetClient.exchangePacketBatch(endpoint: configuration.endpoint, batch: batch)
    }

    public func submitDNSMessage(_ message: AuroraDNSMessage) async throws {
        guard configuration != nil else {
            throw AuroraClientError.unavailable
        }
        latestDNSMessage = message
    }

    public func submitSocketEvent(_ event: AuroraSocketEvent) async throws {
        guard configuration != nil else {
            throw AuroraClientError.unavailable
        }
        latestSocketEvent = event
    }

    public func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {
        latestPathChange = change
    }

    public func close() async {
        configuration = nil
    }

    private func issueAdmissionTokenIfConfigured(endpoint: URL) async throws {
        guard let issuerClient, let tokenWallet else {
            return
        }
        let metadata = try await issuerClient.fetchIssuerMetadata(endpoint: endpoint)
        guard !metadata.issuerMetadata.isEmpty, metadata.issuerMetadataHash.count == 48 else {
            throw AuroraClientError.invalidIssuerResponse("issuer metadata unavailable")
        }
        let request = try AuroraBlindRSAIssueRequest.random(
            nowUnix: Int64(Date().timeIntervalSince1970)
        )
        let issued = try await issuerClient.issueBlindRSAAdmissionToken(endpoint: endpoint, request: request)
        guard issued.issuerMetadataHash.isEmpty || issued.issuerMetadataHash == metadata.issuerMetadataHash else {
            throw AuroraClientError.invalidAdmissionProof("issuer metadata hash mismatch")
        }
        try await tokenWallet.store(AuroraTokenWalletEntry(
            relayBucketID: issued.relayBucketIDHex,
            accessHintCredential: Data(),
            admissionProof: issued.admissionProof,
            tokenAuthenticator: issued.tokenAuthenticator,
            hintSecret: Data(),
            expiresAtUnix: issued.expiryUnix
        ))
    }
}
