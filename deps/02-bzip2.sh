#!/bin/bash
# Builds bzip2 (libbz2) from source, once per cosmo architecture, for
# CPython's bz2 module. bzip2's own build system is a plain Makefile
# (no autoconf), so this is simpler than zlib/libffi.
set -euo pipefail

BZ2_VERSION="1.0.8"
BZ2_URL="https://sourceware.org/pub/bzip2/bzip2-${BZ2_VERSION}.tar.gz"
BZ2_SHA256="ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"

source "$(dirname "$0")/common.sh"

WORK=/work/build/deps-src/bzip2
log() { printf '\n--- [bzip2] %s ---\n' "$*"; }

log "Downloading bzip2 ${BZ2_VERSION}"
rm -rf "$WORK"
mkdir -p "$WORK/src"
cd "$WORK"
fetch "$BZ2_URL" "${BZ2_SHA256}" bzip2.tar.gz
tar -xf bzip2.tar.gz --strip-components=1 -C src

build_one_arch() {
  local arch="$1"
  local dir="$WORK/build-$arch"
  rm -rf "$dir"
  cp -r "$WORK/src" "$dir"
  cd "$dir"
  log "Building for $arch"
  make -j"$(nproc)" libbz2.a \
    CC="$COSMOCC/bin/${arch}-unknown-cosmo-cc" \
    AR="$COSMOCC/bin/${arch}-unknown-cosmo-ar" \
    RANLIB="$COSMOCC/bin/${arch}-linux-cosmo-ranlib"
}

build_one_arch x86_64
build_one_arch aarch64

log "Installing"
install_common_headers "$WORK/src/bzlib.h"
install_fat_static_lib libbz2.a "$WORK/build-x86_64" "$WORK/build-aarch64"

log "Done"
