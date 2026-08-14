#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/DerivedData}"
IOS_APP="${AURORA_IOS_APP:-$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/AuroraIOS.app}"
MAC_APP="${AURORA_MAC_APP:-$DERIVED_DATA_PATH/Build/Products/Debug/AuroraMac.app}"

require_file() {
  if [ ! -f "$1" ]; then
    printf 'missing app bundle file: %s\n' "$1" >&2
    exit 1
  fi
}

validate_sealed_trust_resource() {
  trust_resource="$1"
  require_file "$trust_resource"
  if [ ! -s "$trust_resource" ]; then
    printf 'sealed trust resource is empty: %s\n' "$trust_resource" >&2
    exit 1
  fi
  if [ ! -d "$AURORA_CORE_DIR/cmd/auroractl" ]; then
    printf 'aurora-core checkout is unavailable: %s\n' "$AURORA_CORE_DIR" >&2
    exit 1
  fi
  (
    cd "$AURORA_CORE_DIR"
    go run ./cmd/auroractl check-native-provisioning-trust "$trust_resource"
  )
}

verify_signed_artifact() {
  if ! codesign --verify --deep --strict "$1"; then
    printf 'invalid code signature: %s\n' "$1" >&2
    exit 1
  fi
}

require_file "$IOS_APP/Frameworks/AuroraKit.framework/AuroraKit"
require_file "$IOS_APP/Frameworks/AuroraUI.framework/AuroraUI"
require_file "$IOS_APP/PlugIns/AuroraPacketTunnel.appex/AuroraPacketTunnel"

require_file "$MAC_APP/Contents/Frameworks/AuroraKit.framework/AuroraKit"
require_file "$MAC_APP/Contents/Frameworks/AuroraUI.framework/AuroraUI"
require_file "$MAC_APP/Contents/PlugIns/AuroraPacketTunnel.appex/Contents/MacOS/AuroraPacketTunnel"

if [ "${AURORA_REQUIRE_SIGNED_SEED_TRUST:-0}" = "1" ]; then
  AURORA_CORE_DIR="${AURORA_CORE_DIR:-$PWD/../aurora-core}"
  validate_sealed_trust_resource "$IOS_APP/Frameworks/AuroraKit.framework/AuroraSignedSeedTrust.bin"
  validate_sealed_trust_resource "$MAC_APP/Contents/Frameworks/AuroraKit.framework/Resources/AuroraSignedSeedTrust.bin"
fi

if [ "${AURORA_REQUIRE_SIGNED_ARTIFACTS:-0}" = "1" ]; then
  verify_signed_artifact "$IOS_APP"
  verify_signed_artifact "$MAC_APP"
fi

printf 'app_bundle_check passed=true frameworks=4 extensions=2\n'
