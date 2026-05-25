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
    @Published public private(set) var lastStatus: AuroraServerStatus?
    @Published public private(set) var redactedDiagnosticLine: String = ""

    public var configuration: AuroraConfiguration
    private let serverClient: any AuroraServerClient

    public init(
        configuration: AuroraConfiguration,
        serverClient: any AuroraServerClient = URLSessionAuroraServerClient()
    ) {
        self.configuration = configuration
        self.serverClient = serverClient
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
}
