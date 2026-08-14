# Native Trust Initialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make native packet-tunnel startup configure independently anchored trust in Core before any provisioning session begins.

**Architecture:** AuroraKit loads a bounded sealed trust resource from its own framework bundle and configures Core through the existing C ABI. The native session driver invokes that configurator before its first Core call, while internal protocols let tests prove ordering and fail-closed behavior without replacing packet-tunnel behavior.

**Tech Stack:** Swift 6, Swift Package Manager, Xcode, AuroraCore C ABI, POSIX shell.

**Spec:** `docs/superpowers/specs/2026-08-14-native-trust-initialization.md`

## Global Constraints

- Trust roots come only from `AuroraSignedSeedTrust.bin` packaged in the signed AuroraKit framework.
- The release trust resource is Git-ignored and must not contain operational material in this repository.
- Missing, malformed, empty, oversized, or Core-rejected trust data prevents Core session startup.
- All output allocated by Core is released through `AuroraCoreZeroFree`.
- The resource limit is 65,536 bytes.
- Do not add protocol encoding, cryptography, or carrier logic to Swift.
- Do not include a protocol specification version outside the specification repository.

---

### Task 1: Add ABI Trust Configuration Coverage

**Files:**
- Modify: `Sources/AuroraKit/AuroraCoreBridge.swift`
- Modify: `Tests/AuroraKitTests/AuroraKitTests.swift`

**Interfaces:**
- Produces: `AuroraCore.configureNativeProvisioningTrust(_ encoded: Data) -> Bool`.
- Produces: `AuroraCore.call` that uses `AuroraCoreZeroFree` for all successful allocations.

- [x] **Step 1: Write the failing direct-ABI test**

```swift
func testCoreAcceptsCanonicalNativeTrustConfiguration() throws {
    let trust = try XCTUnwrap(AuroraTestTrustConfiguration.canonicalData())
    XCTAssertTrue(AuroraCore.configureNativeProvisioningTrust(trust))
    XCTAssertTrue(AuroraCore.configureNativeProvisioningTrust(trust))
}
```

- [x] **Step 2: Run the direct-ABI test to verify it fails**

Run: `swift test --filter AuroraKitTests/testCoreAcceptsCanonicalNativeTrustConfiguration`

Expected: FAIL because `configureNativeProvisioningTrust` does not exist.

- [x] **Step 3: Add the minimal Core bridge operation**

```swift
private enum Op: Int32 {
    case configureNativeProvisioningTrust = 21
}

static func configureNativeProvisioningTrust(_ encoded: Data) -> Bool {
    guard !encoded.isEmpty, encoded.count <= 65_536 else { return false }
    return okPayload(call(.configureNativeProvisioningTrust, input: encoded)) != nil
}

defer { AuroraCoreZeroFree(ptr, outLen) }
```

- [x] **Step 4: Run the direct-ABI test to verify it passes**

Run: `swift test --filter AuroraKitTests/testCoreAcceptsCanonicalNativeTrustConfiguration`

Expected: PASS with two accepted calls for the same canonical root set.

- [x] **Step 5: Commit**

```sh
git add Sources/AuroraKit/AuroraCoreBridge.swift Tests/AuroraKitTests/AuroraKitTests.swift
git commit -m "fix: configure native trust through Core ABI"
```

### Task 2: Make the Native Session Driver Fail Closed

**Files:**
- Create: `Sources/AuroraKit/AuroraNativeTrustConfiguration.swift`
- Modify: `Sources/AuroraKit/AuroraNativePacketTunnelCore.swift`
- Modify: `Tests/AuroraKitTests/AuroraKitTests.swift`

**Interfaces:**
- Consumes: `AuroraCore.configureNativeProvisioningTrust(_:) ` from Task 1.
- Produces: `AuroraNativeTrustConfiguring.configure() throws`.
- Produces: `AuroraCoreNativeSessionDriver.init(trustConfigurator:binding:)` for internal tests.

- [x] **Step 1: Write the failing ordering and rejection tests**

```swift
func testCoreDriverConfiguresTrustBeforeBeginningSession() async throws {
    let events = NativeTrustDriverEvents()
    let driver = AuroraCoreNativeSessionDriver(
        trustConfigurator: RecordingTrustConfigurator(events: events),
        binding: RecordingNativeCoreBinding(events: events)
    )
    _ = try await driver.begin(provisioning: Data([0x01]))
    XCTAssertEqual(await events.values, ["configure", "begin"])
}

func testCoreDriverDoesNotBeginWhenTrustConfigurationFails() async {
    let binding = RecordingNativeCoreBinding(events: NativeTrustDriverEvents())
    let driver = AuroraCoreNativeSessionDriver(
        trustConfigurator: RejectingTrustConfigurator(),
        binding: binding
    )
    await XCTAssertThrowsErrorAsync(try await driver.begin(provisioning: Data([0x01])))
    XCTAssertEqual(await binding.beginCount, 0)
}
```

- [x] **Step 2: Run the ordering test to verify it fails**

Run: `swift test --filter AuroraKitTests/testCoreDriverConfiguresTrustBeforeBeginningSession`

Expected: FAIL because the initializer and trust configurator do not exist.

- [x] **Step 3: Add bounded resource loading and injected Core binding**

