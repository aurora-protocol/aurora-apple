#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/DerivedData}"
IOS_APP="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/AuroraIOS.app"
MAC_APP="$DERIVED_DATA_PATH/Build/Products/Debug/AuroraMac.app"

require_file() {
  if [ ! -f "$1" ]; then
    printf 'missing app bundle file: %s\n' "$1" >&2
    exit 1
  fi
}

require_sealed_trust_resource() {
  resource="$(find "$1" -type f -name AuroraSignedSeedTrust.bin -size +0c -print -quit)"
  if [ -z "$resource" ]; then
    printf 'missing sealed trust resource in framework: %s\n' "$1" >&2
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
  require_sealed_trust_resource "$IOS_APP/Frameworks/AuroraKit.framework"
  require_sealed_trust_resource "$MAC_APP/Contents/Frameworks/AuroraKit.framework"
fi

printf 'app_bundle_check passed=true frameworks=4 extensions=2\n'
