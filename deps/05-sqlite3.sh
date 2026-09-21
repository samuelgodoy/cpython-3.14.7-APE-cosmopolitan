#!/bin/bash
# Builds SQLite (autoconf amalgamation) from source, once per cosmo
# architecture, for CPython's sqlite3 module.
set -euo pipefail

SQLITE_VERSION="3460100"
SQLITE_URL="https://www.sqlite.org/2024/sqlite-autoconf-${SQLITE_VERSION}.tar.gz"
SQLITE_SHA256="67d3fe6d268e6eaddcae3727fce58fcc8e9c53869bdd07a0c61e38ddf2965071"

source "$(dirname "$0")/common.sh"

WORK=/work/build/deps-src/sqlite3
log() { printf '\n--- [sqlite3] %s ---\n' "$*"; }

log "Downloading sqlite ${SQLITE_VERSION}"
rm -rf "$WORK"
mkdir -p "$WORK/src"
cd "$WORK"
fetch "$SQLITE_URL" "${SQLITE_SHA256}" sqlite.tar.gz
tar -xf sqlite.tar.gz --strip-components=1 -C src
# See deps/03-xz.sh for why: flatten mtimes to avoid spurious
# autotools regeneration during the build.
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
  CFLAGS="-DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_RTREE -DSQLITE_THREADSAFE=1" \
    ./configure --host="$host" --disable-shared --enable-static --disable-readline --disable-tcl
  make -j"$(nproc)" libsqlite3.la
}

HOST_X86_64=x86_64-pc-linux-gnu
HOST_AARCH64=aarch64-unknown-linux-gnu
build_one_arch x86_64 "$HOST_X86_64"
build_one_arch aarch64 "$HOST_AARCH64"

log "Installing"
install_common_headers "$WORK/build-x86_64/sqlite3.h"
install_fat_static_lib libsqlite3.a \
  "$WORK/build-x86_64/.libs" "$WORK/build-aarch64/.libs"

log "Done"
