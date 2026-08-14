import Foundation

enum AuroraNativeTrustConfigurationError: Error, Equatable, Sendable {
    case resourceUnavailable
    case invalidResource
    case coreRejected
}

protocol AuroraNativeTrustConfiguring: Sendable {
    func configure() throws
}

struct AuroraBundleNativeTrustConfigurator: AuroraNativeTrustConfiguring {
    private static let maximumResourceBytes = 65_536

    private let resourceLoader: @Sendable () throws -> Data
    private let configureCore: @Sendable (Data) -> Bool

    init() {
        self.init(resourceURL: Bundle(for: AuroraKitResourceBundle.self).url(
            forResource: "AuroraSignedSeedTrust",
            withExtension: "bin"
        ))
    }

    init(resourceURL: URL?) {
        self.init(
            resourceLoader: {
                guard let resourceURL else {
                    throw AuroraNativeTrustConfigurationError.resourceUnavailable
                }
                do {
                    return try Data(contentsOf: resourceURL)
                } catch {
                    throw AuroraNativeTrustConfigurationError.resourceUnavailable
                }
            },
            configureCore: AuroraCore.configureNativeProvisioningTrust
        )
    }

    init(
        resourceLoader: @escaping @Sendable () throws -> Data,
        configureCore: @escaping @Sendable (Data) -> Bool
    ) {
        self.resourceLoader = resourceLoader
        self.configureCore = configureCore
    }

    func configure() throws {
        var encoded: Data
        do {
            encoded = try resourceLoader()
        } catch let error as AuroraNativeTrustConfigurationError {
            throw error
        } catch {
            throw AuroraNativeTrustConfigurationError.resourceUnavailable
        }
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        guard !encoded.isEmpty, encoded.count <= Self.maximumResourceBytes else {
            throw AuroraNativeTrustConfigurationError.invalidResource
        }
        guard configureCore(encoded) else {
            throw AuroraNativeTrustConfigurationError.coreRejected
        }
    }
}

protocol AuroraNativeCoreBinding: Sendable {
    func begin(provisioning: Data) -> AuroraNativeIssuerWork?
    func complete(handle: UInt64, issuerResponse: Data) -> Bool
    func ingress(handle: UInt64, packet: Data) -> [Data]?
    func nextLocalPacket(handle: UInt64) -> Data?
    func close(handle: UInt64) -> Bool
}

struct AuroraCoreNativeBinding: AuroraNativeCoreBinding {
    func begin(provisioning: Data) -> AuroraNativeIssuerWork? {
        AuroraCore.beginNativeSession(provisioning: provisioning)
    }

    func complete(handle: UInt64, issuerResponse: Data) -> Bool {
        AuroraCore.completeNativeSession(handle: handle, issuerResponse: issuerResponse)
    }

    func ingress(handle: UInt64, packet: Data) -> [Data]? {
        AuroraCore.ingressLocalPacket(handle: handle, packet: packet)
    }

    func nextLocalPacket(handle: UInt64) -> Data? {
        AuroraCore.nextLocalPacket(handle: handle)
    }

    func close(handle: UInt64) -> Bool {
        AuroraCore.closeNativeSession(handle: handle)
    }
}

private final class AuroraKitResourceBundle {}
