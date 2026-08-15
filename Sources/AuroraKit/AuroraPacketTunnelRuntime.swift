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

    /// Checks that a batch is encodable without producing the encoding. Callers
    /// on the packet path need the check, not the bytes, and encoding a full
    /// batch copies every packet only to discard it.
    public static func validate(_ batch: AuroraPacketFlowBatch) throws {
        guard batch.packets.count == batch.protocolNumbers.count,
              batch.packets.count <= maxPackets
        else {
            throw AuroraPacketBatchCodecError.invalidBatch
        }
        for (packet, protocolNumber) in zip(batch.packets, batch.protocolNumbers) {
            guard let packetProtocolNumber = packetProtocolNumber(for: packet),
                  packetProtocolNumber == protocolNumber
            else {
                throw AuroraPacketBatchCodecError.invalidBatch
            }
            guard !packet.isEmpty,
                  packet.count <= maxPacketBytes,
                  protocolNumber >= 0,
                  protocolNumber <= UInt16.max
            else {
                throw AuroraPacketBatchCodecError.invalidBatch
            }
        }
    }

    public static func encode(_ batch: AuroraPacketFlowBatch) throws -> Data {
        try validate(batch)
        var out = Data()
        out.reserveCapacity(encodedSize(of: batch))
        appendUInt16(UInt16(batch.packets.count), to: &out)
        for (packet, protocolNumber) in zip(batch.packets, batch.protocolNumbers) {
            appendUInt16(UInt16(protocolNumber), to: &out)
            appendUInt32(UInt32(packet.count), to: &out)
            out.append(packet)
        }
        return out
    }

    private static func encodedSize(of batch: AuroraPacketFlowBatch) -> Int {
        batch.packets.reduce(2) { total, packet in total + 2 + 4 + packet.count }
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
            let packet = data.subdata(in: offset..<(offset + packetLength))
            guard packetProtocolNumber(for: packet) == protocolNumber else {
                throw AuroraPacketBatchCodecError.invalidBatch
            }
            packets.append(packet)
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

    private static func packetProtocolNumber(for packet: Data) -> Int? {
        guard let first = packet.first else {
            return nil
        }
        switch first >> 4 {
        case 4:
            return 2
        case 6:
            return 30
        default:
            return nil
        }
    }
}

public struct AuroraNetworkPathChange: Equatable, Sendable {
    public var interface: String
    public var expensive: Bool
    public var constrained: Bool
    public var available: Bool

