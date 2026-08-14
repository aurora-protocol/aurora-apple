# Native Trust Initialization

## Problem

The portable Core refuses native provisioning until it has an independently
anchored signed-seed trust configuration. Its C ABI already exposes that
configuration operation. The Apple adapter did not call it, so the default
native packet-tunnel driver fails before issuer work is created.

Existing high-level tests did not expose this because they replace the native
session driver with a mock. A direct Core regression test confirms that a
native session cannot begin without trust initialization.

## Required Behavior

- The Apple adapter configures Core trust before every attempt to begin a
  native session. Core accepts repeated configuration only when the canonical
  configuration is unchanged.
- The trust configuration is loaded only from an immutable resource in the
  signed AuroraKit framework. It is not derived from user provisioning,
  portable profiles, application preferences, or remote responses.
- Missing, malformed, empty, or oversized resource data fails closed and no
  Core session operation runs after the failure.
- The resource is injected by release packaging after Core validates it. It is
  ignored by Git and never contains operational material in this repository.
- The bridge frees every Core output buffer through the zero-and-free ABI,
  including configuration results.
- Release bundle verification fails when the sealed resource is absent from
  either Apple application framework bundle.
- CI pins a Core revision that exports the trust configuration operation and
  zero-and-free function used by AuroraKit.
- Distribution verification consumes explicit iOS and macOS application paths,
  checks the exact framework resource location, validates both files through
  Core, and verifies signed release artifacts.

## Design

`AuroraCore` gains a narrow internal `configureNativeProvisioningTrust` method
for the existing Core operation. A new trust configurator loads the resource
with an explicit maximum size, hands the bytes to that method, then clears the
temporary data.

`AuroraCoreNativeSessionDriver` receives a trust configurator and a Core
binding behind internal protocols. Its public initializer retains production
defaults. Tests inject a recorder configurator and binding to prove ordering
and fail-closed behavior without mocking the packet tunnel itself.

The default configurator locates `AuroraSignedSeedTrust.bin` in the AuroraKit
framework bundle, which is present in both the app and packet-tunnel processes.
`scripts/prepare-native-trust-resource.sh` validates a supplied release file
with the sibling Core checkout before copying it to the ignored resource path.

Unsigned local and pull-request builds remain explicit command-line choices;
the project does not disable signing globally. Signed distribution archives use
the normal Xcode signing configuration. Release verification receives explicit
application paths from those archives so it cannot accidentally inspect a
stale Debug product.

## Verification

- Unit tests exercise missing, oversized, rejected, and accepted resource
  inputs; verify temporary input is cleared by the loader contract; and prove
  the driver configures trust before invoking Core.
- A direct ABI test configures a canonical test trust root through the Apple
  bridge and verifies repeat configuration succeeds.
- The full local readiness script builds the portable Core, runs Swift tests,
  compiles all app and extension targets, and checks application bundles.
- Release bundle checks run with `AURORA_REQUIRE_SIGNED_SEED_TRUST=1` after a
  trusted resource is injected, require the exact resource in iOS and macOS
  AuroraKit framework bundles, and validate it through Core.
- The pull-request workflow pins the ABI-compatible Core revision and runs the
  bundle verifier regression. A separately configured release workflow archives
  with signing enabled and verifies archive application paths and signatures
  before distribution.
