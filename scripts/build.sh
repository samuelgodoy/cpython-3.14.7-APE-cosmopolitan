#!/bin/bash
# Entry point of the builder container (`docker compose run --rm build`).
#
# 1. Clones CPython at $CPYTHON_REF and verifies it is exactly
#    $CPYTHON_COMMIT, into a Docker volume that is wiped every run.
# 2. Applies patches/cpython/*.patch in order and commits them with a fixed
#    author and date, so the version string is the same on every build.
# 3. Hands off to configure-and-make.sh, which builds the fat APE binary,
#    tests it, and publishes it to .bin/.
#
# Third-party C libraries, the Cosmopolitan toolchain and the other
# downloaded sources are already in the image (docker/Dockerfile, deps/).
set -euo pipefail

: "${CPYTHON_REPO:?set in docker-compose.yml}"
: "${CPYTHON_REF:?set in docker-compose.yml}"
: "${CPYTHON_COMMIT:?set in docker-compose.yml}"
export CPYTHON_REF CPYTHON_COMMIT

SRC_DIR=/work/src/cpython
BUILD_DIR=/work/build/cpython
PATCH_DIR=/work/patches/cpython
OUT_DIR=/work/.bin
LOG_DIR=/work/logs

log() { printf '\n=== %s ===\n' "$*"; }

# Prove the toolchain can actually run before spending minutes finding
# out it can't. On Docker Desktop for Windows, WSLInterop re-registers
# itself (on WSL/Docker restart, and seemingly on its own) and hijacks the
# APE's MZ header, so cosmocc cannot execute. The symptom points squarely
# at the wrong thing - zlib's configure reports "Compiler error reporting
# is too harsh", and CPython's reports "C compiler cannot create
# executables" - which sends you debugging compiler flags. See
# docs/BUILD.md, "A note on WSLInterop".
if ! /opt/cosmocc/bin/cosmocc --version >/dev/null 2>&1; then
  echo "error: cosmocc cannot execute in this container." >&2
  echo "       Nothing is wrong with the compiler or its flags - on Docker" >&2
  echo "       Desktop/WSL2 this is WSLInterop intercepting APE binaries." >&2
  echo "       Fix it from PowerShell on the host, then re-run:" >&2
  echo "         wsl -d docker-desktop -u root -- sh -c \\" >&2
  echo "           \"echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop\"" >&2
  exit 2
fi

log "Fetching CPython ${CPYTHON_REF}"
rm -rf "$SRC_DIR"
mkdir -p "$(dirname "$SRC_DIR")"
git clone --quiet --depth 1 --branch "$CPYTHON_REF" "$CPYTHON_REPO" "$SRC_DIR"
cd "$SRC_DIR"

# A tag can be moved; the commit it pointed to when this build was pinned
# cannot. Refuse to build anything else.
actual="$(git rev-parse HEAD)"
if [ "$actual" != "$CPYTHON_COMMIT" ]; then
  echo "error: ${CPYTHON_REF} resolved to ${actual}, expected ${CPYTHON_COMMIT}." >&2
  echo "       The upstream tag changed; refusing to build unverified source." >&2
  exit 1
fi
echo "verified ${CPYTHON_REF} = ${actual}"

# Reproducibility: every timestamp that reaches the binary derives from the
# upstream commit time - the patch commit below, GCC's __DATE__/__TIME__
# (GCC honours SOURCE_DATE_EPOCH), and the mtimes of the embedded zip.
SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
export SOURCE_DATE_EPOCH
echo "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}"

log "Applying ${PATCH_DIR}"
shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
  echo "error: no patches found in ${PATCH_DIR}" >&2
  exit 1
fi
for p in "${patches[@]}"; do
  echo "applying $(basename "$p")"
  git apply "$p"
done

# Commit so `git describe` (which CPython uses to stamp sys.version) reports
# v3.14.7-1-g<hash> instead of "-dirty". Fixed identity and dates make that
# hash depend only on the patches. This commit exists only in the
# throwaway clone.
git add -A
GIT_AUTHOR_NAME="cpython-cosmo" GIT_AUTHOR_EMAIL="build@cpython-cosmo.invalid" \
GIT_COMMITTER_NAME="cpython-cosmo" GIT_COMMITTER_EMAIL="build@cpython-cosmo.invalid" \
GIT_AUTHOR_DATE="@${SOURCE_DATE_EPOCH} +0000" GIT_COMMITTER_DATE="@${SOURCE_DATE_EPOCH} +0000" \
  git commit --quiet --no-gpg-sign -m "Apply cpython-cosmo patches on top of ${CPYTHON_REF}"
echo "patched tree: $(git rev-parse HEAD)"

log "Preparing build tree"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

if [ ! -e /opt/cosmocc/.deps-built ]; then
  echo "error: this image has no prebuilt dependencies - run 'docker compose build'." >&2
  exit 1
fi

exec "$(dirname "$0")/configure-and-make.sh" "$SRC_DIR" "$BUILD_DIR" "$OUT_DIR" "$LOG_DIR"
