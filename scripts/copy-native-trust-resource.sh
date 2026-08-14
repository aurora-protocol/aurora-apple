#!/usr/bin/env sh
set -eu

SOURCE_PATH="$SRCROOT/Sources/AuroraKit/Resources/AuroraSignedSeedTrust.bin"
RESOURCE_PATH="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AuroraSignedSeedTrust.bin"

if [ ! -f "$SOURCE_PATH" ]; then
    if [ "$CONFIGURATION" = "Release" ]; then
        printf 'missing sealed native trust resource: %s\n' "$SOURCE_PATH" >&2
        exit 1
    fi
    exit 0
fi
if [ ! -s "$SOURCE_PATH" ]; then
    printf 'sealed native trust resource is empty: %s\n' "$SOURCE_PATH" >&2
    exit 1
fi

mkdir -p "$(dirname "$RESOURCE_PATH")"
install -m 600 "$SOURCE_PATH" "$RESOURCE_PATH"
