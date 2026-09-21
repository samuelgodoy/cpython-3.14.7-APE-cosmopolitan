#!/bin/bash
# Fetches psycopg 3 (pure-Python package) and psycopg-c (its C accelerator,
# shipped by upstream as pre-generated Cython output) from PyPI, verifies
# them, and applies this project's patches from patches/psycopg-c/.
#
# Nothing is compiled here: CPython's build compiles psycopg-c's C files
# straight into python.com via Modules/Setup.local, and the pure-Python
# package is copied into the embedded stdlib. The sources are unpacked to
# /opt/sources so that build step can find them.
set -euo pipefail

PSYCOPG_VERSION="3.2.3"
PSYCOPG_URL="https://files.pythonhosted.org/packages/d1/ad/7ce016ae63e231575df0498d2395d15f005f05e32d3a2d439038e1bd0851/psycopg-${PSYCOPG_VERSION}.tar.gz"
PSYCOPG_SHA256="a5764f67c27bec8bfac85764d23c534af2c27b893550377e37ce59c12aac47a2"

PSYCOPG_C_URL="https://files.pythonhosted.org/packages/53/ba/74caf4eab78d95a173e65cb81507a589365aeafb1d9c84f374002b51dc53/psycopg_c-${PSYCOPG_VERSION}.tar.gz"
PSYCOPG_C_SHA256="06ae7db8eaec1a3845960fa7f997f4ccdb1a7a7ab8dc593a680bcc74e1359671"

source "$(dirname "$0")/common.sh"

DEST=/opt/sources
PATCHES=/opt/patches/psycopg-c
WORK=/tmp/deps-src/psycopg
log() { printf '\n--- [psycopg] %s ---\n' "$*"; }

rm -rf "$WORK"
mkdir -p "$WORK" "$DEST"
cd "$WORK"

log "Downloading psycopg ${PSYCOPG_VERSION}"
fetch "$PSYCOPG_URL" "${PSYCOPG_SHA256}" psycopg.tar.gz

log "Downloading psycopg-c ${PSYCOPG_VERSION}"
fetch "$PSYCOPG_C_URL" "${PSYCOPG_C_SHA256}" psycopg_c.tar.gz

rm -rf "$DEST/psycopg" "$DEST/psycopg-c"
mkdir -p "$DEST/psycopg" "$DEST/psycopg-c"
tar -xf psycopg.tar.gz --strip-components=1 -C "$DEST/psycopg"
tar -xf psycopg_c.tar.gz --strip-components=1 -C "$DEST/psycopg-c"

log "Applying patches/psycopg-c"
for p in "$PATCHES"/*.patch; do
  [ -e "$p" ] || continue
  echo "applying $(basename "$p")"
  patch -d "$DEST/psycopg-c" -p1 --forward --no-backup-if-mismatch < "$p"
done

rm -rf "$WORK"
