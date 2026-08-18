import Foundation
import XCTest
@testable import AuroraKit

final class AuroraRedactorAndWalletTests: XCTestCase {
    func testNativeProvisioningTrustRejectsEmptyConfiguration() {
        XCTAssertFalse(AuroraNativeProvisioningTrust.configure(Data()))
    }

    func testServerStatusDecodesHealthResponse() throws {
        let data = Data(#"{"ready":true,"issuer":true,"cover":true}"#.utf8)
        let status = try JSONDecoder().decode(AuroraServerStatus.self, from: data)

        XCTAssertTrue(status.ready)
        XCTAssertTrue(status.issuer)
        XCTAssertTrue(status.cover)
        XCTAssertEqual(status.summary, "ready")
    }

    func testRedactorRemovesSensitiveFields() {
        let raw = """
        admission_proof=abcdef hint_secret=123456 token_authenticator=feedface normal=ok
        """

        let redacted = AuroraRedactor.redact(raw)

        XCTAssertFalse(redacted.contains("abcdef"))
        XCTAssertFalse(redacted.contains("123456"))
        XCTAssertFalse(redacted.contains("feedface"))
        XCTAssertTrue(redacted.contains("normal=ok"))
    }

    func testRedactorRemovesCredentialAndReplayFields() {
        let raw = """
        access_hint_credential=secret-access replay_nonce=secret-replay bridge_bundle=secret-bundle relay_descriptor=secret-relay normal=ok
        """

        let redacted = AuroraRedactor.redact(raw)

        XCTAssertFalse(redacted.contains("secret-access"))
        XCTAssertFalse(redacted.contains("secret-replay"))
        XCTAssertFalse(redacted.contains("secret-bundle"))
        XCTAssertFalse(redacted.contains("secret-relay"))
        XCTAssertTrue(redacted.contains("normal=ok"))
    }

    func testTokenWalletStoresCredentialsInSecureStoreByRelayBucket() async throws {
        let store = MockSecureCredentialStore()
        let wallet = AuroraTokenWallet(credentialStore: store)
        let entry = AuroraTokenWalletEntry(
            relayBucketID: "bucket-a",
            accessHintCredential: Data("secret-access".utf8),
            admissionProof: Data("secret-proof".utf8),
            tokenAuthenticator: Data("secret-token".utf8),
            hintSecret: Data("secret-hint".utf8),
            bridgeBundle: Data("secret-bridge".utf8),
            relayDescriptor: Data("secret-relay".utf8),
            expiresAtUnix: 1_800_000_000
        )

        try await wallet.store(entry)

        let lastSave = await store.lastSave
        let saved = await store.savedData(service: AuroraTokenWallet.service, account: "relay-bucket:bucket-a")
        XCTAssertEqual(lastSave?.service, AuroraTokenWallet.service)
        XCTAssertEqual(lastSave?.account, "relay-bucket:bucket-a")
        XCTAssertNotNil(saved)
        let loaded = try await wallet.load(relayBucketID: "bucket-a")
        XCTAssertEqual(loaded, entry)
    }

    func testTokenWalletDiagnosticRedactsCredentialMaterial() {
        let entry = AuroraTokenWalletEntry(
            relayBucketID: "bucket-a",
            accessHintCredential: Data("secret-access".utf8),
            admissionProof: Data("secret-proof".utf8),
            tokenAuthenticator: Data("secret-token".utf8),
            hintSecret: Data("secret-hint".utf8),
            bridgeBundle: Data("secret-bridge".utf8),
            relayDescriptor: Data("secret-relay".utf8),
            expiresAtUnix: 1_800_000_000
        )

        let line = entry.redactedDiagnosticLine

        XCTAssertTrue(line.contains("relay_bucket_id=bucket-a"))
        XCTAssertTrue(line.contains("expires_at_unix=1800000000"))
        XCTAssertFalse(line.contains("secret-access"))
        XCTAssertFalse(line.contains("secret-proof"))
        XCTAssertFalse(line.contains("secret-token"))
        XCTAssertFalse(line.contains("secret-hint"))
        XCTAssertFalse(line.contains("secret-bridge"))
        XCTAssertFalse(line.contains("secret-relay"))
    }

    func testTokenWalletDeletesRelayBucketCredential() async throws {
        let store = MockSecureCredentialStore()
        let wallet = AuroraTokenWallet(credentialStore: store)
        let entry = AuroraTokenWalletEntry(
            relayBucketID: "bucket-a",
            accessHintCredential: Data("secret-access".utf8),
            admissionProof: Data("secret-proof".utf8),
            tokenAuthenticator: Data("secret-token".utf8),
            hintSecret: Data("secret-hint".utf8),
            bridgeBundle: nil,
            relayDescriptor: nil,
            expiresAtUnix: nil
        )

        try await wallet.store(entry)
        try await wallet.delete(relayBucketID: "bucket-a")

        let deleted = await store.deletedKeys
        XCTAssertEqual(deleted, [
            MockSecureCredentialStore.Key(service: AuroraTokenWallet.service, account: "relay-bucket:bucket-a"),
        ])
        let loaded = try await wallet.load(relayBucketID: "bucket-a")
        XCTAssertNil(loaded)
    }

}
