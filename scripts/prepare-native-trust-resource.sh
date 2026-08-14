#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

AURORA_CORE_DIR="${AURORA_CORE_DIR:-$PWD/../aurora-core}"
SOURCE_PATH="${AURORA_SIGNED_SEED_TRUST_PATH:-}"
RESOURCE_PATH="$PWD/Sources/AuroraKit/Resources/AuroraSignedSeedTrust.bin"

if [ -z "$SOURCE_PATH" ]; then
    printf 'AURORA_SIGNED_SEED_TRUST_PATH is required\n' >&2
    exit 1
fi
if [ ! -f "$SOURCE_PATH" ]; then
    printf 'signed-seed trust file is unavailable: %s\n' "$SOURCE_PATH" >&2
    exit 1
fi
if [ ! -d "$AURORA_CORE_DIR/cmd/auroractl" ]; then
    printf 'aurora-core checkout is unavailable: %s\n' "$AURORA_CORE_DIR" >&2
    exit 1
fi

(
    cd "$AURORA_CORE_DIR"
    go run ./cmd/auroractl check-native-provisioning-trust "$SOURCE_PATH"
)

mkdir -p "$(dirname "$RESOURCE_PATH")"
umask 077
install -m 600 "$SOURCE_PATH" "$RESOURCE_PATH"
printf 'prepared sealed native trust resource\n'
