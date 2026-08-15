#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

RESOURCE_PATH="$PWD/Sources/AuroraKit/Resources/AuroraSignedSeedTrust.bin"
mkdir -p "$(dirname "$RESOURCE_PATH")"
printf '%s' 'AQGhoaGhoaGhoaGhoaGhoaGhDmehdcbgoQvoAE1oXDEFyAFBAgEAQQRrF9Hy4SxCR/i85uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2QGg3v1H1AAAAAAAAAAEAAAAA9IZXAAAAAAAE' | base64 -D -o "$RESOURCE_PATH"
chmod 600 "$RESOURCE_PATH"
printf 'prepared non-operational native trust test resource\n'
