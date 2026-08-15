import Foundation

/// Supplies the native core with the application-bundled signed-seed roots.
/// Provisioning data never supplies or replaces these roots.
public enum AuroraNativeProvisioningTrust {
    private static let resourceName = "AuroraSignedSeedRoots"
    private static let resourceExtension = "bin"
    private static let maximumBytes = 64 << 10

    @discardableResult
    public static func configureBundled() -> Bool {
        guard let resourceURL = Bundle(for: AuroraNativeProvisioningTrustBundle.self).url(
            forResource: resourceName,
            withExtension: resourceExtension
        ), var roots = try? Data(contentsOf: resourceURL, options: [.mappedIfSafe])
        else {
            return false
        }
        defer { roots.resetBytes(in: 0..<roots.count) }
        return configure(roots)
    }

    @discardableResult
    public static func configure(_ roots: Data) -> Bool {
        guard !roots.isEmpty, roots.count <= maximumBytes else {
            return false
        }
        var copy = Data(roots)
        defer { copy.resetBytes(in: 0..<copy.count) }
        return AuroraCore.configureNativeProvisioningTrust(copy)
    }
}

private final class AuroraNativeProvisioningTrustBundle: NSObject {}
