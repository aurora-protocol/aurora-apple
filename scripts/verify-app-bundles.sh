#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/DerivedData}"
IOS_APP="${AURORA_IOS_APP:-$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/AuroraIOS.app}"
MAC_APP="${AURORA_MAC_APP:-$DERIVED_DATA_PATH/Build/Products/Debug/AuroraMac.app}"
CODESIGN_BIN="${AURORA_CODESIGN_BIN:-codesign}"
PLIST_BUDDY_BIN="${AURORA_PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
APP_GROUP_IDENTIFIER="group.org.aurora-protocol.aurora.shared"

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
  if ! "$CODESIGN_BIN" --verify --deep --strict "$1"; then
    printf 'invalid code signature: %s\n' "$1" >&2
    exit 1
  fi
}

verify_signed_identity() (
  artifact="$1"
  expected_team="$2"
  expected_bundle_identifier="$3"
  entitlements="$(mktemp "${TMPDIR:-/tmp}/aurora-entitlements.XXXXXX")"
  trap 'rm -f "$entitlements"' EXIT HUP INT TERM

  if ! "$CODESIGN_BIN" -d --entitlements :- "$artifact" > "$entitlements" 2>/dev/null; then
    printf 'unable to read signed entitlements: %s\n' "$artifact" >&2
    exit 1
  fi

  if ! signature_metadata="$("$CODESIGN_BIN" -dv --verbose=4 "$artifact" 2>&1)"; then
    printf 'unable to read signing identity: %s\n' "$artifact" >&2
    exit 1
  fi
  signing_team="$(printf '%s\n' "$signature_metadata" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
  if [ "$signing_team" != "$expected_team" ]; then
    printf 'unexpected signing team: %s\n' "$artifact" >&2
    exit 1
  fi

  require_scalar() {
    key="$1"
    expected="$2"
    label="$3"
    if ! value="$("$PLIST_BUDDY_BIN" -c "Print :$key" "$entitlements" 2>/dev/null)" || [ "$value" != "$expected" ]; then
      printf 'unexpected %s: %s\n' "$label" "$artifact" >&2
      exit 1
    fi
  }

  require_single_array_value() {
    key="$1"
    expected="$2"
    label="$3"
    if ! value="$("$PLIST_BUDDY_BIN" -c "Print :$key:0" "$entitlements" 2>/dev/null)" || [ "$value" != "$expected" ]; then
      printf 'missing expected %s: %s\n' "$label" "$artifact" >&2
      exit 1
    fi
    if "$PLIST_BUDDY_BIN" -c "Print :$key:1" "$entitlements" >/dev/null 2>&1; then
      printf 'unexpected additional %s: %s\n' "$label" "$artifact" >&2
      exit 1
    fi
  }

  require_scalar 'application-identifier' "$expected_team.$expected_bundle_identifier" 'application identifier'
  require_scalar 'com.apple.developer.team-identifier' "$expected_team" 'team identifier'
  require_single_array_value 'com.apple.security.application-groups' "$APP_GROUP_IDENTIFIER" 'application group'
  require_single_array_value 'com.apple.developer.networking.networkextension' 'packet-tunnel-provider' 'network extension entitlement'
)

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
  AURORA_EXPECTED_SIGNING_TEAM="${AURORA_EXPECTED_SIGNING_TEAM:-}"
  if [ -z "$AURORA_EXPECTED_SIGNING_TEAM" ]; then
    printf 'expected signing team is required for signed artifact validation\n' >&2
    exit 1
  fi
  verify_signed_artifact "$IOS_APP"
  verify_signed_artifact "$IOS_APP/PlugIns/AuroraPacketTunnel.appex"
  verify_signed_artifact "$MAC_APP"
  verify_signed_artifact "$MAC_APP/Contents/PlugIns/AuroraPacketTunnel.appex"
  verify_signed_identity "$IOS_APP" "$AURORA_EXPECTED_SIGNING_TEAM" 'org.aurora-protocol.aurora.ios'
  verify_signed_identity "$IOS_APP/PlugIns/AuroraPacketTunnel.appex" "$AURORA_EXPECTED_SIGNING_TEAM" 'org.aurora-protocol.aurora.ios.packet-tunnel'
  verify_signed_identity "$MAC_APP" "$AURORA_EXPECTED_SIGNING_TEAM" 'org.aurora-protocol.aurora.macos'
  verify_signed_identity "$MAC_APP/Contents/PlugIns/AuroraPacketTunnel.appex" "$AURORA_EXPECTED_SIGNING_TEAM" 'org.aurora-protocol.aurora.macos.packet-tunnel'
fi

printf 'app_bundle_check passed=true frameworks=4 extensions=2\n'
