#!/bin/bash
# Builds OpenSSL from source, once per cosmo architecture, for CPython's
# ssl module and OpenSSL-backed hashlib algorithms.
set -euo pipefail

OSSL_VERSION="3.4.0"
OSSL_URL="https://www.openssl.org/source/openssl-${OSSL_VERSION}.tar.gz"
OSSL_SHA256="e15dda82fe2fe8139dc2ac21a36d4ca01d5313c75f99f46c4e8a27709b7294bf"

source "$(dirname "$0")/common.sh"

WORK=/work/build/deps-src/openssl
log() { printf '\n--- [openssl] %s ---\n' "$*"; }

log "Downloading OpenSSL ${OSSL_VERSION}"
rm -rf "$WORK"
mkdir -p "$WORK/src"
cd "$WORK"
fetch "$OSSL_URL" "${OSSL_SHA256}" openssl.tar.gz
tar -xf openssl.tar.gz --strip-components=1 -C src
find src -exec touch -t 202001010000 {} +

build_one_arch() {
  local arch="$1"
  local target="$2"
  local dir="$WORK/build-$arch"
  rm -rf "$dir"
  cp -r "$WORK/src" "$dir"
  find "$dir" -exec touch -t 202001010000 {} +
  cd "$dir"
  log "Configuring for $arch"
  # no-asm: cosmocc's assembler/toolchain conventions don't match what
  #   OpenSSL's perl-generated per-platform asm expects; keep this simple
  #   and portable rather than chasing hand-tuned asm compatibility.
  # no-shared/no-dso: APE has no dynamic loader.
  # no-engine/no-dynamic-engine: engines are loaded as .so plugins, moot here.
  # no-tests, no-apps: we only need libcrypto/libssl, not the openssl CLI.
  # no-threads is NOT set - CPython's ssl module wants a thread-safe libcrypto.
  CC="$COSMOCC/bin/${arch}-unknown-cosmo-cc" \
  AR="$COSMOCC/bin/${arch}-unknown-cosmo-ar" \
  RANLIB="$COSMOCC/bin/${arch}-linux-cosmo-ranlib" \
    ./Configure "$target" \
      no-asm no-shared no-dso no-engine no-dynamic-engine \
      no-tests no-apps no-docs \
      --prefix=/usr/local --openssldir=/usr/local/ssl
  log "Building for $arch (this is the slowest dep - be patient)"
  make -j"$(nproc)" build_libs
}

build_one_arch x86_64 linux-x86_64
build_one_arch aarch64 linux-aarch64

log "Installing"
install_common_headers "$WORK/build-x86_64/include/openssl"
install_fat_static_lib libssl.a "$WORK/build-x86_64" "$WORK/build-aarch64"
install_fat_static_lib libcrypto.a "$WORK/build-x86_64" "$WORK/build-aarch64"

log "Done"
