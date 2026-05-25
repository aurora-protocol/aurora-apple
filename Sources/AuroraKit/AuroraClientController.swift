import Foundation

@MainActor
public final class AuroraClientController: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case checking
        case ready
        case unavailable(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var tunnelState: AuroraTunnelLifecycleState = .disconnected
    @Published public private(set) var lastStatus: AuroraServerStatus?
    @Published public private(set) var redactedDiagnosticLine: String = ""

    public var configuration: AuroraConfiguration
    private let serverClient: any AuroraServerClient
    private let tunnelManager: any AuroraTunnelManager

    public init(
        configuration: AuroraConfiguration,
        serverClient: any AuroraServerClient = URLSessionAuroraServerClient(),
        tunnelManager: any AuroraTunnelManager = AuroraSystemTunnelManager()
    ) {
        self.configuration = configuration
        self.serverClient = serverClient
        self.tunnelManager = tunnelManager
    }

    @discardableResult
    public func updateEndpoint(_ endpointText: String) -> Bool {
        guard let endpoint = AuroraConfiguration.validatedEndpoint(from: endpointText) else {
            state = .unavailable("invalid server")
            return false
        }
        configuration.endpoint = endpoint
        lastStatus = nil
        state = .idle
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
