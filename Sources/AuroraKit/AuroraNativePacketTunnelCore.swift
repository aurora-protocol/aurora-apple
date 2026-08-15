import CryptoKit
import Foundation

public struct AuroraNativeIssuerWork: Equatable, Sendable {
    public var handle: UInt64
    public var issuerURL: URL
    public var issuerCarrierPath: String
    public var requestBody: Data

    public init(handle: UInt64, issuerURL: URL, issuerCarrierPath: String, requestBody: Data) {
        self.handle = handle
        self.issuerURL = issuerURL
        self.issuerCarrierPath = issuerCarrierPath
        self.requestBody = Data(requestBody)
    }
}

public protocol AuroraNativeSessionDriver: Sendable {
    func begin(provisioning: Data) async throws -> AuroraNativeIssuerWork
    func complete(handle: UInt64, issuerResponse: Data) async throws
    func ingress(handle: UInt64, packet: Data) async throws -> [Data]
    func nextLocalPacket(handle: UInt64) async throws -> Data
    func close(handle: UInt64) async
}

public protocol AuroraNativeIssuerTransport: Sendable {
    func postIssuerWork(url: URL, body: Data) async throws -> Data
}

public enum AuroraNativeTunnelError: Error, Equatable, Sendable {
    case unavailable
    case invalidProvisioning
    case invalidIssuerWork
    case invalidPacket
    case coreOperationFailed
}

public struct AuroraNativeProvisioningReservation: Equatable, Sendable {
    public var provisioning: Data
    public var spentHintKey: Data
    public var relayBucketID: Data
    public var accessHintExpiryUnix: UInt64

    public init(
        provisioning: Data,
        spentHintKey: Data,
        relayBucketID: Data,
        accessHintExpiryUnix: UInt64
    ) {
        self.provisioning = Data(provisioning)
        self.spentHintKey = Data(spentHintKey)
        self.relayBucketID = Data(relayBucketID)
        self.accessHintExpiryUnix = accessHintExpiryUnix
    }

    mutating func zero() {
        provisioning.resetBytes(in: 0..<provisioning.count)
        spentHintKey.resetBytes(in: 0..<spentHintKey.count)
        relayBucketID.resetBytes(in: 0..<relayBucketID.count)
        self = AuroraNativeProvisioningReservation(
            provisioning: Data(),
            spentHintKey: Data(),
            relayBucketID: Data(),
            accessHintExpiryUnix: 0
        )
    }
}

public protocol AuroraNativeProvisioningReserver: Sendable {
    func reserve(
        source: Data,
        spentHintKeys: [Data],
        now: Date
    ) async throws -> AuroraNativeProvisioningReservation
}

public protocol AuroraNativeProvisioningValidator: Sendable {
    func validate(source: Data, now: Date) async throws
}

public struct AuroraCoreNativeProvisioningValidator: AuroraNativeProvisioningValidator {
    public init() {}

    public func validate(source: Data, now: Date) async throws {
        let valid = await Task.detached {
            AuroraCore.validateNativeProvisioningSource(source, now: now)
        }.value
        guard valid else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
    }
}

public struct AuroraCoreNativeProvisioningReserver: AuroraNativeProvisioningReserver {
    public init() {}

    public func reserve(
        source: Data,
        spentHintKeys: [Data],
        now: Date
    ) async throws -> AuroraNativeProvisioningReservation {
        guard let reservation = AuroraCore.reserveNativeProvisioning(
            source: source,
            spentHintKeys: spentHintKeys,
            now: now
        ) else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        return AuroraNativeProvisioningReservation(
            provisioning: reservation.provisioning,
            spentHintKey: reservation.spentHintKey,
            relayBucketID: reservation.relayBucketID,
            accessHintExpiryUnix: reservation.accessHintExpiryUnix
        )
    }
}

struct AuroraNativeProvisioningReservationLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var spentHintKey: Data
        var accessHintExpiryUnix: UInt64
    }

    var sourceDigest: Data?
    var entries: [Entry]

    init(sourceDigest: Data? = nil, entries: [Entry]) {
        self.sourceDigest = sourceDigest.map { Data($0) }
        self.entries = entries
    }

    mutating func prune(nowUnix: UInt64) {
        entries.removeAll { $0.accessHintExpiryUnix <= nowUnix }
    }

    func isValid() -> Bool {
        guard (sourceDigest == nil || sourceDigest?.count == 32),
              entries.count <= AuroraNativeProvisioningStore.maximumReservations
        else {
            return false
        }
        var seen = Set<Data>()
        for entry in entries {
            guard entry.spentHintKey.count == 48,
                  entry.accessHintExpiryUnix > 0,
                  seen.insert(entry.spentHintKey).inserted
            else {
                return false
            }
        }
        return true
    }
}

