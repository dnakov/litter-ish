#!/bin/sh
# Build the Alpine fakefs artifact that the `ish-embed-host` Rust crate
# expects at runtime. The supervisor binary itself is embedded into the
# crate via `include_bytes!` and dropped into the rootfs at boot, so this
# script only needs to produce the base Alpine fakefs.
#
# Inputs (env, optional):
#   ALPINE_VERSION  default 3.21.0
#
# The embedded runtime is ARM64-only, so use Alpine's aarch64 minirootfs and
# official aarch64 package repositories.
#
# Outputs (in <repo>/build/):
#   fs/         directory the consumer bundles or copies into sandbox
#   fs.tar.gz   convenience tarball of the same directory

set -eu

cd "$(dirname "$0")/.."
ISH_ROOT=$(pwd)
BUILD="$ISH_ROOT/build"
ALPINE_VERSION="${ALPINE_VERSION:-3.21.0}"
ALPINE_MAJOR=$(echo "$ALPINE_VERSION" | cut -d. -f1-2)
TARBALL_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MAJOR}/releases/aarch64/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"

mkdir -p "$BUILD"
TARBALL="$BUILD/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"
ROOTFS_DIR="$BUILD/fs"
ROOTFS_TGZ="$BUILD/fs.tar.gz"

# Need the host fakefsify binary; ensure the host meson build exists.
HOST_BUILD="$BUILD/host-fakefsify"
export PATH="/opt/homebrew/opt/llvm/bin:$PATH"
if [ ! -x "$HOST_BUILD/tools/fakefsify" ]; then
    echo "--> meson setup $HOST_BUILD (host)"
    meson setup "$HOST_BUILD" --buildtype=release >/dev/null
fi
echo "--> ninja fakefsify"
ninja -C "$HOST_BUILD" tools/fakefsify >/dev/null

if [ ! -f "$TARBALL" ]; then
    echo "--> downloading $TARBALL_URL"
    curl -sSL -o "$TARBALL" "$TARBALL_URL"
fi

rm -rf "$ROOTFS_DIR"
echo "--> fakefsify -> $ROOTFS_DIR"
"$HOST_BUILD/tools/fakefsify" "$TARBALL" "$ROOTFS_DIR" >/dev/null
# fakefsify leaves the SQLite WAL files behind; checkpoint them so the
# shipped meta.db is self-contained.
sqlite3 "$ROOTFS_DIR/meta.db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
rm -f "$ROOTFS_DIR/meta.db-shm" "$ROOTFS_DIR/meta.db-wal"

echo "--> tar -czf $ROOTFS_TGZ"
tar -czf "$ROOTFS_TGZ" -C "$BUILD" fs

du -sh "$ROOTFS_DIR" "$ROOTFS_TGZ"
