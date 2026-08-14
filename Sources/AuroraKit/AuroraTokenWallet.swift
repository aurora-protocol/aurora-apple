import Foundation

#if canImport(Security)
import Security
#endif

public protocol AuroraSecureCredentialStore: Sendable {
    func save(_ data: Data, service: String, account: String) async throws
    func load(service: String, account: String) async throws -> Data?
    func delete(service: String, account: String) async throws
}

public enum AuroraSecureCredentialStoreError: Error, Equatable, Sendable {
    case unsupportedPlatform
    case keychainStatus(Int32)
    case unexpectedData
}

public enum AuroraAppleSharedContainer {
    public static let appGroupIdentifierInfoKey = "AuroraAppGroupIdentifier"
    public static let keychainAccessGroupInfoKey = "AuroraKeychainAccessGroup"
    public static let defaultAppGroupIdentifier = "group.org.aurora-protocol.aurora.shared"

    public static func appGroupIdentifier(bundle: Bundle = .main) -> String {
        configuredString(for: appGroupIdentifierInfoKey, in: bundle) ?? defaultAppGroupIdentifier
    }

    public static func keychainAccessGroup(bundle: Bundle = .main) -> String? {
        configuredString(for: keychainAccessGroupInfoKey, in: bundle)
    }

    private static func configuredString(for key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct AuroraTokenWalletEntry: Codable, Equatable, Sendable {
    public var relayBucketID: String
    public var accessHintCredential: Data
    public var admissionProof: Data
    public var tokenAuthenticator: Data
    public var hintSecret: Data
    public var bridgeBundle: Data?
    public var relayDescriptor: Data?
    public var expiresAtUnix: Int64?

    public init(
        relayBucketID: String,
        accessHintCredential: Data,
        admissionProof: Data,
        tokenAuthenticator: Data,
        hintSecret: Data,
        bridgeBundle: Data? = nil,
        relayDescriptor: Data? = nil,
        expiresAtUnix: Int64? = nil
    ) {
        self.relayBucketID = relayBucketID
        self.accessHintCredential = accessHintCredential
        self.admissionProof = admissionProof
        self.tokenAuthenticator = tokenAuthenticator
        self.hintSecret = hintSecret
        self.bridgeBundle = bridgeBundle
        self.relayDescriptor = relayDescriptor
        self.expiresAtUnix = expiresAtUnix
    }

    public var redactedDiagnosticLine: String {
        var fields = [
            "relay_bucket_id=\(relayBucketID)",
            "access_hint_credential=<redacted>",
            "admission_proof=<redacted>",
            "token_authenticator=<redacted>",
            "hint_secret=<redacted>",
        ]
        if bridgeBundle != nil {
            fields.append("bridge_bundle=<redacted>")
        }
        if relayDescriptor != nil {
            fields.append("relay_descriptor=<redacted>")
        }
        if let expiresAtUnix {
            fields.append("expires_at_unix=\(expiresAtUnix)")
        }
        return AuroraRedactor.redact(fields.joined(separator: " "))
    }
}

public actor AuroraTokenWallet {
    public static let service = "org.aurora-protocol.aurora.token-wallet"

    private let credentialStore: any AuroraSecureCredentialStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(credentialStore: any AuroraSecureCredentialStore = AuroraKeychainCredentialStore()) {
        self.credentialStore = credentialStore
    }

    public func store(_ entry: AuroraTokenWalletEntry) async throws {
        let data = try encoder.encode(entry)
        try await credentialStore.save(
            data,
            service: Self.service,
            account: Self.account(relayBucketID: entry.relayBucketID)
        )
    }

    public func load(relayBucketID: String) async throws -> AuroraTokenWalletEntry? {
        guard let data = try await credentialStore.load(
            service: Self.service,
            account: Self.account(relayBucketID: relayBucketID)
        ) else {
            return nil
        }
        return try decoder.decode(AuroraTokenWalletEntry.self, from: data)
    }

    public func delete(relayBucketID: String) async throws {
        try await credentialStore.delete(
            service: Self.service,
            account: Self.account(relayBucketID: relayBucketID)
        )
    }

    public nonisolated static func account(relayBucketID: String) -> String {
        "relay-bucket:\(relayBucketID)"
    }
}

#if canImport(Security)
protocol AuroraKeychainItemStore: AnyObject {
    func add(_ query: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

private final class AuroraSystemKeychainItemStore: AuroraKeychainItemStore, @unchecked Sendable {
    static let shared = AuroraSystemKeychainItemStore()

    func add(_ query: CFDictionary) -> OSStatus {
        SecItemAdd(query, nil)
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

public struct AuroraKeychainCredentialStore: AuroraSecureCredentialStore, @unchecked Sendable {
    public let accessGroup: String?
    private let itemStore: any AuroraKeychainItemStore

    public init(accessGroup: String? = AuroraAppleSharedContainer.keychainAccessGroup()) {
        self.init(accessGroup: accessGroup, itemStore: AuroraSystemKeychainItemStore.shared)
    }

    init(accessGroup: String?, itemStore: any AuroraKeychainItemStore) {
        self.accessGroup = accessGroup
        self.itemStore = itemStore
    }

    public func save(_ data: Data, service: String, account: String) async throws {
        let query = baseQuery(service: service, account: account)
        let attributes = [kSecValueData as String: data] as CFDictionary
        let updateStatus = itemStore.update(query as CFDictionary, attributes: attributes)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw AuroraSecureCredentialStoreError.keychainStatus(updateStatus)
        }

        var createQuery = query
        createQuery[kSecValueData as String] = data
        createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let createStatus = itemStore.add(createQuery as CFDictionary)
        if createStatus == errSecSuccess {
            return
        }
        guard createStatus == errSecDuplicateItem else {
            throw AuroraSecureCredentialStoreError.keychainStatus(createStatus)
        }
        let retryStatus = itemStore.update(query as CFDictionary, attributes: attributes)
        guard retryStatus == errSecSuccess else {
            throw AuroraSecureCredentialStoreError.keychainStatus(retryStatus)
        }
    }

    public func load(service: String, account: String) async throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = itemStore.copyMatching(query as CFDictionary, result: &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AuroraSecureCredentialStoreError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            throw AuroraSecureCredentialStoreError.unexpectedData
        }
        return data
    }

    public func delete(service: String, account: String) async throws {
        let status = itemStore.delete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuroraSecureCredentialStoreError.keychainStatus(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
#else
public struct AuroraKeychainCredentialStore: AuroraSecureCredentialStore, Sendable {
    public let accessGroup: String?

    public init(accessGroup: String? = AuroraAppleSharedContainer.keychainAccessGroup()) {
        self.accessGroup = accessGroup
    }

    public func save(_ data: Data, service: String, account: String) async throws {
        throw AuroraSecureCredentialStoreError.unsupportedPlatform
    }

    public func load(service: String, account: String) async throws -> Data? {
        throw AuroraSecureCredentialStoreError.unsupportedPlatform
    }

    public func delete(service: String, account: String) async throws {
        throw AuroraSecureCredentialStoreError.unsupportedPlatform
    }
}
#endif
