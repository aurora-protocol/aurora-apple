import Foundation
import XCTest
@testable import AuroraKit

final class AuroraControllerTests: XCTestCase {
    func testControllerRefreshesStatusThroughInjectedClient() async {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true))
        )

        await controller.refreshStatus()

        let state = await controller.state
        XCTAssertEqual(state, .ready)
    }

    func testControllerRequiresFullServerSurfaceBeforeReady() async {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: false))
        )

        await controller.refreshStatus()

        let state = await controller.state
        XCTAssertEqual(state, .unavailable("server unavailable"))
    }

    func testControllerUpdatesEndpointFromValidatedUserInput() async {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true))
        )

        let updated = await controller.updateEndpoint("https://aurora.example:9443")
        let endpoint = await controller.configuration.endpoint
        let state = await controller.state

        XCTAssertTrue(updated)
        XCTAssertEqual(endpoint.absoluteString, "https://aurora.example:9443")
        XCTAssertEqual(state, .idle)
    }

    func testControllerPersistsEndpointUpdatesAsSharedPortableProfile() async throws {
        let store = MockPortableProfileStore()
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            profileStore: store
        )

        let updated = await controller.updateEndpoint("https://relay.example:9443")

        let savedProfile = try XCTUnwrap(store.savedProfileText)
        let reparsed = try AuroraPortableProfile.parse(savedProfile)
        XCTAssertTrue(updated)
        XCTAssertEqual(reparsed.endpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(reparsed.localMode, "platform-vpn")
        XCTAssertFalse(savedProfile.contains("admission_proof"))
        XCTAssertFalse(savedProfile.contains("token_authenticator"))
        XCTAssertFalse(savedProfile.contains("hint_secret"))
    }

    func testControllerImportsNativeProvisioningIntoSecureStoreWithoutExportingIt() async throws {
        let credentialStore = MockSecureCredentialStore()
        let provisioningStore = AuroraNativeProvisioningStore(credentialStore: credentialStore, validator: MockNativeProvisioningValidator())
        let profileStore = MockPortableProfileStore()
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            profileStore: profileStore,
            nativeProvisioningStore: provisioningStore
        )
        let provisioning = Data(repeating: 0xa7, count: 64)

        let imported = await controller.importNativeProvisioning(provisioning)
        let rejected = await controller.importNativeProvisioning(Data())

        let configuration = await controller.configuration
        let hasNativeProvisioning = await controller.hasNativeProvisioning
        let stored = await credentialStore.savedData(
            service: AuroraNativeProvisioningStore.service,
            account: AuroraNativeProvisioningStore.account(identifier: AuroraNativeProvisioningStore.defaultIdentifier)
        )
        let exported = await controller.exportPortableProfile()
        XCTAssertTrue(imported)
        XCTAssertFalse(rejected)
        XCTAssertEqual(configuration.nativeProvisioningIdentifier, AuroraNativeProvisioningStore.defaultIdentifier)
        XCTAssertTrue(hasNativeProvisioning)
        XCTAssertEqual(stored, provisioning)
        XCTAssertFalse(exported.contains("nativeProvisioningIdentifier"))
        XCTAssertFalse(exported.contains(provisioning.base64EncodedString()))
    }

    func testControllerRestoresAndRemovesNativeProvisioning() async throws {
        let credentialStore = MockSecureCredentialStore()
        let provisioningStore = AuroraNativeProvisioningStore(credentialStore: credentialStore, validator: MockNativeProvisioningValidator())
        let provisioning = Data(repeating: 0xb8, count: 64)
        try await provisioningStore.save(provisioning)
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!),
            nativeProvisioningStore: provisioningStore
        )

        await controller.restoreNativeProvisioning()
        let restored = await controller.configuration.nativeProvisioningIdentifier
        let availableAfterRestore = await controller.hasNativeProvisioning

        await controller.removeNativeProvisioning()
        let removed = await controller.configuration.nativeProvisioningIdentifier
        let availableAfterRemoval = await controller.hasNativeProvisioning
        let stored = try await provisioningStore.load()
        XCTAssertEqual(restored, AuroraNativeProvisioningStore.defaultIdentifier)
        XCTAssertTrue(availableAfterRestore)
        XCTAssertNil(removed)
        XCTAssertFalse(availableAfterRemoval)
        XCTAssertNil(stored)
    }

    func testEndpointValidationRejectsRemotePlainHTTPButAllowsLoopback() {
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "http://relay.example:9443"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "http://203.0.113.7:9443"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "http://127.example.com:9443"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "http://127.0.0.1.example:9443"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "http://127.256.0.1:9443"))
        XCTAssertNotNil(AuroraConfiguration.validatedEndpoint(from: "http://127.0.0.1:9443"))
        XCTAssertNotNil(AuroraConfiguration.validatedEndpoint(from: "http://[::1]:9443"))
        XCTAssertNotNil(AuroraConfiguration.validatedEndpoint(from: "https://relay.example:9443"))
    }

    func testEndpointValidationRequiresOriginOnlyURL() {
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "https://relay.example:9443/private"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "https://relay.example:9443/?debug=true"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "https://relay.example:9443/#fragment"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "https://user@relay.example:9443"))
        XCTAssertNil(AuroraConfiguration.validatedEndpoint(from: "https://user:pass@relay.example:9443"))
        XCTAssertNotNil(AuroraConfiguration.validatedEndpoint(from: "https://relay.example:9443/"))
    }

    func testControllerRejectsInvalidEndpointInput() async {
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true))
        )

        let updated = await controller.updateEndpoint("not a server")
        let endpoint = await controller.configuration.endpoint
        let state = await controller.state

        XCTAssertFalse(updated)
        XCTAssertEqual(endpoint.absoluteString, "http://127.0.0.1:9443")
        XCTAssertEqual(state, .unavailable("invalid server"))
    }

    func testControllerImportsPortableProfileAndResetsDerivedState() async {
        let packetClient = MockPacketExchangeClient(outboundBatch: AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x15])],
            protocolNumbers: [2]
        ))
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            packetClient: packetClient
        )
        await controller.refreshStatus()
        await controller.checkPacketExchange()

        let imported = await controller.importPortableProfile("""
        [aurora]
        version = "2.0"
        profile = "adversarial-dpi"
        route = "split-2"
        speed = "balanced"

        [local]
        mode = "platform-vpn"
        dns = "through-aurora"

        [methods]
        allow_h2 = true
        allow_h1_ws = true
        allow_h3_ext_dgram = false
        allow_masque = false

        [security]
        require_pq = true
        require_split2_for_adversarial = true
        allow_lab_tokens = false

        [storage]
        replay_cache = "sqlite"

        [x.aurora.apple]
        endpoint = "https://relay.example:9443"
        """)

        let configuration = await controller.configuration
        let state = await controller.state
        let packetState = await controller.packetExchangeState
        let credentialState = await controller.credentialState
        let tunnelState = await controller.tunnelState
        let lastStatus = await controller.lastStatus
        let lastPacketExchange = await controller.lastPacketExchange
        let diagnostic = await controller.redactedDiagnosticLine
        XCTAssertTrue(imported)
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(configuration.routePolicy, "adversarial-dpi")
        XCTAssertNil(lastStatus)
        XCTAssertNil(lastPacketExchange)
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(packetState, .idle)
        XCTAssertEqual(credentialState, .idle)
        XCTAssertEqual(tunnelState, .disconnected)
        XCTAssertTrue(diagnostic.contains("profile_import=ready"))
    }

    func testControllerPersistsImportedPortableProfileAsSanitizedSharedProfile() async throws {
        let store = MockPortableProfileStore()
        let controller = await AuroraClientController(
            configuration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            serverClient: MockServerClient(status: AuroraServerStatus(ready: true, issuer: true, cover: true)),
            profileStore: store
        )

        let imported = await controller.importPortableProfile("""
        [aurora]
        version = "2.0"
        profile = "adversarial-dpi"
        route = "split-2"
        speed = "balanced"

        [local]
        mode = "platform-vpn"
        dns = "through-aurora"

        [methods]
        allow_h2 = true
        allow_h1_ws = true
        allow_h3_ext_dgram = false
        allow_masque = false

        [security]
        require_pq = true
        require_split2_for_adversarial = true
        allow_lab_tokens = false

        [storage]
        replay_cache = "sqlite"

        [x.aurora.apple]
        endpoint = "https://relay.example:9443"
        admission_proof = "secret-proof"
        token_authenticator = "secret-token"
        hint_secret = "secret-hint"

        [x.aurora.lab]
        replay_nonce = "secret-replay"
        bridge_bundle = "secret-bridge"
        relay_descriptor = "secret-relay"
        """)

        let savedProfile = try XCTUnwrap(store.savedProfileText)
        let reparsed = try AuroraPortableProfile.parse(savedProfile)
        XCTAssertTrue(imported)
        XCTAssertEqual(reparsed.endpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(reparsed.profile, "adversarial-dpi")
        XCTAssertTrue(savedProfile.contains("[aurora]"))
        XCTAssertTrue(savedProfile.contains("[x.aurora.apple]"))
        XCTAssertFalse(savedProfile.contains("secret-proof"))
        XCTAssertFalse(savedProfile.contains("secret-token"))
        XCTAssertFalse(savedProfile.contains("secret-hint"))
        XCTAssertFalse(savedProfile.contains("secret-replay"))
        XCTAssertFalse(savedProfile.contains("secret-bridge"))
        XCTAssertFalse(savedProfile.contains("secret-relay"))
        XCTAssertFalse(savedProfile.contains("admission_proof"))
        XCTAssertFalse(savedProfile.contains("token_authenticator"))
        XCTAssertFalse(savedProfile.contains("hint_secret"))
    }

}
