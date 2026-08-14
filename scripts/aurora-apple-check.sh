#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/DerivedData}"
XCODEBUILD="${XCODEBUILD:-xcodebuild}"
SWIFTPM_CACHE_PATH="$DERIVED_DATA_PATH/swiftpm-cache"
SWIFTPM_CONFIG_PATH="$DERIVED_DATA_PATH/swiftpm-config"
SWIFTPM_SECURITY_PATH="$DERIVED_DATA_PATH/swiftpm-security"
CLANG_MODULE_CACHE_PATH="$DERIVED_DATA_PATH/ModuleCache.noindex"

export CLANG_MODULE_CACHE_PATH

mkdir -p "$SWIFTPM_CACHE_PATH" "$SWIFTPM_CONFIG_PATH" "$SWIFTPM_SECURITY_PATH" "$CLANG_MODULE_CACHE_PATH"

scripts/verify-core-abi.sh

# Build the embedded portable core first; AuroraKit links it (Section 35.10).
scripts/build-auroracore-xcframework.sh

scripts/verify-app-bundles-test.sh

swift test \
  --cache-path "$SWIFTPM_CACHE_PATH" \
  --config-path "$SWIFTPM_CONFIG_PATH" \
  --security-path "$SWIFTPM_SECURITY_PATH" \
  --manifest-cache local

"$XCODEBUILD" -project AuroraApple.xcodeproj -scheme AuroraMac -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA_PATH" build CODE_SIGNING_ALLOWED=NO
"$XCODEBUILD" -project AuroraApple.xcodeproj -scheme AuroraIOS -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED_DATA_PATH" build CODE_SIGNING_ALLOWED=NO
"$XCODEBUILD" -project AuroraApple.xcodeproj -scheme AuroraPacketTunnel_macOS -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA_PATH" build CODE_SIGNING_ALLOWED=NO
"$XCODEBUILD" -project AuroraApple.xcodeproj -scheme AuroraPacketTunnel_iOS -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED_DATA_PATH" build CODE_SIGNING_ALLOWED=NO

DERIVED_DATA_PATH="$DERIVED_DATA_PATH" sh scripts/verify-app-bundles.sh
