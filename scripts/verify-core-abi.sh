#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AURORA_CORE_DIR="${AURORA_CORE_DIR:-$ROOT/../aurora-core}"
CORE_SOURCE="$AURORA_CORE_DIR/mobile/auroracore/auroracore.go"

if [ ! -f "$CORE_SOURCE" ]; then
    printf 'aurora-core ABI source is unavailable: %s\n' "$CORE_SOURCE" >&2
    exit 1
fi

if ! grep -Fq 'opConfigureNativeProvisioningTrust = 21' "$CORE_SOURCE"; then
    printf 'aurora-core does not export native trust configuration operation\n' >&2
    exit 1
fi
if ! grep -Fq 'func AuroraCoreZeroFree' "$CORE_SOURCE"; then
    printf 'aurora-core does not export zero-and-free ABI operation\n' >&2
    exit 1
fi

printf 'core_abi_check passed=true\n'