final class AuroraNoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public actor AuroraNativeProvisioningStore {
    public static let service = "org.aurora-protocol.aurora.native-provisioning"
    public static let reservationService = "org.aurora-protocol.aurora.native-provisioning-reservations"
    public static let defaultIdentifier = "active"
    public static let maximumBytes = 16 << 20
    public static let maximumReservations = 64
    private static let maximumReservationLedgerBytes = 16 << 10

    private let credentialStore: any AuroraSecureCredentialStore
    private let validator: any AuroraNativeProvisioningValidator
    private let reserver: any AuroraNativeProvisioningReserver

    public init(
        credentialStore: any AuroraSecureCredentialStore = AuroraKeychainCredentialStore(),
        validator: any AuroraNativeProvisioningValidator = AuroraCoreNativeProvisioningValidator(),
        reserver: any AuroraNativeProvisioningReserver = AuroraCoreNativeProvisioningReserver()
    ) {
        self.credentialStore = credentialStore
        self.validator = validator
        self.reserver = reserver
    }

    public func save(_ provisioning: Data, identifier: String = defaultIdentifier) async throws {
        guard Self.isValidIdentifier(identifier),
              !provisioning.isEmpty,
              provisioning.count <= Self.maximumBytes
        else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        try await validator.validate(source: provisioning, now: Date())
        try await credentialStore.save(provisioning, service: Self.service, account: Self.account(identifier: identifier))
        // A source-bound ledger that survives cleanup cannot apply to this replacement source.
        try? await credentialStore.delete(service: Self.reservationService, account: Self.reservationAccount(identifier: identifier))
    }

    public func load(identifier: String = defaultIdentifier) async throws -> Data? {
        guard Self.isValidIdentifier(identifier) else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        guard let provisioning = try await credentialStore.load(service: Self.service, account: Self.account(identifier: identifier)) else {
            return nil
        }
        guard !provisioning.isEmpty, provisioning.count <= Self.maximumBytes else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        return provisioning
    }

    public func delete(identifier: String = defaultIdentifier) async throws {
        guard Self.isValidIdentifier(identifier) else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        try await credentialStore.delete(service: Self.service, account: Self.account(identifier: identifier))
        try await credentialStore.delete(service: Self.reservationService, account: Self.reservationAccount(identifier: identifier))
    }

    public func reserve(
        identifier: String = defaultIdentifier,
        now: Date = Date()
    ) async throws -> AuroraNativeProvisioningReservation {
        guard Self.isValidIdentifier(identifier),
              now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970 >= 1,
              now.timeIntervalSince1970 <= Double(Int64.max),
              var source = try await load(identifier: identifier)
        else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        defer { source.resetBytes(in: 0..<source.count) }
        let nowUnix = UInt64(now.timeIntervalSince1970)
        let sourceDigest = Self.provisioningDigest(source)
        var ledger = try await loadReservationLedger(identifier: identifier)
        if let persistedSourceDigest = ledger.sourceDigest, persistedSourceDigest != sourceDigest {
            ledger = AuroraNativeProvisioningReservationLedger(sourceDigest: sourceDigest, entries: [])
        }
        ledger.prune(nowUnix: nowUnix)
        let reservation = try await reserver.reserve(
            source: source,
            spentHintKeys: ledger.entries.map(\.spentHintKey),
            now: now
        )
        guard reservation.provisioning.count > 0,
              reservation.provisioning.count <= Self.maximumBytes,
              reservation.spentHintKey.count == 48,
              reservation.relayBucketID.count == 16,
              reservation.accessHintExpiryUnix > nowUnix,
              !ledger.entries.contains(where: { $0.spentHintKey == reservation.spentHintKey }),
              ledger.entries.count < Self.maximumReservations
        else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        ledger.entries.append(.init(
            spentHintKey: reservation.spentHintKey,
            accessHintExpiryUnix: reservation.accessHintExpiryUnix
        ))
        ledger.sourceDigest = sourceDigest
        let encodedLedger = try JSONEncoder().encode(ledger)
        try await credentialStore.save(
            encodedLedger,
            service: Self.reservationService,
            account: Self.reservationAccount(identifier: identifier)
        )
        return reservation
    }

