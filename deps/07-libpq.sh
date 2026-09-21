#!/bin/bash
# Builds libpq (PostgreSQL client library) from source, once per cosmo
# architecture. This alone is real, verified progress toward psycopg3 (a
# future built-in-module integration, see docs/BUILD.md) - psycopg's C
# accelerator is a normal CPython extension (unlike pycryptodome, which
# turned out to be structurally incompatible with static linking - it
# dlopen()s its own compiled pieces at runtime, which APE can't do).
#
# We only need libpq itself, not the full PostgreSQL server - build just
# the client library subtree.
set -euo pipefail

PG_VERSION="17.2"
PG_URL="https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz"
PG_SHA256="51d8cdd6a5220fa8c0a3b12f2d0eeb50fcf5e0bdb7b37904a9cdff5cf1e61c36"

source "$(dirname "$0")/common.sh"

WORK=/work/build/deps-src/libpq
log() { printf '\n--- [libpq] %s ---\n' "$*"; }

log "Downloading PostgreSQL ${PG_VERSION} (building libpq only)"
rm -rf "$WORK"
mkdir -p "$WORK/src"
cd "$WORK"
fetch "$PG_URL" "${PG_SHA256}" pg.tar.gz
tar -xf pg.tar.gz --strip-components=1 -C src

# Cosmopolitan Libc resolves signal numbers like SIGUSR2/SIGHUP/SIGTERM/
# SIGALRM at *runtime* (the same binary can run on OSes with different
# signal numbering), so they aren't preprocessor integer constants the way
# glibc's are. postgres's compile-time sanity check for this doesn't build
# as a result ("expression in static assertion is not constant") - it's a
# sanity check, not behavior, so drop just those 4 lines rather than patch
# around it.
sed -i '/StaticAssertDecl(SIG.* < PG_NSIG/d' src/src/port/pqsignal.c

find src -exec touch -t 202001010000 {} +

build_one_arch() {
  local arch="$1"
  local host="$2"
  local dir="$WORK/build-$arch"
  rm -rf "$dir"
  cp -r "$WORK/src" "$dir"
  find "$dir" -exec touch -t 202001010000 {} +
  cd "$dir"
  log "Configuring for $arch"
  # Unlike the fat `cosmocc` wrapper (used for the final CPython link),
  # the single-arch `${arch}-unknown-cosmo-cc` compiler doesn't
  # automatically search $COSMOCC/${arch}-linux-cosmo/lib for our
  # cosmocc-built deps. Every other dep here only ever compiles+archives
  # with this compiler (no link-time external-lib test); this is the
  # first one whose own configure does a real link test against one
  # (-lcrypto, for --with-ssl=openssl), so it's the first to need this
  # spelled out explicitly.
  CC="$COSMOCC/bin/${arch}-unknown-cosmo-cc" \
  AR="$COSMOCC/bin/${arch}-unknown-cosmo-ar" \
  RANLIB="$COSMOCC/bin/${arch}-linux-cosmo-ranlib" \
  LDFLAGS="-L$COSMOCC/${arch}-linux-cosmo/lib" \
    ./configure --host="$host" --without-readline --without-zlib \
      --with-ssl=openssl --without-icu --without-ldap --without-systemd

  # configure auto-adds -Werror=vla (cosmocc accepts the flag, so its
  # "does the compiler support this warning" probe says yes, and it gets
  # promoted to an error). A couple of src/common files use a VLA in a way
  # upstream considers fine on every compiler they actually test against -
  # not something we should "fix" in vendored postgres code. Strip just
  # that one -Werror promotion post-configure rather than fight the
  # detection.
  sed -i 's/-Werror=vla//' src/Makefile.global

  log "Building for $arch (libpq, letting its own Makefile pull in what it needs)"
  # Build libpq directly rather than src/common and src/port as separate
  # manual steps first - libpq's own Makefile already declares the right
  # prerequisites (including triggering generated-header creation in
  # src/backend/utils, e.g. errcodes.h) through postgres's submake
  # machinery. Building src/common in isolation first was skipping that.
  #
  # Target libpq.a specifically (not the default `all`, which also builds
  # libpq.so.*): cosmocc correctly refuses `-shared` (APE has no dynamic
  # loader, same as every other dep here) and that's the ONLY thing that
  # fails - the static archive we actually want builds fine before that.
  make -j"$(nproc)" -C src/interfaces/libpq libpq.a
}

HOST_X86_64=x86_64-pc-linux-gnu
HOST_AARCH64=aarch64-unknown-linux-gnu
build_one_arch x86_64 "$HOST_X86_64"
build_one_arch aarch64 "$HOST_AARCH64"

log "Installing"
install_common_headers \
  "$WORK/build-x86_64/src/interfaces/libpq/libpq-fe.h" \
  "$WORK/build-x86_64/src/include/postgres_ext.h" \
  "$WORK/build-x86_64/src/include/pg_config_ext.h"

# pg_config.h differs per arch (SIMD/CRC intrinsic availability, CFLAGS
# echoed back into the header, etc - see deps/04-libffi.sh for why we
# handle this class of header with a tiny arch-dispatch wrapper instead of
# sharing one copy).
cp -v "$WORK/build-x86_64/src/include/pg_config.h" "$COSMOCC/include/pg_config_x86_64.h"
cp -v "$WORK/build-aarch64/src/include/pg_config.h" "$COSMOCC/include/pg_config_aarch64.h"
cat > "$COSMOCC/include/pg_config.h" <<'EOF'
/* Dispatcher for cosmocc's fat (x86_64 + aarch64) builds - see
 * deps/07-libpq.sh. pg_config.h is architecture-specific. */
#if defined(__x86_64__)
#include "pg_config_x86_64.h"
#elif defined(__aarch64__)
#include "pg_config_aarch64.h"
#else
#error "libpq: unsupported architecture for pg_config.h"
#endif
EOF

install_fat_static_lib libpq.a \
  "$WORK/build-x86_64/src/interfaces/libpq" \
  "$WORK/build-aarch64/src/interfaces/libpq"

# libpq.a alone isn't enough to link a client against - it calls into
# libpgcommon.a (SCRAM auth, base64, hashing helpers) and libpgport.a
# (portability shims), matching libpq.pc's own "Libs.private: -lpgcommon
# -lpgport -lm". Both already got built as prerequisites of libpq.a above;
# just install them too.
install_fat_static_lib libpgcommon.a \
  "$WORK/build-x86_64/src/common" \
  "$WORK/build-aarch64/src/common"
install_fat_static_lib libpgport.a \
  "$WORK/build-x86_64/src/port" \
  "$WORK/build-aarch64/src/port"

log "Done"
