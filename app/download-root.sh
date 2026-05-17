#!/bin/sh
set -eu

: "${ROOTFS_URL:?ROOTFS_URL is required}"
: "${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR is required}"
: "${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH is required}"

rootfs_arch="${ROOTFS_ARCH:-aarch64}"
output="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/root.tar.gz"

curl -L "https://$ROOTFS_URL" -o "$output"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/linuxkit-root.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

tar -xzf "$output" -C "$tmpdir" ./bin/busybox 2>/dev/null || tar -xzf "$output" -C "$tmpdir" bin/busybox
description="$(file "$tmpdir/bin/busybox")"

case "$rootfs_arch:$description" in
    aarch64:*"ARM aarch64"*) ;;
    arm64:*"ARM aarch64"*) ;;
    *)
        echo "Refusing to package non-$rootfs_arch rootfs: $description" >&2
        exit 1
        ;;
esac
