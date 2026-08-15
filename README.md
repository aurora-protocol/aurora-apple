# Aurora Apple

Aurora Apple contains the iOS and macOS client apps plus shared Swift client libraries.

## What is included

- `AuroraKit`: configuration, client state, diagnostic redaction, and the thin
  adapter over the embedded portable core.
- `AuroraUI`: reusable SwiftUI status surface for client apps.
- `AuroraIOS`: iOS app target that checks a running Aurora server.
- `AuroraMac`: macOS app target that checks a running Aurora server.
- `SharedNetworkExtension`: shared packet tunnel provider with Network Extension IPv4/DNS settings for entitlement-backed packaging work.

## Embedded portable core

Per Aurora spec Section 35.10, wire encoding, AdmissionProof handling,
ReplayProof, and the cover-issuance carrier codec are portable-core
responsibilities and MUST NOT be reimplemented in the platform adapter.
`AuroraKit` therefore links `AuroraCore.xcframework`, a C archive built from the
Go `aurora-core` repository, and delegates all byte-level protocol work to it;
the Swift layer performs only network and packet I/O.

`AuroraCore.xcframework` is a build artifact (gitignored). Build it from the
exact `aurora-core` revision pinned by the build script before building the
package or apps:

```sh
scripts/build-auroracore-xcframework.sh        # uses ../aurora-core by default
AURORA_CORE_DIR=/path/to/aurora-core scripts/build-auroracore-xcframework.sh
```

It produces macOS (arm64+x86_64), iOS device (arm64), and iOS simulator
(arm64+x86_64) slices. Requires the Go toolchain and Xcode.

## Signed-seed roots

Native provisioning verifies signed seeds against roots supplied separately from
the provisioning bundle. Release builds require a canonical sealed trust resource
from the release environment and stage it as an `AuroraKit` resource bundled as
`AuroraSignedSeedTrust.bin` (matching the Android native client's asset name):

```sh
AURORA_SIGNED_SEED_TRUST_PATH=/secure/path/AuroraSignedSeedTrust.bin \
  scripts/build-auroracore-xcframework.sh
```

The staging step rejects missing, oversized, malformed, and non-canonical
inputs. It deletes any previously staged resource before reporting a failure.
The root bundle is intentionally ignored by Git and must be supplied for every
release archive. Debug builds use an empty placeholder, which native
provisioning rejects.

## Local checks

```sh
scripts/aurora-apple-check.sh
```

The readiness check builds the embedded core, runs the Swift package tests, and
performs unsigned Xcode builds for `AuroraMac`, `AuroraIOS`,
`AuroraPacketTunnel_macOS`, and `AuroraPacketTunnel_iOS`.

The generated Xcode project is committed so the apps can be opened and built in Xcode without a generator step. Regenerate it after editing `project.yml`:

```sh
xcodegen generate
```
