#!/bin/bash
# Builds xz/liblzma from source, once per cosmo architecture, for CPython's
# lzma module.
set -euo pipefail

XZ_VERSION="5.6.4"
XZ_URL="https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz"
XZ_SHA256="269e3f2e512cbd3314849982014dc199a7b2148cf5c91cedc6db629acdf5e09b"

source "$(dirname "$0")/common.sh"

WORK=/work/build/deps-src/xz
log() { printf '\n--- [xz] %s ---\n' "$*"; }

log "Downloading xz ${XZ_VERSION}"
rm -rf "$WORK"
mkdir -p "$WORK/src"
cd "$WORK"
fetch "$XZ_URL" "${XZ_SHA256}" xz.tar.gz
tar -xf xz.tar.gz --strip-components=1 -C src
# Tarball extraction can leave mtimes out of order, tricking automake's
# generated Makefiles into thinking configure.ac/Makefile.am changed and
# need regenerating with a specific aclocal/automake version we don't have
# installed. Flatten every mtime to the same instant so make never sees
# anything as "newer" and trusts the shipped, already-generated build
# files as-is.
find src -exec touch -t 202001010000 {} +

build_one_arch() {
  local arch="$1"
  local host="$2"
  local dir="$WORK/build-$arch"
  rm -rf "$dir"
  cp -r "$WORK/src" "$dir"
  find "$dir" -exec touch -t 202001010000 {} +
  cd "$dir"
  log "Building for $arch"
  CC="$COSMOCC/bin/${arch}-unknown-cosmo-cc" \
  AR="$COSMOCC/bin/${arch}-unknown-cosmo-ar" \
  RANLIB="$COSMOCC/bin/${arch}-linux-cosmo-ranlib" \
    ./configure --host="$host" --disable-shared --enable-static \
      --disable-doc --disable-scripts --disable-xz --disable-xzdec \
      --disable-lzmadec --disable-lzmainfo --disable-nls
  make -j"$(nproc)" -C src/liblzma
}

HOST_X86_64=x86_64-pc-linux-gnu
HOST_AARCH64=aarch64-unknown-linux-gnu
build_one_arch x86_64 "$HOST_X86_64"
build_one_arch aarch64 "$HOST_AARCH64"

log "Installing"
install_common_headers "$WORK/src/src/liblzma/api/lzma.h" "$WORK/src/src/liblzma/api/lzma"
install_fat_static_lib liblzma.a \
  "$WORK/build-x86_64/src/liblzma/.libs" "$WORK/build-aarch64/src/liblzma/.libs"

log "Done"
