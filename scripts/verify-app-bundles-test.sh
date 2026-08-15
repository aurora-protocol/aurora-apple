#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT_CORE_DIR="${AURORA_CORE_DIR:-$ROOT/../aurora-core}"
DERIVED_DATA_PATH="$(mktemp -d /private/tmp/aurora-bundle-test.XXXXXX)"
IOS_FRAMEWORK="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/AuroraIOS.app/Frameworks/AuroraKit.framework"
MAC_FRAMEWORK="$DERIVED_DATA_PATH/Build/Products/Debug/AuroraMac.app/Contents/Frameworks/AuroraKit.framework"
CANONICAL_TRUST="$DERIVED_DATA_PATH/AuroraSignedSeedTrust.bin"

if [ ! -d "$AUDIT_CORE_DIR/cmd/auroractl" ]; then
    printf 'aurora-core checkout is unavailable: %s\n' "$AUDIT_CORE_DIR" >&2
    exit 1
fi

printf '%s' 'AQGhoaGhoaGhoaGhoaGhoaGhDmehdcbgoQvoAE1oXDEFyAFBAgEAQQRrF9Hy4SxCR/i85uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2QGg3v1H1AAAAAAAAAAEAAAAA9IZXAAAAAAAE' | base64 -D -o "$CANONICAL_TRUST"

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

if AURORA_REQUIRE_SIGNED_SEED_TRUST=1 AURORA_CORE_DIR="$AUDIT_CORE_DIR" DERIVED_DATA_PATH="$DERIVED_DATA_PATH" sh "$ROOT/scripts/verify-app-bundles.sh"; then
    printf 'sealed trust resource check unexpectedly passed without resources\n' >&2
    exit 1
fi

mkdir -p "$IOS_FRAMEWORK/decoy" "$MAC_FRAMEWORK/decoy"
cp "$CANONICAL_TRUST" "$IOS_FRAMEWORK/decoy/AuroraSignedSeedTrust.bin"
cp "$CANONICAL_TRUST" "$MAC_FRAMEWORK/decoy/AuroraSignedSeedTrust.bin"
if AURORA_REQUIRE_SIGNED_SEED_TRUST=1 AURORA_CORE_DIR="$AUDIT_CORE_DIR" DERIVED_DATA_PATH="$DERIVED_DATA_PATH" sh "$ROOT/scripts/verify-app-bundles.sh"; then
    printf 'decoy trust resources unexpectedly passed\n' >&2
    exit 1
fi

cp "$CANONICAL_TRUST" "$IOS_FRAMEWORK/AuroraSignedSeedTrust.bin"
mkdir -p "$MAC_FRAMEWORK/Resources"
cp "$CANONICAL_TRUST" "$MAC_FRAMEWORK/Resources/AuroraSignedSeedTrust.bin"
AURORA_REQUIRE_SIGNED_SEED_TRUST=1 AURORA_CORE_DIR="$AUDIT_CORE_DIR" DERIVED_DATA_PATH="$DERIVED_DATA_PATH" sh "$ROOT/scripts/verify-app-bundles.sh"
