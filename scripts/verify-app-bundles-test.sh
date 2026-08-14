#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="$(mktemp -d /private/tmp/aurora-bundle-test.XXXXXX)"
IOS_FRAMEWORK="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/AuroraIOS.app/Frameworks/AuroraKit.framework"
MAC_FRAMEWORK="$DERIVED_DATA_PATH/Build/Products/Debug/AuroraMac.app/Contents/Frameworks/AuroraKit.framework"

mkdir -p "$IOS_FRAMEWORK" "$MAC_FRAMEWORK"
mkdir -p "$(dirname "$IOS_FRAMEWORK")"
mkdir -p "$(dirname "$MAC_FRAMEWORK")"
touch "$IOS_FRAMEWORK/AuroraKit"
touch "$MAC_FRAMEWORK/AuroraKit"
mkdir -p "$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/AuroraIOS.app/Frameworks/AuroraUI.framework"
touch "$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/AuroraIOS.app/Frameworks/AuroraUI.framework/AuroraUI"
mkdir -p "$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/AuroraIOS.app/PlugIns/AuroraPacketTunnel.appex"
touch "$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/AuroraIOS.app/PlugIns/AuroraPacketTunnel.appex/AuroraPacketTunnel"
mkdir -p "$DERIVED_DATA_PATH/Build/Products/Debug/AuroraMac.app/Contents/Frameworks/AuroraUI.framework"
touch "$DERIVED_DATA_PATH/Build/Products/Debug/AuroraMac.app/Contents/Frameworks/AuroraUI.framework/AuroraUI"
mkdir -p "$DERIVED_DATA_PATH/Build/Products/Debug/AuroraMac.app/Contents/PlugIns/AuroraPacketTunnel.appex/Contents/MacOS"
touch "$DERIVED_DATA_PATH/Build/Products/Debug/AuroraMac.app/Contents/PlugIns/AuroraPacketTunnel.appex/Contents/MacOS/AuroraPacketTunnel"

if AURORA_REQUIRE_SIGNED_SEED_TRUST=1 DERIVED_DATA_PATH="$DERIVED_DATA_PATH" sh "$ROOT/scripts/verify-app-bundles.sh"; then
    printf 'sealed trust resource check unexpectedly passed without resources\n' >&2
    exit 1
fi

printf 'test-root' > "$IOS_FRAMEWORK/AuroraSignedSeedTrust.bin"
printf 'test-root' > "$MAC_FRAMEWORK/AuroraSignedSeedTrust.bin"
AURORA_REQUIRE_SIGNED_SEED_TRUST=1 DERIVED_DATA_PATH="$DERIVED_DATA_PATH" sh "$ROOT/scripts/verify-app-bundles.sh"
