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
swift test
xcodegen generate
xcodebuild -project AuroraApple.xcodeproj -scheme AuroraMac -destination 'platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project AuroraApple.xcodeproj -scheme AuroraIOS -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project AuroraApple.xcodeproj -scheme AuroraPacketTunnel_macOS -destination 'platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project AuroraApple.xcodeproj -scheme AuroraPacketTunnel_iOS -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
```

The generated Xcode project is committed so the apps can be opened and built in Xcode without a generator step.
