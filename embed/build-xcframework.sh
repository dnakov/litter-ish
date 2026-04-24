#!/bin/sh
# Build codex_ish.xcframework from the three iOS slices.
#
# Prereqs:
#   brew install meson ninja llvm lld libarchive
#   Xcode Command Line Tools
#
# Output: build/codex_ish.xcframework in the iSH repo root.

set -eu

cd "$(dirname "$0")/.."
ISH_ROOT=$(pwd)
OUT="$ISH_ROOT/build/codex_ish.xcframework"
BUILD_DIRS="build-ios-device build-ios-sim-arm64 build-ios-sim-x86_64"
CROSS_DIR="$ISH_ROOT/embed/cross"

# llvm-ar / llvm-clang must be on PATH for Meson's archiver and the VDSO
# cross-compile step.
export PATH="/opt/homebrew/opt/llvm/bin:$PATH"

configure_slice() {
    build_dir="$1"
    cross_file="$2"
    if [ ! -f "$build_dir/build.ninja" ]; then
        echo "--> meson setup $build_dir ($cross_file)"
        meson setup "$build_dir" --cross-file "$cross_file" --buildtype=release >/dev/null
    fi
}

build_slice() {
    build_dir="$1"
    echo "--> ninja -C $build_dir"
    ninja -C "$build_dir" \
        libish.a libish_emu.a libfakefs.a embed/libish_embed.a >/dev/null
}

merge_slice() {
    build_dir="$1"
    out="$build_dir/libcodex_ish.a"
    echo "--> libtool -static -o $out"
    # Apple libtool merges multiple .a files into one. Use xcrun to pick
    # the Xcode toolchain copy so it handles Mach-O/bitcode correctly.
    xcrun libtool -static -o "$out" \
        "$build_dir/libish.a" \
        "$build_dir/libish_emu.a" \
        "$build_dir/libfakefs.a" \
        "$build_dir/embed/libish_embed.a"
}

# --- Step 1: configure + build each slice
configure_slice build-ios-device       "$CROSS_DIR/ios-device.txt"
configure_slice build-ios-sim-arm64    "$CROSS_DIR/ios-sim-arm64.txt"
configure_slice build-ios-sim-x86_64   "$CROSS_DIR/ios-sim-x86_64.txt"

for d in $BUILD_DIRS; do build_slice  "$d"; done
for d in $BUILD_DIRS; do merge_slice  "$d"; done

# --- Step 2: lipo the two sim arches together into one static lib
SIM_DIR="$ISH_ROOT/build/ios-sim-fat"
mkdir -p "$SIM_DIR"
echo "--> lipo -create sim arm64 + x86_64"
xcrun lipo -create -output "$SIM_DIR/libcodex_ish.a" \
    "$ISH_ROOT/build-ios-sim-arm64/libcodex_ish.a" \
    "$ISH_ROOT/build-ios-sim-x86_64/libcodex_ish.a"

# --- Step 3: prepare a Headers/ dir for the xcframework
HEADERS_DIR="$ISH_ROOT/build/codex_ish_headers"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp "$ISH_ROOT/embed/ish_embed.h" "$HEADERS_DIR/"

# module.modulemap lets Swift consumers `import CodexISH` directly.
cat >"$HEADERS_DIR/module.modulemap" <<'EOF'
module CodexISH {
    header "ish_embed.h"
    export *
}
EOF

# --- Step 4: xcodebuild -create-xcframework
rm -rf "$OUT"
echo "--> xcodebuild -create-xcframework -> $OUT"
xcrun xcodebuild -create-xcframework \
    -library "$ISH_ROOT/build-ios-device/libcodex_ish.a" -headers "$HEADERS_DIR" \
    -library "$SIM_DIR/libcodex_ish.a" -headers "$HEADERS_DIR" \
    -output "$OUT" >/dev/null

echo
echo "built: $OUT"
find "$OUT" -type f \( -name '*.a' -o -name '*.h' -o -name '*.plist' -o -name '*.modulemap' \) \
    -exec ls -lh {} \; | awk '{print $5, $NF}'
