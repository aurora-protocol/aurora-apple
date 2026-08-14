#!/usr/bin/env sh
# Stages the release-owned signed-seed roots as an AuroraKit resource. The
# portable core validates the canonical encoding before the resource is copied.
set -eu

if [ -n "${SRCROOT:-}" ]; then
  cd "$SRCROOT"
else
  cd "$(dirname "$0")/.."
fi
APPLE_DIR="$PWD"
AURORA_CORE_DIR="${AURORA_CORE_DIR:-$APPLE_DIR/../aurora-core}"
RESOURCE_DIR="$APPLE_DIR/Sources/AuroraKit/Resources"
RESOURCE_PATH="$RESOURCE_DIR/AuroraSignedSeedRoots.bin"
ROOTS_PATH="${AURORA_SIGNED_SEED_ROOTS_FILE:-}"
REQUIRE_ROOTS="${AURORA_REQUIRE_SIGNED_SEED_ROOTS:-}"
CONFIGURATION="${CONFIGURATION:-}"

require_roots=false
if [ "$CONFIGURATION" = "Release" ] || [ "$REQUIRE_ROOTS" = "1" ]; then
  require_roots=true
fi

if [ -z "$ROOTS_PATH" ]; then
  if [ "$require_roots" = true ]; then
    rm -f "$RESOURCE_PATH"
    echo "error: AURORA_SIGNED_SEED_ROOTS_FILE is required for a release build" >&2
    exit 1
  fi
  umask 077
  mkdir -p "$RESOURCE_DIR"
  : > "$RESOURCE_PATH"
  chmod 600 "$RESOURCE_PATH"
  exit 0
fi

rm -f "$RESOURCE_PATH"
if [ ! -f "$ROOTS_PATH" ] || [ ! -r "$ROOTS_PATH" ]; then
  echo "error: signed-seed roots file is not a readable regular file" >&2
  exit 1
fi
if [ ! -f "$AURORA_CORE_DIR/go.mod" ]; then
  echo "error: aurora-core checkout not found at $AURORA_CORE_DIR" >&2
  exit 1
fi

size="$(LC_ALL=C wc -c < "$ROOTS_PATH" | tr -d '[:space:]')"
case "$size" in
  ''|*[!0-9]*)
    echo "error: unable to measure signed-seed roots file" >&2
    exit 1
    ;;
esac
if [ "$size" -eq 0 ] || [ "$size" -gt 65536 ]; then
  echo "error: signed-seed roots file has an invalid size" >&2
  exit 1
fi

GOTOOLCHAIN="${GOTOOLCHAIN:-go1.25.13}" \
GOCACHE="${GOCACHE:-/private/tmp/aurora-gocache}" \
go run "$AURORA_CORE_DIR/cmd/auroractl" check-native-provisioning-trust "$ROOTS_PATH" >/dev/null

umask 077
mkdir -p "$RESOURCE_DIR"
install -m 600 "$ROOTS_PATH" "$RESOURCE_PATH"
echo "staged signed-seed roots for AuroraKit"
