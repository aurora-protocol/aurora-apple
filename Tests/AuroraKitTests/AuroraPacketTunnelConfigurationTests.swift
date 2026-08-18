import Foundation
import XCTest
@testable import AuroraKit

final class AuroraPacketTunnelConfigurationTests: XCTestCase {
    func testPacketTunnelConfigurationBuildsNetworkExtensionFloor() throws {
        let endpoint = URL(string: "https://relay.example:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))

        XCTAssertEqual(tunnel.tunnelRemoteAddress, "relay.example")
        XCTAssertEqual(tunnel.ipv4Address, "10.77.0.2")
        XCTAssertEqual(tunnel.ipv4SubnetMask, "255.255.255.255")
        XCTAssertEqual(tunnel.ipv6Address, "fd77::2")
        XCTAssertEqual(tunnel.ipv6NetworkPrefixLength, 128)
        XCTAssertEqual(tunnel.mtu, 1280)
        XCTAssertEqual(tunnel.dnsServers, ["100.64.0.1", "fd77::1"])
        XCTAssertTrue(tunnel.includeDefaultIPv4Route)
        XCTAssertTrue(tunnel.includeDefaultIPv6Route)
        XCTAssertTrue(tunnel.captureAllDNSDomains)
    }

    func testPacketTunnelConfigurationFallsBackToEndpointStringWhenHostIsMissing() throws {
        let endpoint = URL(string: "http://127.0.0.1:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(
            configuration: AuroraConfiguration(endpoint: endpoint),
            tunnelRemoteAddress: ""
        )

        XCTAssertEqual(tunnel.tunnelRemoteAddress, "127.0.0.1")
    }

    func testPacketTunnelConfigurationExcludesIPv4RelayFromDefaultRoute() throws {
        let endpoint = URL(string: "https://203.0.113.7:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))

        XCTAssertEqual(tunnel.excludedIPv4Routes, [
            AuroraIPv4Route(destinationAddress: "203.0.113.7", subnetMask: "255.255.255.255"),
        ])
    }

    func testPacketTunnelConfigurationExcludesIPv6RelayFromDefaultRoute() throws {
        let endpoint = URL(string: "https://[2001:db8:100::7]:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))

        XCTAssertEqual(tunnel.tunnelRemoteAddress, "2001:db8:100::7")
        XCTAssertEqual(tunnel.excludedIPv6Routes, [
            AuroraIPv6Route(destinationAddress: "2001:db8:100::7", networkPrefixLength: 128),
        ])
    }

    func testPacketTunnelConfigurationAppliesResolvedRelayAddressesBeforeActivation() throws {
        let endpoint = URL(string: "https://relay.example:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))

        let resolved = try tunnel.applyingResolvedRemoteAddresses([
            "2001:db8:100::7",
            "203.0.113.7",
            "203.0.113.7",
        ])

        XCTAssertEqual(resolved.tunnelRemoteAddress, "2001:db8:100::7")
        XCTAssertEqual(resolved.excludedIPv4Routes, [
            AuroraIPv4Route(destinationAddress: "203.0.113.7", subnetMask: "255.255.255.255"),
        ])
        XCTAssertEqual(resolved.excludedIPv6Routes, [
            AuroraIPv6Route(destinationAddress: "2001:db8:100::7", networkPrefixLength: 128),
        ])
        XCTAssertNoThrow(try resolved.validatedForNetworkSettings())
    }

    func testPacketTunnelConfigurationRejectsUnresolvedAndInvalidIPv6Settings() throws {
        let endpoint = URL(string: "https://relay.example:9443")!
        let tunnel = AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))
        XCTAssertThrowsError(try tunnel.validatedForNetworkSettings())

        var invalid = try tunnel.applyingResolvedRemoteAddresses(["203.0.113.7"])
        invalid.ipv6NetworkPrefixLength = 129
        XCTAssertThrowsError(try invalid.validatedForNetworkSettings())
    }

    func testTunnelEndpointResolverReturnsNumericLoopbackAddress() async throws {
        let endpoint = URL(string: "https://localhost:9443")!
        let resolver = AuroraTunnelEndpointResolver()
        let resolved = try await resolver.resolve(
            AuroraPacketTunnelConfiguration(configuration: AuroraConfiguration(endpoint: endpoint))
        )

        XCTAssertNotEqual(resolved.tunnelRemoteAddress, "localhost")
        XCTAssertNoThrow(try resolved.validatedForNetworkSettings())
        XCTAssertFalse(resolved.excludedIPv4Routes.isEmpty && resolved.excludedIPv6Routes.isEmpty)
    }

    func testTunnelEndpointResolverCancelsWhileLookupIsBlocked() async throws {
        let lookupStarted = expectation(description: "hostname lookup started")
        let releaseLookup = DispatchSemaphore(value: 0)
        defer { releaseLookup.signal() }
        let resolver = AuroraTunnelEndpointResolver(lookup: { _ in
            lookupStarted.fulfill()
            _ = releaseLookup.wait(timeout: .now() + 1)
            return ["203.0.113.7"]
        })
        let configuration = AuroraPacketTunnelConfiguration(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!)
        )
        let resolution = Task {
            do {
                _ = try await resolver.resolve(configuration)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        await fulfillment(of: [lookupStarted], timeout: 1)
        resolution.cancel()

        let wasCancelled = await resolution.value
        XCTAssertTrue(wasCancelled)
    }

    func testTunnelEndpointResolverTimesOutWhileLookupIsBlocked() async throws {
        let lookupStarted = expectation(description: "hostname lookup started")
        let releaseLookup = DispatchSemaphore(value: 0)
        defer { releaseLookup.signal() }
        let resolver = AuroraTunnelEndpointResolver(
            resolutionTimeoutNanoseconds: 50_000_000,
            lookup: { _ in
                lookupStarted.fulfill()
                _ = releaseLookup.wait(timeout: .now() + 1)
                return ["203.0.113.7"]
            }
        )
        let configuration = AuroraPacketTunnelConfiguration(
            configuration: AuroraConfiguration(endpoint: URL(string: "https://relay.example:9443")!)
        )

        let resolution = Task {
            do {
                _ = try await resolver.resolve(configuration)
                return false
            } catch let error as AuroraPacketTunnelConfigurationError {
                return error == .endpointResolutionTimedOut
            } catch {
                return false
            }
        }
        await fulfillment(of: [lookupStarted], timeout: 1)

        let timedOut = await resolution.value
        XCTAssertTrue(timedOut)
    }

    func testTunnelProfileBuildsProviderConfigurationPayload() throws {
        let endpoint = URL(string: "https://relay.example:9443")!
        let profile = AuroraTunnelProfile(
            configuration: AuroraConfiguration(endpoint: endpoint, routePolicy: "adversarial-dpi"),
            providerBundleIdentifier: "org.aurora-protocol.aurora.ios.packet-tunnel"
        )

        XCTAssertEqual(profile.localizedDescription, "Aurora")
        XCTAssertEqual(profile.providerBundleIdentifier, "org.aurora-protocol.aurora.ios.packet-tunnel")
        XCTAssertEqual(profile.serverAddress, "https://relay.example:9443")
        XCTAssertEqual(profile.providerConfiguration["endpoint"], "https://relay.example:9443")
        XCTAssertEqual(profile.providerConfiguration["routePolicy"], "adversarial-dpi")
    }

    func testTunnelProfileParsesProviderConfigurationPayload() throws {
        let configuration = try XCTUnwrap(AuroraTunnelProfile.configuration(from: [
            "endpoint": "https://relay.example:9443",
            "routePolicy": "balanced",
        ]))

        XCTAssertEqual(configuration.endpoint.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(configuration.routePolicy, "balanced")
    }

    func testTunnelProfileCarriesOnlyNativeProvisioningKeychainReference() throws {
        let identifier = "production-slot"
        let profile = AuroraTunnelProfile(
            configuration: AuroraConfiguration(
                endpoint: URL(string: "https://relay.example:9443")!,
                nativeProvisioningIdentifier: identifier
            ),
            providerBundleIdentifier: "org.aurora-protocol.aurora.ios.packet-tunnel"
        )

        XCTAssertEqual(profile.providerConfiguration[AuroraTunnelProfile.nativeProvisioningIdentifierKey], identifier)
        XCTAssertFalse(profile.providerConfiguration.values.contains { $0.contains("access_hint") })
        let configuration = try XCTUnwrap(AuroraTunnelProfile.configuration(from: profile.providerConfiguration))
        XCTAssertEqual(configuration.nativeProvisioningIdentifier, identifier)
    }

    func testTunnelProfileRejectsInvalidProviderConfigurationEndpoint() throws {
        XCTAssertNil(AuroraTunnelProfile.configuration(from: [
            "endpoint": "not a server",
            "routePolicy": "balanced",
        ]))
    }

    func testTunnelConfigurationResolverPrefersProviderConfiguration() throws {
        let store = MockPortableProfileStore(initialProfileText: """
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
        endpoint = "https://stored.example:9443"
        """)
        let resolver = AuroraTunnelConfigurationResolver(
            fallbackConfiguration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            profileStore: store
        )

        let configuration = resolver.configuration(providerConfiguration: [
            AuroraTunnelProfile.endpointKey: "https://provider.example:9443",
            AuroraTunnelProfile.routePolicyKey: "balanced",
        ])

        XCTAssertEqual(configuration.endpoint.absoluteString, "https://provider.example:9443")
        XCTAssertEqual(configuration.routePolicy, "balanced")
    }

    func testTunnelConfigurationResolverLoadsStoredPortableProfileAndMigratesSanitizedProfile() throws {
        let store = MockPortableProfileStore(initialProfileText: """
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
        endpoint = "https://stored.example:9443"
        admission_proof = "secret-proof"
        token_authenticator = "secret-token"
        hint_secret = "secret-hint"
        """)
        let resolver = AuroraTunnelConfigurationResolver(
            fallbackConfiguration: AuroraConfiguration(endpoint: URL(string: "http://127.0.0.1:9443")!),
            profileStore: store
        )

        let configuration = resolver.configuration(providerConfiguration: nil)
        let migratedProfile = try XCTUnwrap(store.savedProfileText)

        XCTAssertEqual(configuration.endpoint.absoluteString, "https://stored.example:9443")
        XCTAssertEqual(configuration.routePolicy, "adversarial-dpi")
        XCTAssertFalse(migratedProfile.contains("secret-proof"))
        XCTAssertFalse(migratedProfile.contains("secret-token"))
        XCTAssertFalse(migratedProfile.contains("secret-hint"))
        XCTAssertFalse(migratedProfile.contains("admission_proof"))
        XCTAssertFalse(migratedProfile.contains("token_authenticator"))
        XCTAssertFalse(migratedProfile.contains("hint_secret"))
    }

    func testPortableProfileParsesConfigFloorAndAppleEndpointExtension() throws {
        let profile = try AuroraPortableProfile.parse("""
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

        XCTAssertEqual(profile.version, "2.0")
        XCTAssertEqual(profile.profile, "adversarial-dpi")
        XCTAssertEqual(profile.route, "split-2")
        XCTAssertEqual(profile.localMode, "platform-vpn")
        XCTAssertEqual(profile.endpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(profile.configuration(defaultEndpoint: URL(string: "https://fallback.example")!).routePolicy, "adversarial-dpi")
    }

    func testPortableProfileRejectsInputLargerThan64KiB() {
        let profile = String(repeating: "#\n", count: (64 * 1024 / 2) + 1)

        XCTAssertThrowsError(try AuroraPortableProfile.parse(profile)) { error in
            XCTAssertEqual(error as? AuroraPortableProfileError, .inputTooLarge)
        }
    }

    func testPortableProfileAcceptsInputAt64KiB() throws {
        let profile = String(repeating: "#\n", count: 64 * 1024 / 2)

        XCTAssertEqual(try AuroraPortableProfile.parse(profile), AuroraPortableProfile())
    }

    func testPortableProfileExportRoundTripsAppleEndpointWithoutSecrets() throws {
        let profile = AuroraPortableProfile(
            configuration: AuroraConfiguration(
                endpoint: URL(string: "https://relay.example:9443")!,
                routePolicy: "adversarial-dpi"
            ),
            route: "split-2",
            localMode: "platform-vpn"
        )

        let exported = profile.tomlString()
        let reparsed = try AuroraPortableProfile.parse(exported)

        XCTAssertTrue(exported.contains("[aurora]"))
        XCTAssertTrue(exported.contains("[x.aurora.apple]"))
        XCTAssertFalse(exported.contains("admission_proof"))
        XCTAssertFalse(exported.contains("token_authenticator"))
        XCTAssertFalse(exported.contains("hint_secret"))
        XCTAssertEqual(reparsed.endpoint?.absoluteString, "https://relay.example:9443")
        XCTAssertEqual(reparsed.profile, "adversarial-dpi")
        XCTAssertEqual(reparsed.route, "split-2")
        XCTAssertEqual(reparsed.localMode, "platform-vpn")
    }

    func testUserDefaultsProfileStoreSanitizesBeforeSaving() throws {
        let suiteName = "org.aurora-protocol.aurora.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AuroraUserDefaultsProfileStore(
            appGroupIdentifier: suiteName,
            defaults: defaults
        )

        try store.savePortableProfile("""
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
        """)

        let saved = try XCTUnwrap(try store.loadPortableProfile())
        XCTAssertTrue(saved.contains("[x.aurora.apple]"))
        XCTAssertFalse(saved.contains("secret-proof"))
        XCTAssertFalse(saved.contains("secret-token"))
        XCTAssertFalse(saved.contains("secret-hint"))
        XCTAssertFalse(saved.contains("admission_proof"))
        XCTAssertFalse(saved.contains("token_authenticator"))
        XCTAssertFalse(saved.contains("hint_secret"))
    }

    func testPortableProfileRejectsUnknownSecurityKeys() {
        XCTAssertThrowsError(try AuroraPortableProfile.parse("""
        [security]
        allow_plaintext_tokens = "yes"

        [x.aurora.apple]
        endpoint = "https://relay.example:9443"
        """)) { error in
            XCTAssertEqual(error as? AuroraPortableProfileError, .unknownKey(section: "security", key: "allow_plaintext_tokens"))
        }
    }

    func testPortableProfileRequiresLabProfileForLabTokens() throws {
        XCTAssertThrowsError(try AuroraPortableProfile.parse("""
        [aurora]
        profile = "adversarial-dpi"

        [security]
        allow_lab_tokens = true
        """)) { error in
            XCTAssertEqual(
                error as? AuroraPortableProfileError,
                .invalidValue(section: "security", key: "allow_lab_tokens", value: "true")
            )
        }

        let profile = try AuroraPortableProfile.parse("""
        [aurora]
        profile = "lab"

        [security]
        allow_lab_tokens = true
        """)
        XCTAssertTrue(profile.allowLabTokens)
    }

}
