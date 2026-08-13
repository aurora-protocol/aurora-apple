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
    public static let defaultIdentifier = "active"
    public static let maximumBytes = 1 << 20

    private let credentialStore: any AuroraSecureCredentialStore

    public init(credentialStore: any AuroraSecureCredentialStore = AuroraKeychainCredentialStore()) {
        self.credentialStore = credentialStore
    }

    public func save(_ provisioning: Data, identifier: String = defaultIdentifier) async throws {
        guard Self.isValidIdentifier(identifier),
              !provisioning.isEmpty,
              provisioning.count <= Self.maximumBytes
        else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        try await credentialStore.save(provisioning, service: Self.service, account: Self.account(identifier: identifier))
    }

    public func load(identifier: String = defaultIdentifier) async throws -> Data? {
        guard Self.isValidIdentifier(identifier) else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        return try await credentialStore.load(service: Self.service, account: Self.account(identifier: identifier))
    }

    public func delete(identifier: String = defaultIdentifier) async throws {
        guard Self.isValidIdentifier(identifier) else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        try await credentialStore.delete(service: Self.service, account: Self.account(identifier: identifier))
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
              let identifier = configuration.nativeProvisioningIdentifier,
              let provisioning = try await provisioningStore.load(identifier: identifier),
              !provisioning.isEmpty
        else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        let work = try await sessionDriver.begin(provisioning: provisioning)
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
        _ = try AuroraPacketBatchCodec.encode(batch)
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
        _ = try AuroraPacketBatchCodec.encode(batch)
        return batch
    }
}
