#!/usr/bin/env sh
# Stages the release-owned sealed native trust resource as an AuroraKit
# resource. The portable core validates the canonical encoding before the
# resource is copied. The resource name (AuroraSignedSeedTrust.bin) is shared
# with the Android native client so release artifacts match across platforms.
set -eu

if [ -n "${SRCROOT:-}" ]; then
  cd "$SRCROOT"
else
  cd "$(dirname "$0")/.."
fi
APPLE_DIR="$PWD"
AURORA_CORE_DIR="${AURORA_CORE_DIR:-$APPLE_DIR/../aurora-core}"
RESOURCE_DIR="$APPLE_DIR/Sources/AuroraKit/Resources"
RESOURCE_PATH="$RESOURCE_DIR/AuroraSignedSeedTrust.bin"
TRUST_PATH="${AURORA_SIGNED_SEED_TRUST_PATH:-}"
REQUIRE_TRUST="${AURORA_REQUIRE_SIGNED_SEED_TRUST:-}"
CONFIGURATION="${CONFIGURATION:-}"

require_trust=false
if [ "$CONFIGURATION" = "Release" ] || [ "$REQUIRE_TRUST" = "1" ]; then
  require_trust=true
fi

if [ -z "$TRUST_PATH" ]; then
  if [ "$require_trust" = true ]; then
    rm -f "$RESOURCE_PATH"
    echo "error: AURORA_SIGNED_SEED_TRUST_PATH is required for a release build" >&2
    exit 1
  fi
  umask 077
  mkdir -p "$RESOURCE_DIR"
  : > "$RESOURCE_PATH"
  chmod 600 "$RESOURCE_PATH"
  exit 0
fi

rm -f "$RESOURCE_PATH"
if [ ! -f "$TRUST_PATH" ] || [ ! -r "$TRUST_PATH" ]; then
  echo "error: sealed native trust file is not a readable regular file" >&2
  exit 1
fi
if [ ! -f "$AURORA_CORE_DIR/go.mod" ]; then
  echo "error: aurora-core checkout not found at $AURORA_CORE_DIR" >&2
  exit 1
fi

size="$(LC_ALL=C wc -c < "$TRUST_PATH" | tr -d '[:space:]')"
case "$size" in
  ''|*[!0-9]*)
    echo "error: unable to measure sealed native trust file" >&2
    exit 1
    ;;
esac
if [ "$size" -eq 0 ] || [ "$size" -gt 65536 ]; then
  echo "error: sealed native trust file has an invalid size" >&2
  exit 1
fi

(
  cd "$AURORA_CORE_DIR"
  GOTOOLCHAIN="${GOTOOLCHAIN:-go1.26.6}" \
  GOCACHE="${GOCACHE:-/private/tmp/aurora-gocache}" \
    go run ./cmd/auroractl check-native-provisioning-trust "$TRUST_PATH" >/dev/null
)

umask 077
mkdir -p "$RESOURCE_DIR"
install -m 600 "$TRUST_PATH" "$RESOURCE_PATH"
echo "staged sealed native trust resource for AuroraKit"