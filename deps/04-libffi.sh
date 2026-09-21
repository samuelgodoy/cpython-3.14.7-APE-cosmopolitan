#!/bin/bash
# Builds libffi from source, once per cosmo architecture, for CPython's
# ctypes module. See deps/common.sh for why per-arch + install into
# the toolchain's own dirs is the right approach for cosmocc.
set -euo pipefail

FFI_VERSION="3.4.6"
FFI_URL="https://github.com/libffi/libffi/releases/download/v${FFI_VERSION}/libffi-${FFI_VERSION}.tar.gz"
FFI_SHA256="b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e"

source "$(dirname "$0")/common.sh"

WORK=/work/build/deps-src/libffi
log() { printf '\n--- [libffi] %s ---\n' "$*"; }

log "Downloading libffi ${FFI_VERSION}"
rm -rf "$WORK"
mkdir -p "$WORK/src"
cd "$WORK"
fetch "$FFI_URL" "${FFI_SHA256}" libffi.tar.gz
tar -xf libffi.tar.gz --strip-components=1 -C src

build_one_arch() {
  local arch="$1"
  local host="$2"
  local dir="$WORK/build-$arch"
  rm -rf "$dir"
  cp -r "$WORK/src" "$dir"
  cd "$dir"
  log "Building for $arch"
  CC="$COSMOCC/bin/${arch}-unknown-cosmo-cc" \
  AR="$COSMOCC/bin/${arch}-unknown-cosmo-ar" \
  RANLIB="$COSMOCC/bin/${arch}-linux-cosmo-ranlib" \
    ./configure --host="$host" --disable-shared --enable-static --disable-docs \
      --disable-exec-static-tramp
  make -j"$(nproc)"
}

# libffi's configure needs an explicit --host triple to pick the right
# target-specific source files (it can't always infer this from a cross
# compiler wrapper name alone). Note: libffi's build drops generated
# headers/libs into a subdir named after --host, not the build dir root.
HOST_X86_64=x86_64-pc-linux-gnu
HOST_AARCH64=aarch64-unknown-linux-gnu
build_one_arch x86_64 "$HOST_X86_64"
build_one_arch aarch64 "$HOST_AARCH64"

OUT_X86_64="$WORK/build-x86_64/$HOST_X86_64"
OUT_AARCH64="$WORK/build-aarch64/$HOST_AARCH64"

log "Installing"
# ffi.h is arch-independent, safe to share. ffitarget.h is NOT - it encodes
# per-arch ABI details (struct layouts, register counts, trampoline sizes).
# Since cosmocc's fat build compiles the same source once per real arch
# compiler (each defining __x86_64__ / __aarch64__ as appropriate), we ship
# both variants under arch-tagged names plus a tiny dispatcher ffitarget.h
# that #includes the right one - so a single shared include dir stays correct
# for both compilation passes.
install_common_headers "$OUT_X86_64/include/ffi.h"
mkdir -p "$COSMOCC/include"
cp -v "$OUT_X86_64/include/ffitarget.h" "$COSMOCC/include/ffitarget_x86_64.h"
cp -v "$OUT_AARCH64/include/ffitarget.h" "$COSMOCC/include/ffitarget_aarch64.h"
cat > "$COSMOCC/include/ffitarget.h" <<'EOF'
/* Dispatcher for cosmocc's fat (x86_64 + aarch64) builds - see
 * deps/04-libffi.sh. ffitarget.h is architecture-specific; each of
 * cosmocc's per-arch compiler passes defines the matching macro. */
#if defined(__x86_64__)
#include "ffitarget_x86_64.h"
#elif defined(__aarch64__)
#include "ffitarget_aarch64.h"
#else
#error "libffi: unsupported architecture for ffitarget.h"
#endif
EOF

install_fat_static_lib libffi.a \
  "$OUT_X86_64/.libs" "$OUT_AARCH64/.libs"

log "Done"