    public nonisolated static func isValidIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.utf8.count <= 128 else {
            return false
        }
        return identifier.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) ||
                ($0.value >= 65 && $0.value <= 90) ||
                ($0.value >= 97 && $0.value <= 122) ||
                $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    public nonisolated static func account(identifier: String) -> String {
        "native-provisioning:\(identifier)"
    }

    public nonisolated static func reservationAccount(identifier: String) -> String {
        "native-provisioning-reservation:\(identifier)"
    }

    private nonisolated static func provisioningDigest(_ source: Data) -> Data {
        Data(SHA256.hash(data: source))
    }

    private func loadReservationLedger(identifier: String) async throws -> AuroraNativeProvisioningReservationLedger {
        guard let encoded = try await credentialStore.load(
            service: Self.reservationService,
            account: Self.reservationAccount(identifier: identifier)
        ) else {
            return AuroraNativeProvisioningReservationLedger(entries: [])
        }
        guard !encoded.isEmpty, encoded.count <= Self.maximumReservationLedgerBytes else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        let ledger = try JSONDecoder().decode(AuroraNativeProvisioningReservationLedger.self, from: encoded)
        guard ledger.isValid() else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        return ledger
    }
}

public struct AuroraCoreNativeSessionDriver: AuroraNativeSessionDriver {
    public init() {}

    public func begin(provisioning: Data) async throws -> AuroraNativeIssuerWork {
        try await Task.detached {
            guard let work = AuroraCore.beginNativeSession(provisioning: provisioning) else {
                throw AuroraNativeTunnelError.coreOperationFailed
            }
            return work
        }.value
    }

    public func complete(handle: UInt64, issuerResponse: Data) async throws {
        try await Task.detached {
            guard AuroraCore.completeNativeSession(handle: handle, issuerResponse: issuerResponse) else {
                throw AuroraNativeTunnelError.coreOperationFailed
            }
        }.value
    }

    public func ingress(handle: UInt64, packet: Data) async throws -> [Data] {
        try await Task.detached {
            guard let packets = AuroraCore.ingressLocalPacket(handle: handle, packet: packet) else {
                throw AuroraNativeTunnelError.coreOperationFailed
            }
            return packets
        }.value
    }

    public func nextLocalPacket(handle: UInt64) async throws -> Data {
        try await Task.detached {
            guard let packet = AuroraCore.nextLocalPacket(handle: handle) else {
                throw AuroraNativeTunnelError.coreOperationFailed
            }
            return packet
        }.value
    }

    public func close(handle: UInt64) async {
        _ = await Task.detached {
            AuroraCore.closeNativeSession(handle: handle)
        }.value
    }
}

public struct URLSessionAuroraNativeIssuerTransport: AuroraNativeIssuerTransport {
    private static let maximumResponseBytes = 1 << 20

    private let session: URLSession
    private let noRedirectDelegate: AuroraNoRedirectSessionDelegate

    public init() {
        self.init(sessionConfiguration: .ephemeral)
    }

    init(configuration: URLSessionConfiguration) {
        self.init(sessionConfiguration: configuration)
    }

    private init(sessionConfiguration configuration: URLSessionConfiguration) {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let delegate = AuroraNoRedirectSessionDelegate()
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.noRedirectDelegate = delegate
    }

