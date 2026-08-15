#!/usr/bin/env sh
# Builds AuroraCore.xcframework from the portable Go core (aurora-core) so the
# Apple thin adapters can delegate all wire/AdmissionProof/carrier logic to the
# portable core instead of reimplementing it in Swift (Aurora spec Section 35.10).
#
# The framework is a build artifact (gitignored). Regenerate it whenever the
# portable core changes. Requires the Go toolchain and Xcode.
#
# Slices: macOS (arm64+x86_64), iOS device (arm64), iOS simulator (arm64+x86_64).
set -eu

cd "$(dirname "$0")/.."
APPLE_DIR="$PWD"
AURORA_CORE_DIR="${AURORA_CORE_DIR:-$APPLE_DIR/../aurora-core}"
EXPECTED_CORE_REVISION="c2d9ac7758058c002aaac1e804ac677382c2c520"
OUT_DIR="${OUT_DIR:-$APPLE_DIR/Vendor}"
BUILD_DIR="$OUT_DIR/.auroracore-build"
PKG="./mobile/auroracore"
IOS_MIN="17.0"
MACOS_MIN="14.0"

export GOCACHE="${GOCACHE:-/private/tmp/aurora-gocache}"

if [ ! -d "$AURORA_CORE_DIR/mobile/auroracore" ]; then
  echo "error: aurora-core binding not found at $AURORA_CORE_DIR/mobile/auroracore" >&2
  echo "set AURORA_CORE_DIR to the aurora-core checkout" >&2
  exit 1
fi
if [ "$(git -C "$AURORA_CORE_DIR" rev-parse HEAD)" != "$EXPECTED_CORE_REVISION" ]; then
  echo "error: aurora-core revision does not match the Apple ABI pin" >&2
  exit 1
fi

scripts/prepare-signed-seed-roots.sh

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# build_arch <out.a> <GOOS> <GOARCH> <sdk> <clang-target>
build_arch() {
  out="$1"; goos="$2"; goarch="$3"; sdk="$4"; target="$5"
  sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
  clang="$(xcrun --sdk "$sdk" --find clang)"
  echo ">> $out ($goos/$goarch, $target)"
  ( cd "$AURORA_CORE_DIR" && \
    CGO_ENABLED=1 GOOS="$goos" GOARCH="$goarch" \
    CC="$clang -target $target -isysroot $sdkpath" \
    CGO_CFLAGS="-target $target -isysroot $sdkpath" \
    go build -buildmode=c-archive -o "$out" "$PKG" )
}

make_headers() {
  dir="$1"; src_header="$2"
  mkdir -p "$dir"
  cp "$src_header" "$dir/auroracore.h"
  cat > "$dir/module.modulemap" <<'EOF'
module AuroraCoreFFI {
    header "auroracore.h"
    export *
}
EOF
}

# xcframework static libraries must be lib-prefixed and live in distinct dirs.
mkdir -p "$BUILD_DIR/macos" "$BUILD_DIR/ios" "$BUILD_DIR/iossim"

# macOS universal (arm64 + x86_64)
build_arch "$BUILD_DIR/macos-arm64.a"  "darwin" "arm64" "macosx" "arm64-apple-macos$MACOS_MIN"
build_arch "$BUILD_DIR/macos-amd64.a"  "darwin" "amd64" "macosx" "x86_64-apple-macos$MACOS_MIN"
lipo -create "$BUILD_DIR/macos-arm64.a" "$BUILD_DIR/macos-amd64.a" -output "$BUILD_DIR/macos/libauroracore.a"
make_headers "$BUILD_DIR/macos-headers" "$BUILD_DIR/macos-arm64.h"

# iOS device (arm64)
build_arch "$BUILD_DIR/ios/libauroracore.a" "ios" "arm64" "iphoneos" "arm64-apple-ios$IOS_MIN"
make_headers "$BUILD_DIR/ios-headers" "$BUILD_DIR/ios/libauroracore.h"

# iOS simulator universal (arm64 + x86_64)
build_arch "$BUILD_DIR/iossim-arm64.a" "ios" "arm64" "iphonesimulator" "arm64-apple-ios$IOS_MIN-simulator"
build_arch "$BUILD_DIR/iossim-amd64.a" "ios" "amd64" "iphonesimulator" "x86_64-apple-ios$IOS_MIN-simulator"
lipo -create "$BUILD_DIR/iossim-arm64.a" "$BUILD_DIR/iossim-amd64.a" -output "$BUILD_DIR/iossim/libauroracore.a"
make_headers "$BUILD_DIR/iossim-headers" "$BUILD_DIR/iossim-arm64.h"

rm -rf "$OUT_DIR/AuroraCore.xcframework"
xcodebuild -create-xcframework \
  -library "$BUILD_DIR/macos/libauroracore.a"  -headers "$BUILD_DIR/macos-headers" \
  -library "$BUILD_DIR/ios/libauroracore.a"    -headers "$BUILD_DIR/ios-headers" \
  -library "$BUILD_DIR/iossim/libauroracore.a" -headers "$BUILD_DIR/iossim-headers" \
  -output "$OUT_DIR/AuroraCore.xcframework"

rm -rf "$BUILD_DIR"
echo "wrote $OUT_DIR/AuroraCore.xcframework"