```swift
protocol AuroraNativeTrustConfiguring: Sendable {
    func configure() throws
}

struct AuroraBundleNativeTrustConfigurator: AuroraNativeTrustConfiguring {
    func configure() throws {
        var encoded = try loadBoundedTrustData()
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        guard AuroraCore.configureNativeProvisioningTrust(encoded) else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
    }
}
```

`AuroraCoreNativeSessionDriver.begin` calls `trustConfigurator.configure()` before `binding.begin(provisioning:)`. The default resource URL comes from the AuroraKit framework bundle. The binding delegates the existing static Core methods and performs no protocol work.

- [x] **Step 4: Run the focused trust and driver tests to verify they pass**

Run: `swift test --filter AuroraKitTests/testCoreDriver`

Expected: PASS; configuration failure records no begin operation.

- [x] **Step 5: Commit**

```sh
git add Sources/AuroraKit/AuroraNativeTrustConfiguration.swift Sources/AuroraKit/AuroraNativePacketTunnelCore.swift Tests/AuroraKitTests/AuroraKitTests.swift
git commit -m "fix: require sealed trust before native sessions"
```

### Task 3: Seal and Verify Release Resources

**Files:**
- Create: `scripts/prepare-native-trust-resource.sh`
- Create: `scripts/copy-native-trust-resource.sh`
- Create: `scripts/verify-app-bundles-test.sh`
- Create: `Sources/AuroraKit/Resources/.gitkeep`
- Modify: `.gitignore`
- Modify: `Package.swift`
- Modify: `project.yml`
- Modify: `AuroraApple.xcodeproj/project.pbxproj`
- Modify: `scripts/verify-app-bundles.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `AURORA_SIGNED_SEED_TRUST_PATH` and `AURORA_CORE_DIR`.
- Produces: ignored `Sources/AuroraKit/Resources/AuroraSignedSeedTrust.bin` after Core validation.
- Produces: `AURORA_REQUIRE_SIGNED_SEED_TRUST=1` bundle verification mode.

- [x] **Step 1: Write the failing release-resource checks**

```sh
AURORA_REQUIRE_SIGNED_SEED_TRUST=1 \
DERIVED_DATA_PATH="$PWD/DerivedData" \
sh scripts/verify-app-bundles.sh
```

Expected: FAIL with a missing sealed trust resource for each application framework bundle.

- [x] **Step 2: Add a validating preparation script and bundle checks**

```sh
test -n "${AURORA_SIGNED_SEED_TRUST_PATH:-}"
test -f "$AURORA_SIGNED_SEED_TRUST_PATH"
( cd "$AURORA_CORE_DIR" && go run ./cmd/auroractl check-native-provisioning-trust "$AURORA_SIGNED_SEED_TRUST_PATH" )
install -m 600 "$AURORA_SIGNED_SEED_TRUST_PATH" "$RESOURCE_PATH"
```

When `AURORA_REQUIRE_SIGNED_SEED_TRUST=1`, the bundle verifier finds `AuroraSignedSeedTrust.bin` inside both built AuroraKit framework resource locations and rejects zero-byte files.

- [x] **Step 3: Prepare a canonical non-operational test root and run release-resource checks**

Run: `AURORA_SIGNED_SEED_TRUST_PATH=/private/tmp/aurora-test-trust.bin scripts/prepare-native-trust-resource.sh`

Run: `AURORA_REQUIRE_SIGNED_SEED_TRUST=1 DERIVED_DATA_PATH="$PWD/DerivedData" sh scripts/verify-app-bundles.sh`

Expected: PASS after the resource exists in both rebuilt framework bundles.

- [x] **Step 4: Document the release-only injection interface**

```markdown
The release build injects a validated trust resource before compilation.
The resource is not a user import and is not committed to source control.
```

- [x] **Step 5: Commit**

```sh
git add .gitignore README.md scripts/prepare-native-trust-resource.sh scripts/verify-app-bundles.sh Sources/AuroraKit/Resources/.gitkeep
git commit -m "build: verify sealed native trust resources"
```

### Task 4: Run the Apple Readiness Gate and Review

**Files:**
- Verify: `scripts/aurora-apple-check.sh`
- Verify: `scripts/verify-app-bundles.sh`

**Interfaces:**
- Consumes: Tasks 1 through 3.
- Produces: a reviewed branch ready for a draft pull request.

- [ ] **Step 1: Run formatting and diff checks**

Run: `git diff --check`

Expected: PASS with no whitespace errors.

- [ ] **Step 2: Run all local readiness checks**

Run: `DERIVED_DATA_PATH="$PWD/DerivedData" scripts/aurora-apple-check.sh`

Expected: PASS for the portable Core build, all Swift tests, iOS/macOS apps, and packet-tunnel targets.

- [ ] **Step 3: Run sealed-resource bundle verification**

Run: `AURORA_REQUIRE_SIGNED_SEED_TRUST=1 DERIVED_DATA_PATH="$PWD/DerivedData" sh scripts/verify-app-bundles.sh`

Expected: PASS after the canonical non-operational test resource is prepared and builds are refreshed.

- [ ] **Step 4: Review the complete diff**

Run: `git diff origin/main...HEAD`

Expected: only the Core configuration bridge, trust loader, driver injection, release resource scripts, tests, and documentation described above.

- [ ] **Step 5: Commit any verification-only tracked adjustments and open a draft pull request**

```sh
git status --short
gh pr create --draft --base main --head fix/apple-native-trust-init --title "Require sealed trust before native sessions"
```
