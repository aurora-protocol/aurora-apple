# Aurora Apple

Aurora Apple contains the iOS and macOS client apps plus shared Swift client libraries.

## What is included

- `AuroraKit`: configuration, server health checks, client state, and diagnostic redaction.
- `AuroraUI`: reusable SwiftUI status surface for client apps.
- `AuroraIOS`: iOS app target that checks a running Aurora server.
- `AuroraMac`: macOS app target that checks a running Aurora server.
- `SharedNetworkExtension`: shared packet tunnel provider with Network Extension IPv4/DNS settings for entitlement-backed packaging work.

## Local checks

```sh
scripts/aurora-apple-check.sh
```

The readiness check runs the Swift package tests and unsigned Xcode builds for `AuroraMac`, `AuroraIOS`, `AuroraPacketTunnel_macOS`, and `AuroraPacketTunnel_iOS`.

The generated Xcode project is committed so the apps can be opened and built in Xcode without a generator step. Regenerate it after editing `project.yml`:

```sh
xcodegen generate
```
