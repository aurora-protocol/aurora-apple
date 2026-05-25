import Foundation

#if canImport(NetworkExtension)
import NetworkExtension
#endif

public enum AuroraTunnelConnectionStatus: Equatable, Sendable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
}

public enum AuroraTunnelLifecycleState: Equatable, Sendable {
    case disconnected
    case installing
    case installed
    case connecting
    case connected
    case disconnecting
    case unavailable(String)
}

public enum AuroraTunnelManagerError: Error, Equatable, Sendable {
    case unsupportedPlatform
    case notInstalled
    case preferencesUnavailable
}

public protocol AuroraTunnelManager: Sendable {
    func install(configuration: AuroraConfiguration) async throws
    func start() async throws
    func stop() async
    func status() async -> AuroraTunnelConnectionStatus
}

public struct AuroraTunnelProfile {
    public static let endpointKey = "endpoint"
    public static let routePolicyKey = "routePolicy"

    public var localizedDescription: String
    public var providerBundleIdentifier: String
    public var serverAddress: String
    public var providerConfiguration: [String: String]

    public init(
        configuration: AuroraConfiguration,
        providerBundleIdentifier: String,
        localizedDescription: String = "Aurora"
    ) {
        self.localizedDescription = localizedDescription
        self.providerBundleIdentifier = providerBundleIdentifier
        self.serverAddress = configuration.endpoint.absoluteString
        self.providerConfiguration = [
            Self.endpointKey: configuration.endpoint.absoluteString,
            Self.routePolicyKey: configuration.routePolicy,
        ]
    }

    public static func configuration(from providerConfiguration: [String: Any]?) -> AuroraConfiguration? {
        guard let endpointText = providerConfiguration?[endpointKey] as? String,
              let endpoint = AuroraConfiguration.validatedEndpoint(from: endpointText)
        else {
            return nil
        }
        let routePolicy = providerConfiguration?[routePolicyKey] as? String ?? "balanced"
        return AuroraConfiguration(endpoint: endpoint, routePolicy: routePolicy)
    }
}

public enum AuroraTunnelProviderBundleIdentifier {
    public static let iOS = "org.aurora-protocol.aurora.ios.packet-tunnel"
    public static let macOS = "org.aurora-protocol.aurora.macos.packet-tunnel"

    public static var current: String {
        #if os(iOS)
        iOS
        #elseif os(macOS)
        macOS
        #else
        ""
        #endif
    }
}

#if canImport(NetworkExtension)
public actor AuroraSystemTunnelManager: AuroraTunnelManager {
    private let providerBundleIdentifier: String
    private var cachedManager: NETunnelProviderManager?

    public init(providerBundleIdentifier: String = AuroraTunnelProviderBundleIdentifier.current) {
        self.providerBundleIdentifier = providerBundleIdentifier
    }

    public func install(configuration: AuroraConfiguration) async throws {
        let manager = try await loadOrCreateManager()
        let profile = AuroraTunnelProfile(
            configuration: configuration,
            providerBundleIdentifier: providerBundleIdentifier
        )
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = profile.providerBundleIdentifier
        tunnelProtocol.serverAddress = profile.serverAddress
        tunnelProtocol.providerConfiguration = profile.providerConfiguration
        tunnelProtocol.disconnectOnSleep = false

        manager.localizedDescription = profile.localizedDescription
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true

        try await save(manager)
        cachedManager = manager
    }

    public func start() async throws {
        guard let manager = try await loadInstalledManager() else {
            throw AuroraTunnelManagerError.notInstalled
        }
        try manager.connection.startVPNTunnel()
        cachedManager = manager
    }

    public func stop() async {
        guard let manager = try? await loadInstalledManager() else {
            return
        }
        manager.connection.stopVPNTunnel()
        cachedManager = manager
    }

    public func status() async -> AuroraTunnelConnectionStatus {
        guard let manager = try? await loadInstalledManager() else {
            return .disconnected
        }
        return AuroraTunnelConnectionStatus(manager.connection.status)
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let manager = try await loadInstalledManager() {
            return manager
        }
        return NETunnelProviderManager()
    }

    private func loadInstalledManager() async throws -> NETunnelProviderManager? {
        if let cachedManager {
            return cachedManager
        }
        let managers = try await Self.loadAllManagers().managers
        return managers.first { manager in
            guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return tunnelProtocol.providerBundleIdentifier == providerBundleIdentifier
        }
    }

    private static func loadAllManagers() async throws -> LoadedTunnelManagers {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: LoadedTunnelManagers(managers: managers ?? []))
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }
}

private struct LoadedTunnelManagers: @unchecked Sendable {
    var managers: [NETunnelProviderManager]
}

private extension AuroraTunnelConnectionStatus {
    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid:
            self = .invalid
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .reasserting:
            self = .reasserting
        case .disconnecting:
            self = .disconnecting
        @unknown default:
            self = .invalid
        }
    }
}
#else
public actor AuroraSystemTunnelManager: AuroraTunnelManager {
    public init(providerBundleIdentifier: String = AuroraTunnelProviderBundleIdentifier.current) {}

    public func install(configuration: AuroraConfiguration) async throws {
        throw AuroraTunnelManagerError.unsupportedPlatform
    }

    public func start() async throws {
        throw AuroraTunnelManagerError.unsupportedPlatform
    }

    public func stop() async {}

    public func status() async -> AuroraTunnelConnectionStatus {
        .invalid
    }
}
#endif
