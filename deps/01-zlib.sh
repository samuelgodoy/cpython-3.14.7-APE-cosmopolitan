#!/bin/bash
# Builds zlib from source, once per architecture, with the raw cosmocc
# per-arch compilers, and installs the static libs into the toolchain's
# own arch lib dirs (see deps/common.sh). Never use the OS's zlib
# (apt) - it's built for the host ABI, not Cosmopolitan's.
set -euo pipefail

ZLIB_VERSION="1.3.1"
ZLIB_URL="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
ZLIB_SHA256="9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"

source "$(dirname "$0")/common.sh"

WORK=/work/build/deps-src/zlib
log() { printf '\n--- [zlib] %s ---\n' "$*"; }

log "Downloading zlib ${ZLIB_VERSION}"
rm -rf "$WORK"
mkdir -p "$WORK/src"
cd "$WORK"
fetch "$ZLIB_URL" "${ZLIB_SHA256}" zlib.tar.gz
tar -xf zlib.tar.gz --strip-components=1 -C src

build_one_arch() {
  local arch="$1"
  local dir="$WORK/build-$arch"
  rm -rf "$dir"
  cp -r "$WORK/src" "$dir"
  cd "$dir"
  log "Building for $arch"
  CC="$COSMOCC/bin/${arch}-unknown-cosmo-cc" \
  AR="$COSMOCC/bin/${arch}-unknown-cosmo-ar" \
  RANLIB="$COSMOCC/bin/${arch}-linux-cosmo-ranlib" \
    ./configure --static
  make -j"$(nproc)" libz.a
}

build_one_arch x86_64
build_one_arch aarch64

log "Installing"
install_common_headers "$WORK/src/zlib.h" "$WORK/build-x86_64/zconf.h"
install_fat_static_lib libz.a "$WORK/build-x86_64" "$WORK/build-aarch64"

log "Done"
