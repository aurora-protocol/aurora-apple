import Foundation

public protocol AuroraPortableProfileStore: Sendable {
    func loadPortableProfile() throws -> String?
    func savePortableProfile(_ profileText: String) throws
}

public struct AuroraUserDefaultsProfileStore: AuroraPortableProfileStore, @unchecked Sendable {
    public static let profileKey = "org.aurora-protocol.aurora.portable-profile"

    private let defaults: UserDefaults

    public init(
        appGroupIdentifier: String = AuroraAppleSharedContainer.appGroupIdentifier(),
        defaults: UserDefaults? = nil
    ) {
        if let defaults {
            self.defaults = defaults
        } else if let suiteDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            self.defaults = suiteDefaults
        } else {
            self.defaults = .standard
        }
    }

    public func loadPortableProfile() throws -> String? {
        defaults.string(forKey: Self.profileKey)
    }

    public func savePortableProfile(_ profileText: String) throws {
        let sanitizedProfile = try AuroraPortableProfile.parse(profileText).tomlString()
        defaults.set(sanitizedProfile, forKey: Self.profileKey)
    }
}