    public init(interface: String, expensive: Bool, constrained: Bool, available: Bool = true) {
        self.interface = interface
        self.expensive = expensive
        self.constrained = constrained
        self.available = available
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

public protocol AuroraPacketTunnelRecoverableCore: AuroraPacketTunnelCore {}

public protocol AuroraPacketExchangeClient: Sendable {
    func exchangePacketBatch(endpoint: URL, batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch
}

public enum AuroraPacketTunnelRuntimeTermination: Error, Equatable, Sendable {
    case stopped
    case packetFlowEnded
    case packetPumpFailed
    case outputPumpFailed
    case packetInjectionFailed
    case networkPathRecoveryFailed
}

public actor AuroraPacketTunnelRuntime {
    private let configuration: AuroraConfiguration
    private let packetFlow: any AuroraPacketFlow
    private let core: any AuroraPacketTunnelCore
    private let onTerminalFailure: @Sendable (AuroraPacketTunnelRuntimeTermination) -> Void
    private var running = false
    private var connected = false
    private var coreClosed = false
    private var outputTask: Task<Void, Never>?
    private var terminalFailure: AuroraPacketTunnelRuntimeTermination?
    private let packetFlowWriteGate = AuroraPacketFlowWriteGate()
    private var packetFlowActivated = false
    private var trafficSuspended = false
    private var trafficGeneration: UInt64 = 0
    private var trafficWaiters: [CheckedContinuation<Void, Never>] = []
    private var acceptsStart = true
    private var nextStartIdentifier: UInt64 = 0
    private var pendingStartIdentifier: UInt64?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configuration: AuroraConfiguration,
        packetFlow: any AuroraPacketFlow,
        core: any AuroraPacketTunnelCore,
        onTerminalFailure: @escaping @Sendable (AuroraPacketTunnelRuntimeTermination) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.packetFlow = packetFlow
        self.core = core
        self.onTerminalFailure = onTerminalFailure
    }

    public func start() async throws {
        guard acceptsStart, pendingStartIdentifier == nil else {
            throw CancellationError()
        }
        nextStartIdentifier &+= 1
        let startIdentifier = nextStartIdentifier
        pendingStartIdentifier = startIdentifier
        defer {
            finishStart(startIdentifier)
        }
        try await core.connect(configuration: configuration)
        guard acceptsStart, pendingStartIdentifier == startIdentifier else {
            await forceCloseCore()
            throw CancellationError()
        }
        connected = true
        coreClosed = false
        terminalFailure = nil
        await packetFlowWriteGate.open()
        guard acceptsStart, pendingStartIdentifier == startIdentifier else {
            await packetFlowWriteGate.close()
            await forceCloseCore()
            throw CancellationError()
        }
        running = true
        trafficSuspended = false
        trafficGeneration &+= 1
    }

    public func activatePacketFlow() {
        packetFlowActivated = true
        guard running, !trafficSuspended, outputTask == nil else {
            return
        }
        startOutputPumpIfSupported()
    }

    @discardableResult
    public func processNextBatch() async throws -> Bool {
        guard await waitForActiveTraffic() else {
            return false
        }
        let generation = trafficGeneration
        guard let inbound = await packetFlow.readPacketBatch() else {
            guard running else {
                return false
            }
            if trafficSuspended || trafficGeneration != generation {
                return await waitForActiveTraffic()
            }
            return false
        }
        guard running else {
            return false
        }
        guard !trafficSuspended, trafficGeneration == generation else {
            return true
        }
        guard inbound.packets.count == inbound.protocolNumbers.count else {
            return true
        }
        let outbound = try await core.ingestPacketBatch(inbound)
        guard running, !trafficSuspended, trafficGeneration == generation else {
            return true
        }
        if !outbound.isEmpty, Self.canWriteToPacketFlow(outbound) {
            let writeSucceeded = await packetFlowWriteGate.write(outbound, to: packetFlow)
            guard writeSucceeded else {
                guard running, !trafficSuspended, trafficGeneration == generation else {
                    return true
                }
                await terminateDueToFailure(.packetInjectionFailed)
                return false
            }
        }
        return true
    }

    @discardableResult
    public func runUntilStopped() async -> AuroraPacketTunnelRuntimeTermination {
        activatePacketFlow()
        while running {
            do {
                let processed = try await processNextBatch()
                if !processed {
                    if running {
                        await terminateDueToFailure(.packetFlowEnded)
                    }
                }
            } catch {
                if running {
                    await terminateDueToFailure(.packetPumpFailed)
                }
            }
        }
        await closeCoreIfConnected()
        return terminalFailure ?? .stopped
    }

    public func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {
        await core.notifyNetworkPathChange(change)
    }

    public func supportsNetworkPathRecovery() -> Bool {
        core is any AuroraPacketTunnelRecoverableCore
    }

    public func suspendForNetworkPathChange() async -> Bool {
        guard core is any AuroraPacketTunnelRecoverableCore, running else {
            return false
        }
        await suspendTrafficAndCloseCore()
        return true
    }

    public func reconnectAfterNetworkPathChange() async throws -> Bool {
        guard core is any AuroraPacketTunnelRecoverableCore, running, acceptsStart else {
            return false
        }
        if !trafficSuspended {
            await suspendTrafficAndCloseCore()
        }
        do {
            try await core.connect(configuration: configuration)
        } catch {
            await terminateDueToFailure(.networkPathRecoveryFailed)
            throw error
        }
        guard running, acceptsStart else {
            await forceCloseCore()
            return false
        }
        connected = true
        coreClosed = false
        await packetFlowWriteGate.open()
        trafficSuspended = false
        trafficGeneration &+= 1
        resumeTrafficWaiters()
        if packetFlowActivated {
            startOutputPumpIfSupported()
        }
        return true
    }

    public func failNetworkPathRecovery() async {
        guard running else {
            return
        }
        await terminateDueToFailure(.networkPathRecoveryFailed)
    }

    public func submitDNSMessage(_ message: AuroraDNSMessage) async throws {
        try await core.submitDNSMessage(message)
    }

    public func submitSocketEvent(_ event: AuroraSocketEvent) async throws {
        try await core.submitSocketEvent(event)
    }

    public func stop() async {
        acceptsStart = false
        running = false
        trafficSuspended = true
        trafficGeneration &+= 1
        resumeTrafficWaiters()
        outputTask?.cancel()
        outputTask = nil
        await packetFlowWriteGate.close()
        await closeCore()
        await waitForPendingStart()
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

    private func forceCloseCore() async {
        coreClosed = true
        connected = false
        await core.close()
    }

    private func finishStart(_ startIdentifier: UInt64) {
        guard pendingStartIdentifier == startIdentifier else {
            return
        }
        pendingStartIdentifier = nil
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForPendingStart() async {
        guard pendingStartIdentifier != nil else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func waitForActiveTraffic() async -> Bool {
        guard running else {
            return false
        }
        guard trafficSuspended else {
            return true
        }
        await withCheckedContinuation { continuation in
            trafficWaiters.append(continuation)
        }
        return running && !trafficSuspended
    }

    private func resumeTrafficWaiters() {
        let waiters = trafficWaiters
        trafficWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func suspendTrafficAndCloseCore() async {
        guard !trafficSuspended else {
            return
        }
        trafficSuspended = true
        trafficGeneration &+= 1
        outputTask?.cancel()
        outputTask = nil
        await packetFlowWriteGate.close()
        await closeCore()
    }

    private func startOutputPumpIfSupported() {
        guard !trafficSuspended, let outputCore = core as? any AuroraPacketTunnelOutputCore else {
            return
        }
        let generation = trafficGeneration
        outputTask?.cancel()
        outputTask = Task { [weak self, outputCore, generation] in
            await self?.pumpOutboundPackets(from: outputCore, generation: generation)
        }
    }

    private func pumpOutboundPackets(from outputCore: any AuroraPacketTunnelOutputCore, generation: UInt64) async {
        while running, !trafficSuspended, trafficGeneration == generation, !Task.isCancelled {
            do {
                let outbound = try await outputCore.nextOutboundPacketBatch()
                guard running, !trafficSuspended, trafficGeneration == generation, !Task.isCancelled else {
                    return
                }
                if !outbound.isEmpty, Self.canWriteToPacketFlow(outbound) {
                    let writeSucceeded = await packetFlowWriteGate.write(outbound, to: packetFlow)
                    guard writeSucceeded else {
                        guard running, !trafficSuspended, trafficGeneration == generation, !Task.isCancelled else {
                            return
                        }
                        await terminateDueToFailure(.packetInjectionFailed)
                        return
                    }
                }
            } catch {
                guard running, !trafficSuspended, trafficGeneration == generation, !Task.isCancelled else {
                    return
                }
                await terminateDueToFailure(.outputPumpFailed)
                return
            }
        }
    }

    private func terminateDueToFailure(_ failure: AuroraPacketTunnelRuntimeTermination) async {
        guard terminalFailure == nil else {
            return
        }
        terminalFailure = failure
        acceptsStart = false
        running = false
        trafficSuspended = true
        trafficGeneration &+= 1
        resumeTrafficWaiters()
        outputTask?.cancel()
        outputTask = nil
        await packetFlowWriteGate.close()
        await closeCore()
        onTerminalFailure(failure)
    }

    private static func canWriteToPacketFlow(_ batch: AuroraPacketFlowBatch) -> Bool {
        (try? AuroraPacketBatchCodec.validate(batch)) != nil
    }
}

private actor AuroraPacketFlowWriteGate {
    private var acceptingWrites = false
    private var inFlightWrites = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        acceptingWrites = true
    }

    func close() async {
        acceptingWrites = false
        guard inFlightWrites > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    func write(_ batch: AuroraPacketFlowBatch, to packetFlow: any AuroraPacketFlow) async -> Bool {
        guard acceptingWrites else {
            return false
        }
        inFlightWrites += 1
        let succeeded = await packetFlow.writePacketBatch(batch)
        inFlightWrites -= 1
        if inFlightWrites == 0 {
            let waiters = closeWaiters
            closeWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        return succeeded
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
        let spentKey = try await issuerClient.spendAdmissionToken(endpoint: endpoint, admissionProof: issued.admissionProof)
        guard spentKey.count == 48 else {
            throw AuroraClientError.invalidIssuerResponse("spent key length \(spentKey.count), want 48")
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
