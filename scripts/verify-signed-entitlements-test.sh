#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d /private/tmp/aurora-signed-entitlements-test.XXXXXX)"
FAKE_CODESIGN="$TEMP_ROOT/codesign"
IOS_APP="$TEMP_ROOT/AuroraIOS.app"
MAC_APP="$TEMP_ROOT/AuroraMac.app"

trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

mkdir -p "$IOS_APP/Frameworks/AuroraKit.framework" "$IOS_APP/Frameworks/AuroraUI.framework" "$IOS_APP/PlugIns/AuroraPacketTunnel.appex"
mkdir -p "$MAC_APP/Contents/Frameworks/AuroraKit.framework" "$MAC_APP/Contents/Frameworks/AuroraUI.framework" "$MAC_APP/Contents/PlugIns/AuroraPacketTunnel.appex/Contents/MacOS"
touch "$IOS_APP/Frameworks/AuroraKit.framework/AuroraKit" "$IOS_APP/Frameworks/AuroraUI.framework/AuroraUI" "$IOS_APP/PlugIns/AuroraPacketTunnel.appex/AuroraPacketTunnel"
touch "$MAC_APP/Contents/Frameworks/AuroraKit.framework/AuroraKit" "$MAC_APP/Contents/Frameworks/AuroraUI.framework/AuroraUI" "$MAC_APP/Contents/PlugIns/AuroraPacketTunnel.appex/Contents/MacOS/AuroraPacketTunnel"

printf '%s\n' \
  '#!/usr/bin/env sh' \
  'set -eu' \
  'if [ "$1" = "--verify" ]; then exit 0; fi' \
  'for target do :; done' \
  'case "$target" in' \
  '  */AuroraIOS.app) bundle="org.aurora-protocol.aurora.ios" ;;' \
  '  */AuroraIOS.app/PlugIns/AuroraPacketTunnel.appex) bundle="org.aurora-protocol.aurora.ios.packet-tunnel" ;;' \
  '  */AuroraMac.app) bundle="org.aurora-protocol.aurora.macos" ;;' \
  '  */AuroraMac.app/Contents/PlugIns/AuroraPacketTunnel.appex) bundle="org.aurora-protocol.aurora.macos.packet-tunnel" ;;' \
  '  *) exit 3 ;;' \
  'esac' \
  'team="ABCDEFGHIJ"' \
  'identifier="$team.$bundle"' \
  'group="group.org.aurora-protocol.aurora.shared"' \
  'network="packet-tunnel-provider"' \
  'case "${AURORA_FAKE_ENTITLEMENT_MODE:-valid}" in' \
  '  wrong-team) team="KLMNOPQRST"; identifier="$team.$bundle" ;;' \
  '  wrong-identifier) identifier="$team.org.aurora-protocol.invalid" ;;' \
  '  missing-app-group) group="" ;;' \
  '  missing-network-extension) network="" ;;' \
  '  valid) ;;' \
  '  *) exit 4 ;;' \
  'esac' \
  'if [ "$1" = "-dv" ]; then printf "TeamIdentifier=%s\\n" "$team" >&2; exit 0; fi' \
  'if [ "$1" != "-d" ]; then exit 2; fi' \
  'printf "%s\\n" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" "<plist version=\"1.0\"><dict>" "<key>application-identifier</key><string>$identifier</string>" "<key>com.apple.developer.team-identifier</key><string>$team</string>"' \
  'if [ -n "$group" ]; then printf "%s\\n" "<key>com.apple.security.application-groups</key><array><string>$group</string></array>"; fi' \
  'if [ -n "$network" ]; then printf "%s\\n" "<key>com.apple.developer.networking.networkextension</key><array><string>$network</string></array>"; fi' \
  'printf "%s\\n" "</dict></plist>"' > "$FAKE_CODESIGN"
chmod +x "$FAKE_CODESIGN"

verify() {
  AURORA_CODESIGN_BIN="$FAKE_CODESIGN" \
    AURORA_EXPECTED_SIGNING_TEAM=ABCDEFGHIJ \
    AURORA_REQUIRE_SIGNED_ARTIFACTS=1 \
    AURORA_REQUIRE_SIGNED_SEED_TRUST=0 \
    AURORA_IOS_APP="$IOS_APP" \
    AURORA_MAC_APP="$MAC_APP" \
    sh "$ROOT/scripts/verify-app-bundles.sh"
}

verify

for mode in wrong-team wrong-identifier missing-app-group missing-network-extension; do
  if AURORA_FAKE_ENTITLEMENT_MODE="$mode" verify; then
    printf 'tampered entitlement verification unexpectedly passed: %s\n' "$mode" >&2
    exit 1
  fi
done
