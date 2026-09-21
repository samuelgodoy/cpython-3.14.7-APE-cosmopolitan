#!/bin/bash
# Fetches the Cosmopolitan libc source files this project patches, at the
# exact release the toolchain was built from, and applies the patches from
# patches/cosmopolitan/.
#
# The patched files are not built here. CPython's build compiles them into
# python.com (as extra sources on the _cosmo line of Modules/Setup.local),
# where the static linker resolves their symbols ahead of the prebuilt
# libc.a members. See docs/PATCHES.md.
set -euo pipefail

COSMOPOLITAN_VERSION="4.0.2"
BASE_URL="https://raw.githubusercontent.com/jart/cosmopolitan/${COSMOPOLITAN_VERSION}"

# path inside the Cosmopolitan tree, and its sha256 at that release
FILES=(
  "libc/thread/sem_open.c 942d72f51fd18368b31ea5a9dec00ee02a7c53aee9cfc1352c552c598bfb558e"
)

source "$(dirname "$0")/common.sh"

DEST=/opt/sources/cosmopolitan
PATCHES=/opt/patches/cosmopolitan
log() { printf '\n--- [cosmopolitan] %s ---\n' "$*"; }

rm -rf "$DEST"
mkdir -p "$DEST"

for entry in "${FILES[@]}"; do
  read -r path sha <<<"$entry"
  log "Downloading ${path} @ ${COSMOPOLITAN_VERSION}"
  mkdir -p "$DEST/$(dirname "$path")"
  fetch "$BASE_URL/$path" "$sha" "$DEST/$path"
done

log "Applying patches/cosmopolitan"
for p in "$PATCHES"/*.patch; do
  [ -e "$p" ] || continue
  echo "applying $(basename "$p")"
  patch -d "$DEST" -p1 --forward --no-backup-if-mismatch < "$p"
done
