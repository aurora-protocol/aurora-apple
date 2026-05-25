import Foundation

@MainActor
public final class AuroraClientController: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case checking
        case ready
        case unavailable(String)
    }

    public enum PacketExchangeState: Equatable, Sendable {
        case idle
        case checking
        case ready(packetCount: Int)
        case unavailable(String)
    }

    public enum CredentialState: Equatable, Sendable {
        case idle
        case issuing
        case ready(relayBucketID: String)
        case unavailable(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var packetExchangeState: PacketExchangeState = .idle
    @Published public private(set) var credentialState: CredentialState = .idle
    @Published public private(set) var lastPacketExchange: AuroraPacketFlowBatch?
    @Published public private(set) var tunnelState: AuroraTunnelLifecycleState = .disconnected
    @Published public private(set) var lastStatus: AuroraServerStatus?
    @Published public private(set) var redactedDiagnosticLine: String = ""

    public var configuration: AuroraConfiguration
    private let serverClient: any AuroraServerClient
    private let packetClient: any AuroraPacketExchangeClient
    private let issuerClient: any AuroraIssuerClient
    private let tokenWallet: AuroraTokenWallet
    private let tunnelManager: any AuroraTunnelManager
    private var lastIssuedToken: AuroraIssuedAdmissionToken?

    public init(
        configuration: AuroraConfiguration,
        serverClient: any AuroraServerClient = URLSessionAuroraServerClient(),
        packetClient: any AuroraPacketExchangeClient = URLSessionAuroraServerClient(),
        issuerClient: any AuroraIssuerClient = URLSessionAuroraServerClient(),
        tokenWallet: AuroraTokenWallet = AuroraTokenWallet(),
        tunnelManager: any AuroraTunnelManager = AuroraSystemTunnelManager()
    ) {
        self.configuration = configuration
        self.serverClient = serverClient
        self.packetClient = packetClient
        self.issuerClient = issuerClient
        self.tokenWallet = tokenWallet
        self.tunnelManager = tunnelManager
    }

    @discardableResult
    public func updateEndpoint(_ endpointText: String) -> Bool {
        guard let endpoint = AuroraConfiguration.validatedEndpoint(from: endpointText) else {
            state = .unavailable("invalid server")
            lastPacketExchange = nil
            packetExchangeState = .idle
            lastIssuedToken = nil
            credentialState = .idle
            return false
        }
        configuration.endpoint = endpoint
        lastStatus = nil
        state = .idle
        lastPacketExchange = nil
        packetExchangeState = .idle
        lastIssuedToken = nil
        credentialState = .idle
        redactedDiagnosticLine = AuroraRedactor.redact("endpoint=\(endpoint.absoluteString)")
        return true
    }

    public func refreshStatus() async {
        state = .checking
        do {
            let status = try await serverClient.fetchStatus(endpoint: configuration.endpoint)
            lastStatus = status
            state = status.ready ? .ready : .unavailable("server unavailable")
            redactedDiagnosticLine = AuroraRedactor.redact(
                "endpoint=\(configuration.endpoint.absoluteString) ready=\(status.ready)"
            )
        } catch {
            state = .unavailable("server unavailable")
            redactedDiagnosticLine = AuroraRedactor.redact("endpoint=\(configuration.endpoint.absoluteString) error=\(error)")
        }
    }

    public func checkPacketExchange() async {
        packetExchangeState = .checking
        let probe = AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [2]
        )
        do {
            let exchanged = try await packetClient.exchangePacketBatch(
                endpoint: configuration.endpoint,
                batch: probe
            )
            lastPacketExchange = exchanged
            packetExchangeState = .ready(packetCount: exchanged.packets.count)
            redactedDiagnosticLine = AuroraRedactor.redact(
                "endpoint=\(configuration.endpoint.absoluteString) packet_exchange=ready packets=\(exchanged.packets.count)"
            )
        } catch {
            lastPacketExchange = nil
            packetExchangeState = .unavailable("packet exchange unavailable")
            redactedDiagnosticLine = AuroraRedactor.redact(
                "endpoint=\(configuration.endpoint.absoluteString) packet_exchange_error=\(error)"
            )
        }
    }

    public func issueAdmissionToken(request: AuroraBlindRSAIssueRequest? = nil) async {
        credentialState = .issuing
        do {
            let metadata = try await issuerClient.fetchIssuerMetadata(endpoint: configuration.endpoint)
            guard !metadata.issuerMetadata.isEmpty, metadata.issuerMetadataHash.count == 48 else {
                throw AuroraClientError.invalidIssuerResponse("issuer metadata unavailable")
            }
            let issueRequest = try request ?? AuroraBlindRSAIssueRequest.random(
                nowUnix: Int64(Date().timeIntervalSince1970)
            )
            let issued = try await issuerClient.issueBlindRSAAdmissionToken(
                endpoint: configuration.endpoint,
                request: issueRequest
            )
            guard issued.issuerMetadataHash.isEmpty || issued.issuerMetadataHash == metadata.issuerMetadataHash else {
                throw AuroraClientError.invalidAdmissionProof("issuer metadata hash mismatch")
            }
            let relayBucketID = issued.relayBucketIDHex
            try await tokenWallet.store(AuroraTokenWalletEntry(
                relayBucketID: relayBucketID,
                accessHintCredential: Data(),
                admissionProof: issued.admissionProof,
                tokenAuthenticator: issued.tokenAuthenticator,
                hintSecret: Data(),
                expiresAtUnix: issued.expiryUnix
            ))
            lastIssuedToken = issued
            credentialState = .ready(relayBucketID: relayBucketID)
            redactedDiagnosticLine = AuroraRedactor.redact(
                "endpoint=\(configuration.endpoint.absoluteString) credential=ready \(issued.redactedDiagnosticLine)"
            )
        } catch {
            lastIssuedToken = nil
            credentialState = .unavailable("credential unavailable")
            redactedDiagnosticLine = AuroraRedactor.redact(
                "endpoint=\(configuration.endpoint.absoluteString) credential_error=\(error)"
            )
        }
    }

    public func installTunnel() async {
        tunnelState = .installing
        do {
            try await tunnelManager.install(configuration: configuration)
            tunnelState = .installed
            redactedDiagnosticLine = AuroraRedactor.redact(
                "endpoint=\(configuration.endpoint.absoluteString) tunnel=installed"
            )
        } catch {
            tunnelState = .unavailable("tunnel unavailable")
            redactedDiagnosticLine = AuroraRedactor.redact(
                "endpoint=\(configuration.endpoint.absoluteString) tunnel_error=\(error)"
            )
        }
    }

    public func startTunnel() async {
        tunnelState = .connecting
        do {
            try await tunnelManager.start()
            tunnelState = .connected
            redactedDiagnosticLine = AuroraRedactor.redact(
                "endpoint=\(configuration.endpoint.absoluteString) tunnel=connected"
            )
        } catch {
            tunnelState = .unavailable("tunnel unavailable")
            redactedDiagnosticLine = AuroraRedactor.redact(
                "endpoint=\(configuration.endpoint.absoluteString) tunnel_error=\(error)"
            )
        }
    }

    public func connectTunnel() async {
        await refreshStatus()
        guard case .ready = state else {
            return
        }

        await issueAdmissionToken()
        guard case .ready = credentialState else {
            return
        }

        await checkPacketExchange()
        guard case .ready = packetExchangeState else {
            return
        }

        await installTunnel()
        guard case .installed = tunnelState else {
            return
        }

        await startTunnel()
    }

    public func stopTunnel() async {
        tunnelState = .disconnecting
        await tunnelManager.stop()
        tunnelState = .disconnected
        redactedDiagnosticLine = AuroraRedactor.redact(
            "endpoint=\(configuration.endpoint.absoluteString) tunnel=disconnected"
        )
    }

    public func refreshTunnelStatus() async {
        tunnelState = AuroraTunnelLifecycleState(await tunnelManager.status())
    }
}

private extension AuroraTunnelLifecycleState {
    init(_ status: AuroraTunnelConnectionStatus) {
        switch status {
        case .invalid:
            self = .unavailable("tunnel unavailable")
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .reasserting:
            self = .connecting
        case .disconnecting:
            self = .disconnecting
        }
    }
}
