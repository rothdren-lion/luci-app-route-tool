#!/bin/sh
# Build APK (ADB v3 format) package for luci-app-route-tool
# OpenWrt 25.12+ uses apk (ADB format), NOT the old gzip-concat format
# Requires: apk-tools (compiled from https://gitlab.alpinelinux.org/alpine/apk-tools)

set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE"

VERSION="$(grep PKG_VERSION Makefile | sed 's/.*:=//')"
RELEASE="$(grep PKG_RELEASE Makefile | sed 's/.*:=//')"
FULL_VER="${VERSION}-r${RELEASE}"
PKG_NAME="luci-app-route-tool"
APK_FILE="${PKG_NAME}_${VERSION}-r${RELEASE}_all.apk"
APK_BIN="${APK_TOOLS_BIN:-$(command -v apk 2>/dev/null || true)}"

echo "=== Building APK: ${PKG_NAME} ${FULL_VER} ==="

# Verify apk-tools is available
if [ ! -x "$APK_BIN" ]; then
    echo "ERROR: apk-tools not found at $APK_BIN"
    echo "  Build from source: git clone https://gitlab.alpinelinux.org/alpine/apk-tools && cd apk-tools && meson setup build && ninja -C build"
    echo "  Or set APK_TOOLS_BIN environment variable"
    exit 1
fi

# Build ADB-format APK using apk-tools mkpkg
# Key notes on OpenWrt APK format requirements:
#   - arch=noarch (not "all") for architecture-independent packages
#   - Do NOT add self-provides (apk mkpkg adds it automatically; explicit self-provides causes conflicts)
#   - version format: X.Y.Z-rN (dash-r before release number)
#   - --allow-untrusted needed on router since package is unsigned
rm -f "$BASE/releases/$APK_FILE"
mkdir -p "$BASE/releases"
# Stage files separately: exclude *.orig backups from the package
APK_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/route-tool-apk.XXXXXX")"
trap 'rm -rf -- "$APK_STAGE"' EXIT HUP INT TERM
cp -R --no-preserve=ownership,xattr "$BASE/files/." "$APK_STAGE/"
find "$APK_STAGE" -name '*.orig' -delete

"$APK_BIN" mkpkg \
    --info "name:${PKG_NAME}" \
    --info "version:${FULL_VER}" \
    --info "description:Route Tool - backup/write router key partitions from LuCI" \
    --info "url:https://github.com/rothdren-lion/luci-app-route-tool" \
    --info "arch:noarch" \
    --info "license:GPL-2.0-only" \
    --info "origin:${PKG_NAME}" \
    --info "maintainer:godsun.pro" \
    --info "depends:luci-base" \
    --info "tags:openwrt:section=luci" \
    --files "$APK_STAGE" \
    --script "post-install:$BASE/CONTROL/postinst" \
    --script "pre-deinstall:$BASE/CONTROL/prerm" \
    --script "post-deinstall:$BASE/CONTROL/postrm" \
    --output "$BASE/releases/$APK_FILE"

# Verify
"$APK_BIN" verify --allow-untrusted "$BASE/releases/$APK_FILE" 2>&1 || true

SIZE=$(wc -c < "$BASE/releases/$APK_FILE")
echo ""
echo "=== APK built successfully ==="
echo "File: releases/$APK_FILE"
echo "Size: ${SIZE} bytes"
echo ""
echo "Install on OpenWrt 25.12+:"
echo "  # If upgrading from a previous install:"
echo "  apk del ${PKG_NAME} 2>/dev/null || true"
echo "  apk add --allow-untrusted ${APK_FILE}"
