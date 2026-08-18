import Foundation
import XCTest
@testable import AuroraKit

final class AuroraProjectStructureTests: XCTestCase {
    func testProjectBuildsSharedPacketTunnelTargets() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let workflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        let readinessScript = try String(
            contentsOf: root.appendingPathComponent("scripts/aurora-apple-check.sh"),
            encoding: .utf8
        )

        for target in ["AuroraPacketTunnel_iOS", "AuroraPacketTunnel_macOS"] {
            XCTAssertTrue(project.contains("\(target):"), "project.yml missing \(target)")
            XCTAssertTrue(readinessScript.contains("-scheme \(target)"), "Apple readiness script does not build \(target)")
        }
        XCTAssertTrue(workflow.contains("scripts/aurora-apple-check.sh"), "CI workflow does not run the Apple readiness script")
        XCTAssertTrue(project.contains("type: app-extension"))
        XCTAssertTrue(project.contains("com.apple.networkextension.packet-tunnel"))
        XCTAssertTrue(project.contains("SharedNetworkExtension"))
        XCTAssertTrue(project.contains("- target: AuroraPacketTunnel_iOS\n        embed: true"))
        XCTAssertTrue(project.contains("- target: AuroraPacketTunnel_macOS\n        embed: true"))
    }

    func testAppleReadinessScriptCoversPackageAndPlatformBuilds() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = root.appendingPathComponent("scripts/aurora-apple-check.sh")
        let coreBuildScript = try String(
            contentsOf: root.appendingPathComponent("scripts/build-auroracore-xcframework.sh"),
            encoding: .utf8
        )
        let workflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let script: String

        if FileManager.default.fileExists(atPath: scriptURL.path) {
            script = try String(contentsOf: scriptURL, encoding: .utf8)
            let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertNotEqual(permissions & 0o111, 0, "Apple readiness script should be executable")
        } else {
            XCTFail("Apple readiness script missing")
            script = ""
        }

        XCTAssertTrue(workflow.contains("scripts/aurora-apple-check.sh"), "CI should call the shared Apple readiness script")
        let workflowSecurityPolicy = try workflowSecurityPolicy(at: root.appendingPathComponent(".github/workflows/ci.yml"))
        XCTAssertEqual(workflowSecurityPolicy.contentsPermission, "read", "CI should grant only repository read access")
        XCTAssertEqual(workflowSecurityPolicy.checkoutDisablesCredentialPersistence, [true, true], "CI checkouts should not persist credentials")
        let approvedActionReferences = [
            "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09",
            "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09",
            "actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e",
        ]
        XCTAssertEqual(
            workflowSecurityPolicy.actionReferences.sorted(),
            approvedActionReferences.sorted(),
            "CI should use only approved immutable action pins"
        )
        XCTAssertTrue(workflow.contains("go-version-file: aurora-core/go.mod"), "CI should use the checked-out core Go version")
        XCTAssertTrue(workflow.contains("cache-dependency-path: aurora-core/go.sum"), "CI should cache the checked-out core dependencies")
        let coreRevision = "c2d9ac7758058c002aaac1e804ac677382c2c520"
        XCTAssertTrue(
            workflow.contains("ref: \(coreRevision)"),
            "CI should pin the reviewed Core ABI revision"
        )
        XCTAssertTrue(
            coreBuildScript.contains("EXPECTED_CORE_REVISION=\"\(coreRevision)\""),
            "local builds should use the same reviewed Core ABI revision as CI"
        )
        XCTAssertTrue(readme.contains("scripts/aurora-apple-check.sh"), "README should document the shared Apple readiness script")
        XCTAssertTrue(script.contains("swift test"), "Apple readiness script should run Swift package tests")
        XCTAssertTrue(script.contains("CODE_SIGNING_ALLOWED=NO"), "Apple readiness script should use unsigned local builds")

        for scheme in ["AuroraMac", "AuroraIOS", "AuroraPacketTunnel_macOS", "AuroraPacketTunnel_iOS"] {
            XCTAssertTrue(script.contains("-scheme \(scheme)"), "Apple readiness script should build \(scheme)")
        }
    }

    func testCoreBridgeScrubsNativeResponsesBeforeRelease() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bridge = try String(
            contentsOf: root.appendingPathComponent("Sources/AuroraKit/AuroraCoreBridge.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            bridge.contains("AuroraCoreZeroFree(ptr, outLen)"),
            "Core bridge should scrub native response buffers before releasing them"
        )
        XCTAssertTrue(
            bridge.contains("input.count <= maximumCallInputBytes"),
            "Core bridge should bound Data before converting its length for the C ABI"
        )
        XCTAssertTrue(
            bridge.contains("Int(outLen) <= maximumCallOutputBytes"),
            "Core bridge should bound native output before copying it into Swift memory"
        )
    }

    func testProjectDeclaresPacketTunnelEntitlements() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let entitlementPaths = [
            "Apps/iOS/AuroraIOS.entitlements",
            "Apps/macOS/AuroraMac.entitlements",
            "SharedNetworkExtension/AuroraPacketTunnel-iOS.entitlements",
            "SharedNetworkExtension/AuroraPacketTunnel-macOS.entitlements",
        ]

        for path in entitlementPaths {
            let entitlement = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(entitlement.contains("com.apple.developer.networking.networkextension"), "\(path) missing Network Extension entitlement")
            XCTAssertTrue(entitlement.contains("packet-tunnel-provider"), "\(path) missing packet tunnel entitlement value")
        }
    }

    func testProjectDeclaresSharedAppGroupAndKeychainAccessGroups() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let entitlementPaths = [
            "Apps/iOS/AuroraIOS.entitlements",
            "Apps/macOS/AuroraMac.entitlements",
            "SharedNetworkExtension/AuroraPacketTunnel-iOS.entitlements",
            "SharedNetworkExtension/AuroraPacketTunnel-macOS.entitlements",
        ]
        let infoPaths = [
            "Apps/iOS/Info.plist",
            "Apps/macOS/Info.plist",
            "SharedNetworkExtension/Info-iOS.plist",
            "SharedNetworkExtension/Info-macOS.plist",
        ]

        for path in entitlementPaths {
            let entitlement = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(entitlement.contains("com.apple.security.application-groups"), "\(path) missing App Group entitlement")
            XCTAssertTrue(entitlement.contains("group.org.aurora-protocol.aurora.shared"), "\(path) missing shared App Group")
            XCTAssertTrue(entitlement.contains("keychain-access-groups"), "\(path) missing shared keychain access groups")
            XCTAssertTrue(entitlement.contains("$(AppIdentifierPrefix)org.aurora-protocol.aurora.shared"), "\(path) missing shared keychain group")
        }

        for path in infoPaths {
            let info = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(info.contains("AuroraAppGroupIdentifier"), "\(path) missing App Group runtime key")
            XCTAssertTrue(info.contains("group.org.aurora-protocol.aurora.shared"), "\(path) missing App Group runtime value")
            XCTAssertTrue(info.contains("AuroraKeychainAccessGroup"), "\(path) missing keychain runtime key")
            XCTAssertTrue(info.contains("$(AppIdentifierPrefix)org.aurora-protocol.aurora.shared"), "\(path) missing keychain runtime value")
        }
    }

    func testProjectGeneratorPreservesSharedStorageDeclarations() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)

        XCTAssertTrue(project.contains("com.apple.security.application-groups"), "project.yml missing App Group entitlement generation")
        XCTAssertTrue(project.contains("group.org.aurora-protocol.aurora.shared"), "project.yml missing shared App Group generation")
        XCTAssertTrue(project.contains("keychain-access-groups"), "project.yml missing keychain access group generation")
        XCTAssertTrue(
            project.contains("$(AppIdentifierPrefix)org.aurora-protocol.aurora.shared"),
            "project.yml missing shared keychain access group generation"
        )
        XCTAssertTrue(project.contains("AuroraAppGroupIdentifier"), "project.yml missing App Group Info.plist generation")
        XCTAssertTrue(project.contains("AuroraKeychainAccessGroup"), "project.yml missing keychain Info.plist generation")
    }

    func testSharedUIExposesPortableProfileImportExport() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/AuroraUI/AuroraStatusView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(view.contains("TextEditor"), "status view missing portable profile editor")
        XCTAssertTrue(view.contains("Import Profile"), "status view missing import action")
        XCTAssertTrue(view.contains("Export Profile"), "status view missing export action")
        XCTAssertTrue(view.contains("importPortableProfile"), "status view does not call controller profile import")
        XCTAssertTrue(view.contains("exportPortableProfile"), "status view does not call controller profile export")
        XCTAssertTrue(view.contains("loadStoredPortableProfile"), "status view does not load stored portable profiles")
    }

    func testSharedUIExposesBoundedNativeProvisioningEnrollment() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/AuroraUI/AuroraStatusView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(view.contains("fileImporter"), "status view missing provisioning file importer")
        XCTAssertTrue(view.contains("Import Provisioning"), "status view missing provisioning import action")
        XCTAssertTrue(view.contains("Remove Provisioning"), "status view missing provisioning removal action")
        XCTAssertTrue(view.contains("importNativeProvisioning"), "status view does not import provisioning through the controller")
        XCTAssertTrue(view.contains("restoreNativeProvisioning"), "status view does not restore provisioning on launch")
        XCTAssertTrue(view.contains("removeNativeProvisioning"), "status view does not remove provisioning through the controller")
        XCTAssertTrue(view.contains("maximumBytes"), "status view must bound provisioning file input before loading it")
        XCTAssertTrue(view.contains("FileHandle(forReadingFrom:"), "status view must open provisioning files through a bounded handle")
        XCTAssertTrue(
            view.contains("read(upToCount: AuroraNativeProvisioningStore.maximumBytes + 1)"),
            "status view must read only one byte beyond the provisioning limit"
        )
        XCTAssertFalse(view.contains("Data(contentsOf: url"), "status view must not map an unbounded provisioning file")
    }

    func testSharedUIExposesRedactedDiagnostics() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/AuroraUI/AuroraStatusView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(view.contains("Diagnostics"), "status view missing diagnostics section")
        XCTAssertTrue(view.contains("redactedDiagnosticLine"), "status view does not read controller redacted diagnostics")
        XCTAssertTrue(view.contains("monospaced"), "status view should render diagnostics as copy-stable text")
    }

    func testPacketTunnelProviderUsesSharedProfileStoreFallback() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let provider = try String(
            contentsOf: root.appendingPathComponent("SharedNetworkExtension/PacketTunnelProvider.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(provider.contains("AuroraTunnelConfigurationResolver"), "packet tunnel provider missing shared resolver")
        XCTAssertTrue(provider.contains("endpointResolver.resolve"), "packet tunnel provider does not resolve relay endpoints before installing routes")
        XCTAssertTrue(provider.contains("AuroraUserDefaultsProfileStore"), "packet tunnel provider missing App Group profile store")
        XCTAssertTrue(provider.contains("AuroraAppleSharedContainer.appGroupIdentifier()"), "packet tunnel provider missing App Group scope")
    }

    func testPacketTunnelProviderConnectsCoreBeforeInstallingNetworkSettings() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let provider = try String(
            contentsOf: root.appendingPathComponent("SharedNetworkExtension/PacketTunnelProvider.swift"),
            encoding: .utf8
        )

        let startRange = try XCTUnwrap(provider.range(of: "try await runtime.start()"))
        let resolutionRange = try XCTUnwrap(provider.range(of: "try await endpointResolver.resolve"))
        let settingsRange = try XCTUnwrap(provider.range(of: "try await applyTunnelNetworkSettings"))
        XCTAssertLessThan(
            resolutionRange.lowerBound,
            startRange.lowerBound,
            "packet tunnel provider should resolve relay addresses before starting the tunnel"
        )
        XCTAssertLessThan(
            startRange.lowerBound,
            settingsRange.lowerBound,
            "packet tunnel provider should connect the core before installing route and DNS settings"
        )
    }

    func testPacketTunnelProviderCancelsEstablishedTunnelOnRuntimeFailure() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let provider = try String(
            contentsOf: root.appendingPathComponent("SharedNetworkExtension/PacketTunnelProvider.swift"),
            encoding: .utf8
        )

        let completionRange = try XCTUnwrap(provider.range(of: "completion(nil)"))
        let runRange = try XCTUnwrap(provider.range(of: "await runtime.runUntilStopped()"))
        let stopRange = try XCTUnwrap(provider.range(of: "lifecycle.requestStop {"))
        let cancellationRange = try XCTUnwrap(provider.range(of: "runtimeTask?.cancel()"))
        let runtimeStopRange = try XCTUnwrap(provider.range(of: "await runtime?.stop()"))
        let setupWaitRange = try XCTUnwrap(provider.range(of: "await startupGate.waitForQuiescence()"))
        XCTAssertTrue(
            provider.contains("cancelTunnelWithError(failure)"),
            "provider should cancel an established tunnel when the runtime fails"
        )
        XCTAssertTrue(
            provider.contains("lifecycle.completeStartup(generation, delivering:"),
            "provider should atomically reject startup success after a stop request"
        )
        XCTAssertTrue(
            provider.contains("lifecycle.beginPathObservation(generation, activating:"),
            "a canceled startup should not start the path observer"
        )
        XCTAssertTrue(
            provider.contains("startupGate.begin(generation)"),
            "provider should track setup before starting asynchronous work"
        )
        XCTAssertFalse(
            provider.contains("await runtime.activatePacketFlow()"),
            "provider should not start the packet pump before startup completion"
        )
        XCTAssertGreaterThan(
            runRange.lowerBound,
            completionRange.lowerBound,
            "provider should enter the runtime pump only after the tunnel has become active"
        )
        XCTAssertGreaterThan(
            cancellationRange.lowerBound,
            stopRange.lowerBound,
            "provider should latch stop intent before cancelling its runtime task"
        )
        XCTAssertGreaterThan(
            setupWaitRange.lowerBound,
            runtimeStopRange.lowerBound,
            "provider should await setup quiescence before completing stop"
        )
    }

    func testPacketTunnelProviderRecoversNativeCarrierAfterNetworkPathChanges() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let provider = try String(
            contentsOf: root.appendingPathComponent("SharedNetworkExtension/PacketTunnelProvider.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            provider.contains("AuroraNetworkPathTransitionTracker"),
            "packet tunnel provider must distinguish initial, duplicate, unavailable, and changed paths"
        )
        XCTAssertTrue(
            provider.contains("AuroraAsyncSerialQueue"),
            "packet tunnel provider must serialize network-path recovery work"
        )
        XCTAssertTrue(
            provider.contains("runtime.suspendForNetworkPathChange()"),
            "packet tunnel provider must stop native carrier traffic before path recovery"
        )
        XCTAssertTrue(
            provider.contains("runtime.reconnectAfterNetworkPathChange()"),
            "packet tunnel provider must establish a fresh native carrier after a path change"
        )
        XCTAssertTrue(
            provider.contains("reasserting = true"),
            "packet tunnel provider must prevent packet forwarding while native recovery is in progress"
        )
        XCTAssertTrue(
            provider.contains("AuroraNetworkPathChange(interface: \"sleep\", expensive: false, constrained: false, available: false)"),
            "packet tunnel provider must suspend native carrier traffic before device sleep"
        )
        XCTAssertTrue(
            provider.contains("await enqueuePathChange(change)"),
            "packet tunnel provider must route path, sleep, and wake events through serialized recovery"
        )
    }

    func testPacketTunnelProviderInstallsIPv6Routes() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let provider = try String(
            contentsOf: root.appendingPathComponent("SharedNetworkExtension/PacketTunnelProvider.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(provider.contains("NEIPv6Settings"), "packet tunnel provider missing IPv6 settings")
        XCTAssertTrue(provider.contains("NEIPv6Route.default()"), "packet tunnel provider missing IPv6 default route")
        XCTAssertTrue(
            provider.contains("configuration.excludedIPv6Routes"),
            "packet tunnel provider missing IPv6 relay exclusions"
        )
    }

    func testAppsConstructControllersWithSharedAppGroupProfileStore() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appPaths = [
            "Apps/iOS/AuroraIOSApp.swift",
            "Apps/macOS/AuroraMacApp.swift",
        ]

        for path in appPaths {
            let app = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(app.contains("profileStore:"), "\(path) missing profile store injection")
            XCTAssertTrue(app.contains("AuroraUserDefaultsProfileStore"), "\(path) missing shared profile store")
            XCTAssertTrue(app.contains("AuroraAppleSharedContainer.appGroupIdentifier()"), "\(path) missing App Group profile store scope")
        }
    }

    func testIOSAppDeclaresCompleteOrientationSet() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let info = try String(contentsOf: root.appendingPathComponent("Apps/iOS/Info.plist"), encoding: .utf8)

        for orientation in [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ] {
            XCTAssertTrue(project.contains(orientation), "project.yml missing \(orientation)")
            XCTAssertTrue(info.contains(orientation), "iOS Info.plist missing \(orientation)")
        }
    }
}