    public func postIssuerWork(url: URL, body: Data) async throws -> Data {
        guard url.scheme?.lowercased() == "https", !body.isEmpty else {
            throw AuroraNativeTunnelError.invalidIssuerWork
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = body
        let (responseBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.expectedContentLength <= Int64(Self.maximumResponseBytes)
        else {
            throw AuroraNativeTunnelError.unavailable
        }
        var responseBody = Data()
        if http.expectedContentLength > 0 {
            responseBody.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in responseBytes {
            guard responseBody.count < Self.maximumResponseBytes else {
                throw AuroraNativeTunnelError.unavailable
            }
            responseBody.append(byte)
        }
        guard !responseBody.isEmpty else {
            throw AuroraNativeTunnelError.unavailable
        }
        return responseBody
    }
}

public protocol AuroraPacketTunnelOutputCore: AuroraPacketTunnelCore {
    func nextOutboundPacketBatch() async throws -> AuroraPacketFlowBatch
}

public actor AuroraNativePacketTunnelCore: AuroraPacketTunnelCore, AuroraPacketTunnelOutputCore, AuroraPacketTunnelRecoverableCore {
    private let provisioningStore: AuroraNativeProvisioningStore
    private let sessionDriver: any AuroraNativeSessionDriver
    private let issuerTransport: any AuroraNativeIssuerTransport
    private var handle: UInt64?

    public init(
        provisioningStore: AuroraNativeProvisioningStore = AuroraNativeProvisioningStore(),
        sessionDriver: any AuroraNativeSessionDriver = AuroraCoreNativeSessionDriver(),
        issuerTransport: any AuroraNativeIssuerTransport = URLSessionAuroraNativeIssuerTransport()
    ) {
        self.provisioningStore = provisioningStore
        self.sessionDriver = sessionDriver
        self.issuerTransport = issuerTransport
    }

    public func connect(configuration: AuroraConfiguration) async throws {
        guard handle == nil,
              let identifier = configuration.nativeProvisioningIdentifier
        else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        var reservation = try await provisioningStore.reserve(identifier: identifier)
        defer { reservation.zero() }
        let work = try await sessionDriver.begin(provisioning: reservation.provisioning)
        do {
            let response = try await issuerTransport.postIssuerWork(
                url: try issuerURL(for: work),
                body: work.requestBody
            )
            try await sessionDriver.complete(handle: work.handle, issuerResponse: response)
            handle = work.handle
        } catch {
            await sessionDriver.close(handle: work.handle)
            throw error
        }
    }

    public func ingestPacketBatch(_ batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        try AuroraPacketBatchCodec.validate(batch)
        let handle = try establishedHandle()
        var packets: [Data] = []
        for packet in batch.packets {
            packets.append(contentsOf: try await sessionDriver.ingress(handle: handle, packet: packet))
        }
        return try packetBatch(packets)
    }

    public func nextOutboundPacketBatch() async throws -> AuroraPacketFlowBatch {
        let packet = try await sessionDriver.nextLocalPacket(handle: try establishedHandle())
        return try packetBatch([packet])
    }

    public func submitDNSMessage(_ message: AuroraDNSMessage) async throws {
        guard handle != nil, !message.message.isEmpty else {
            throw AuroraNativeTunnelError.unavailable
        }
    }

    public func submitSocketEvent(_ event: AuroraSocketEvent) async throws {
        guard handle != nil else {
            throw AuroraNativeTunnelError.unavailable
        }
    }

    public func notifyNetworkPathChange(_ change: AuroraNetworkPathChange) async {}

    public func close() async {
        guard let handle else {
            return
        }
        self.handle = nil
        await sessionDriver.close(handle: handle)
    }

    private func establishedHandle() throws -> UInt64 {
        guard let handle else {
            throw AuroraNativeTunnelError.unavailable
        }
        return handle
    }

    private func issuerURL(for work: AuroraNativeIssuerWork) throws -> URL {
        guard work.handle != 0,
              work.issuerURL.scheme?.lowercased() == "https",
              work.issuerURL.user == nil,
              work.issuerURL.password == nil,
              work.issuerCarrierPath.hasPrefix("/")
        else {
            throw AuroraNativeTunnelError.invalidIssuerWork
        }
        guard var components = URLComponents(url: work.issuerURL, resolvingAgainstBaseURL: false) else {
            throw AuroraNativeTunnelError.invalidIssuerWork
        }
        components.path = work.issuerCarrierPath
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw AuroraNativeTunnelError.invalidIssuerWork
        }
        return url
    }

    private func packetBatch(_ packets: [Data]) throws -> AuroraPacketFlowBatch {
        let protocols = try packets.map { packet -> Int in
            guard let first = packet.first else {
                throw AuroraNativeTunnelError.invalidPacket
            }
            switch first >> 4 {
            case 4:
                return 2
            case 6:
                return 30
            default:
                throw AuroraNativeTunnelError.invalidPacket
            }
        }
        let batch = AuroraPacketFlowBatch(packets: packets, protocolNumbers: protocols)
        try AuroraPacketBatchCodec.validate(batch)
        return batch
    }
}
