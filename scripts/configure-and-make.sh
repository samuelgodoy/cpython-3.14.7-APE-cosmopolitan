#!/bin/bash
# Configures and builds CPython with the cosmocc toolchain.
# Called by build.sh with: SRC_DIR BUILD_DIR OUT_DIR LOG_DIR
#
#   SRC_DIR   patched CPython checkout (Docker volume)
#   BUILD_DIR out-of-tree build, staging, the assembled binary (Docker volume)
#   OUT_DIR   where the finished binary is published - it receives exactly
#             one file, python-<version>-release.com, and only after the
#             test suite has passed against it (host .bin/)
#   LOG_DIR   build transcripts, BUILD-INFO.txt, SHA256SUMS (host logs/)
set -euo pipefail

SRC_DIR="$1"
BUILD_DIR="$2"
OUT_DIR="$3"
LOG_DIR="$4"
mkdir -p "$LOG_DIR"

# Sources fetched and patched at image build time (see deps/08-*, 09-*).
SOURCES=/opt/sources
MODULES=/work/modules

COSMOCC_BIN=/opt/cosmocc/bin
export CC="$COSMOCC_BIN/cosmocc"
export CXX="$COSMOCC_BIN/cosmoc++"
export AR="$COSMOCC_BIN/cosmoar"
export RANLIB="$COSMOCC_BIN/x86_64-linux-cosmo-ranlib"
export READELF="$COSMOCC_BIN/x86_64-linux-cosmo-readelf"

# Every third-party C library (zlib, libffi, sqlite3, openssl, ...) is built
# from source with cosmocc by deps/*.sh, which install straight into
# the toolchain's own include/lib dirs - cosmocc finds them with no extra
# flags here, same as it finds its own libc. Never pulled from apt.

log() { printf '\n=== %s ===\n' "$*"; }

cd "$BUILD_DIR"


# We install to --prefix=/zip/usr/local. That path is never used on real
# disk; it's baked into the binary as CPython's compiled-in fallback
# prefix (see Modules/getpath.py). At runtime, Cosmopolitan Libc's zipos
# feature transparently maps the "/zip/..." prefix onto a zip archive
# appended to the running executable itself, so python finds its stdlib
# (encodings, os.py, etc.) inside its own single-file .com no matter
# which OS or directory it's run from.
PY_PREFIX=/zip/usr/local

log "Running CPython configure with cosmocc (fully static, no dlopen)"
MODULE_BUILDTYPE=static \
"$SRC_DIR"/configure \
    --prefix="$PY_PREFIX" \
    --disable-shared \
    --disable-test-modules \
    --without-pymalloc \
    --without-readline \
    --with-openssl=/opt/cosmocc \
    CC="$CC" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    2>&1 | tee "$LOG_DIR/configure.log"

log "Forcing HAVE_BROKEN_SEM_GETVALUE (see docs/BUILD.md - multiprocessing.Lock/Queue)"
# configure's own "broken sem_getvalue" detection (configure.ac, "Multi-
# processing check for broken sem_getvalue") only catches sem_getvalue()
# returning an outright error. Cosmopolitan Libc's sem_getvalue() instead
# "succeeds" while writing garbage into the output count - a failure mode
# that probe doesn't check for, so configure wrongly concludes it's fine.
# The practical symptom: multiprocessing.Lock()/Semaphore().release() call
# sem_getvalue() to sanity-check against maxvalue before posting, and with
# garbage back, get a spurious "semaphore or lock released too many times"
# on every single release. CPython already ships a HAVE_BROKEN_SEM_GETVALUE
# code path for exactly this class of bug (real platforms have hit it
# before, e.g. historically on Darwin) that avoids trusting the returned
# count at all - we just need to force it on, since configure's test can't
# detect this particular flavor of "broken" on its own.
echo '#define HAVE_BROKEN_SEM_GETVALUE 1' >> pyconfig.h

log "Raising the default thread stack size (see docs/BUILD.md - threaded imports)"
# Cosmopolitan's default pthread stack is far smaller than glibc's 8MB,
# and CPython's PEG parser recurses on it. Importing a large module from
# a non-main thread then dies with:
#
#   MemoryError: Parser stack overflowed - Python source too complex to parse
#
# Reproduced with `import asyncio` inside a threading.Thread: it fails at
# the default size and succeeds verbatim after threading.stack_size(8MB).
# It bites whenever the source has to be parsed at all - lazy imports
# inside worker threads, and anything importing through
# multiprocessing.managers' accepter thread.
#
# THREAD_STACK_SIZE is CPython's own knob for exactly this (see
# Python/thread_pthread.h); configure leaves it undefined because on a
# normal POSIX platform the OS default is already generous. 8MB matches
# what glibc gives the main thread, so this restores the assumption the
# stdlib is written against rather than inventing a new one.
echo '#define THREAD_STACK_SIZE 0x800000' >> pyconfig.h

log "Registering modules/ as static built-in modules"
# Modules/Setup.local is CPython's own supported mechanism for adding
# extra built-in modules without touching Modules/config.c by hand (see
# docs/BUILD.md "Adding a package with a C extension"). It's only auto-created
# empty if missing, so writing it ourselves before the first `make` (which
# is what generates Makefile/config.c from it) is how we hook in.
mkdir -p Modules
{
  echo "*static*"
  # The patched Cosmopolitan sem_open.c rides along with _cosmo: makesetup
  # compiles every source listed on a line into python.com, and an object
  # linked in directly beats the same symbol in libc.a. See docs/PATCHES.md.
  echo "_cosmo $MODULES/cosmo/_cosmo.c $SOURCES/cosmopolitan/libc/thread/sem_open.c"
  echo "_cosmocrypto $MODULES/cosmocrypto/_cosmocrypto.c -lcrypto"
  # Module names here must match the PyInit_<name> Cython actually
  # generated (pq.c -> PyInit_pq, _psycopg.c -> PyInit__psycopg) - makesetup
  # derives the extern declaration from this exact name. See
  # modules/psycopg/psycopg_c/__init__.py for how "pq"/"_psycopg"
  # (unavoidably flat - Setup module names can't contain dots) get
  # re-exposed as psycopg_c.pq / psycopg_c._psycopg like upstream expects.
  # -lpgcommon appears twice: static archives only pull in members that
  # resolve a symbol already needed at the point they're processed on the
  # link line, and libpq.a -> libpgcommon.a -> (nothing further) isn't
  # perfectly one-directional here (a couple of libpq.a's own object files
  # reference libpgcommon symbols that only get demanded after the first
  # -lpgcommon pass). Cheaper than teaching Setup's simple parser
  # --start-group/--end-group.
  # psycopg-c's C sources come from its PyPI sdist (deps/08-psycopg.sh);
  # encoding_shim.c is this project's.
  echo "pq $SOURCES/psycopg-c/psycopg_c/pq.c $MODULES/psycopg/encoding_shim.c -lpq -lpgcommon -lpgport"
  echo "_psycopg $SOURCES/psycopg-c/psycopg_c/_psycopg.c $SOURCES/psycopg-c/psycopg_c/types/numutils.c -lpq -lpgcommon -lpgport"
} > Modules/Setup.local

log "Pinning sys.version's git tag before it can go '-dirty'"
# Modules/getbuildinfo.c's build rule shells out LIVE to `git describe --all
# --always --dirty` (configure.ac's GITTAG) every single time it (re)links -
# not just once at configure time. CPython's own build regenerates several
# files that are tracked in git (Python/frozen_modules/*.h,
# Python/deepfreeze/deepfreeze.c, etc.) via .PHONY "regen-frozen"/
# "regen-importlib" Makefile targets that unconditionally rerun on *every*
# `make` invocation - so even committing right after such a regen and
# rerunning `make` again just triggers another regen first, dirtying the
# tree again before getbuildinfo.o can compile against a clean state. No
# number of "commit, then rebuild" passes converges.
# Fix: capture `git describe`/rev-parse/name-rev's output *now*, right after
# build.sh's post-patch commit (SRC_DIR is guaranteed clean at this exact
# point - nothing has run `make` yet), and pass it to `make` as literal
# command-line variable overrides for GITVERSION/GITTAG/GITBRANCH. Make
# command-line variables take precedence over the Makefile's own `=`
# assignments, so the live `git describe --dirty` shell command in the
# recipe never actually runs - `make` substitutes our fixed strings instead,
# regardless of how many times regen-frozen dirties the tree afterward.
GIT_VERSION="$(cd "$SRC_DIR" && LC_ALL=C git rev-parse --short HEAD)"
GIT_TAG="$(cd "$SRC_DIR" && LC_ALL=C git describe --all --always --dirty)"
GIT_BRANCH="$(cd "$SRC_DIR" && LC_ALL=C git name-rev --name-only HEAD)"
echo "GITVERSION=$GIT_VERSION GITTAG=$GIT_TAG GITBRANCH=$GIT_BRANCH"

log "Building (this takes a while)"
make -j"$(nproc)" \
    GITVERSION="echo $GIT_VERSION" \
    GITTAG="echo $GIT_TAG" \
    GITBRANCH="echo $GIT_BRANCH" \
    2>&1 | tee "$LOG_DIR/make.log"

log "Installing to staging root"
STAGE=/work/build/stage
rm -rf "$STAGE"
mkdir -p "$STAGE"
make install DESTDIR="$STAGE" \
    GITVERSION="echo $GIT_VERSION" \
    GITTAG="echo $GIT_TAG" \
    GITBRANCH="echo $GIT_BRANCH" \
    2>&1 | tee "$LOG_DIR/install.log"

log "Trimming stdlib fat (tests, caches, dead weight) before embedding"
STDLIB="$STAGE$PY_PREFIX/lib/python3.14"
rm -rf "$STDLIB"/test "$STDLIB"/idlelib "$STDLIB"/turtledemo \
       "$STDLIB"/turtle.py "$STDLIB"/tkinter \
       "$STDLIB"/lib2to3/tests "$STDLIB"/ctypes/test \
       "$STDLIB"/unittest/test
find "$STDLIB" -type d -name '__pycache__' -prune -exec rm -rf {} +
# tkinter/idlelib/turtledemo need Tcl/Tk, which we never build (see docs/BUILD.md
# "Explicitly out of scope" - not pure-C/pure-Python, and low value for a
# CLI-oriented portable binary) - `import tkinter` fails regardless, so
# shipping these is pure dead weight, not a feature we're removing.

# libpython3.14.a (~80MB!) is only useful for compiling new C extensions
# against this install - structurally impossible here anyway (see "pip and
# compiled packages"), so it's pure waste. Find it wherever `make install`
# put it rather than assuming a fixed path.
find "$STAGE$PY_PREFIX" -name 'libpython*.a' -delete
rm -rf "$STAGE$PY_PREFIX"/share

# `make install` also installs a full copy of the interpreter binary itself
# into bin/python3.14 (and a bin/python3 symlink) - ~36MB, and a complete,
# useless duplicate: the thing actually running IS python.com, nothing
# reads bin/python3.14 out of the embedded zip at runtime (sys.executable
# always resolves to the real on-disk python.com, verified). Small
# supporting scripts (pip3, pydoc3, ...) stay - they're tiny text files.
rm -f "$STAGE$PY_PREFIX"/bin/python3.14 "$STAGE$PY_PREFIX"/bin/python3

log "Fetching Mozilla CA bundle for ssl.create_default_context() fallback"
# This build's OpenSSL has no meaningful --openssldir on the machine that
# actually runs python.com (there wasn't one at build time either, inside
# the container). patches/cpython/0007 makes ssl.create_default_context() load
# this bundle as a fallback so https:// actually works out of the box.
curl -fsSL -o "$STDLIB/_cosmo_cacert.pem" "https://curl.se/ca/cacert.pem"

log "Embedding cosmocrypto (pure-Python wrapper over the built-in _cosmocrypto)"
cp "$MODULES/cosmocrypto/cosmocrypto.py" "$STDLIB/cosmocrypto.py"

log "Embedding cosmo (pure-Python wrapper over the built-in _cosmo)"
cp "$MODULES/cosmo/cosmo.py" "$STDLIB/cosmo.py"

log "Embedding psycopg (pure-Python layer + psycopg_c shim over pq/_psycopg builtins)"
cp -r "$SOURCES/psycopg/psycopg" "$STDLIB/psycopg"
# Only psycopg_c/__init__.py (the shim) is needed at runtime - _psycopg.c,
# pq.c and types/numutils.c (~6.5MB combined) were already compiled into
# this python.com's own libpython3.14.a at build time; shipping the .c
# source again inside the zip would just be dead weight.
mkdir -p "$STDLIB/psycopg_c"
cp "$MODULES/psycopg/psycopg_c/__init__.py" "$STDLIB/psycopg_c/"
find "$STDLIB/psycopg" "$STDLIB/psycopg_c" -type d -name '__pycache__' -prune -exec rm -rf {} +

log "Embedding tzdata for zoneinfo (this build has no system IANA tz database)"
# stdlib zoneinfo looks for the IANA database at a real OS path
# (/usr/share/zoneinfo) or via the pure-Python "tzdata" package as a
# fallback - we have neither by default. The pip package is just data
# files (no C extension), so it's a plain unzip into site-packages.
TZDATA_WHL=/tmp/tzdata.whl
curl -fsSL -o "$TZDATA_WHL" \
  "https://files.pythonhosted.org/packages/f9/bc/8737e8d54cf51106118039b83f485a4783112fab49ea9d044b234978a46e/tzdata-2026.4-py2.py3-none-any.whl"
echo "c2169a8b0a7a5e9674da5a135ccdfb2b3e671b333ed9fed17b41f73c34476e81  $TZDATA_WHL" | sha256sum -c -
unzip -q -o "$TZDATA_WHL" 'tzdata/*' -d "$STDLIB/site-packages"
rm -f "$TZDATA_WHL"

log "Collecting base binary"
# Assembled inside the build volume and only copied to OUT_DIR at the very
# end, after the tests pass - so .bin/ never holds a half-built or broken
# binary. Named for what it is, e.g. python-3.14.7-release.com.
ARTIFACT="python-${CPYTHON_REF#v}-release.com"
ASSEMBLY="$BUILD_DIR/out"
BINARY="$ASSEMBLY/$ARTIFACT"
rm -rf "$ASSEMBLY"
mkdir -p "$ASSEMBLY"
cp -v python.com "$BINARY" 2>/dev/null || cp -v python "$BINARY"

log "Byte-compiling the stdlib (legacy layout, for zipimport)"
# Without this the zip holds only .py, so EVERY import parses source at
# runtime - zipimport can't write a cache back into a read-only zip, so
# it never amortizes. Two real consequences, not just slow startup:
#
#  1. Importing inside a thread can die with "MemoryError: Parser stack
#     overflowed - Python source too complex to parse". Threads get a much
#     smaller stack than the main thread, and CPython's parser recurses on
#     it; some stdlib modules (email._policybase -> email.header, reached
#     from multiprocessing.managers) are complex enough to blow it. With a
#     .pyc there is no parse, so the recursion never happens. Found by the
#     CPython test-suite audit (test_multiprocessing_fork).
#  2. Interpreter startup was ~4x slower on Windows than Linux.
#
# Use the DEFAULT __pycache__ layout, not compileall's legacy -b layout.
# The distinction matters and is easy to get backwards: /zip/... is not
# served by zipimport here. Cosmopolitan's zipos presents it as a real
# filesystem, so CPython's ordinary FileFinder/SourceFileLoader handles
# these imports - confirmed at runtime, where email.header reports
# SourceFileLoader and a __cached__ of
# /zip/.../email/__pycache__/header.cpython-314.pyc. That loader only ever
# looks in __pycache__/, so legacy foo.pyc beside foo.py is invisible to
# it (a -b build shipped 1067 unused .pyc and changed nothing).
# -d makes embedded code objects report /zip/... paths in tracebacks.
# Uses the interpreter we just built, so the bytecode magic matches.
# --invalidation-mode unchecked-hash is load-bearing, not a tweak. A
# default (timestamp) .pyc records the source's mtime and size, and the
# importer discards the bytecode unless they still match. Zip entries
# store time with DOS granularity (2 seconds, no timezone), so the mtime
# zipimport computes for the .py never matches what compileall recorded -
# every .pyc is judged stale and the source is parsed anyway. The bytecode
# ships, costs megabytes, and does nothing. PEP 552's unchecked-hash mode
# drops the validation entirely, which is exactly right for bytecode
# frozen into a read-only artifact alongside the source it was built from.
echo "compiling $STDLIB"
./python -E -Wi -m compileall -f -q \
    --invalidation-mode unchecked-hash \
    -d "$PY_PREFIX/lib/python3.14" \
    "$STDLIB"
compileall_rc=$?

# Verify rather than trust. An earlier version of this step piped through
# `tail` with `|| true`, which turned "wrote nothing at all" into a silent
# no-op that shipped a .pyc-less binary anyway - the exact failure mode
# this check exists to make impossible.
pyc_count="$(find "$STDLIB" -path '*/__pycache__/*' -name '*.pyc' | wc -l)"
echo "compileall exit=$compileall_rc, __pycache__ .pyc files: $pyc_count"
if [ ! -f "$STDLIB/email/__pycache__/header.cpython-314.pyc" ] || \
   [ "$pyc_count" -lt 500 ]; then
  echo "error: byte-compilation did not produce the expected __pycache__ files" >&2
  echo "       (only $pyc_count found). Without them every import parses source" >&2
  echo "       at runtime, which is slow and breaks importing from threads." >&2
  exit 1
fi
# Note: these __pycache__ directories must survive into the zip - an
# earlier version of this script deleted them here to save space, which
# is exactly what made the stdlib source-only in the first place.

log "Embedding stdlib into the APE zip store (/zip/... at runtime)"
# Entries are stored path-for-path as they'll be addressed at runtime
# under /zip/, e.g. usr/local/lib/python3.14/os.py -> /zip/usr/local/lib/python3.14/os.py
# Both .py and .pyc ship: zipimport prefers the .pyc, while keeping the
# source means tracebacks still show real lines and inspect.getsource()
# works - worth the extra compressed megabytes in a developer-facing tool.
#
# Reproducibility: every entry gets the same timestamp (SOURCE_DATE_EPOCH,
# the upstream commit time - see build.sh) and entries are added in a fixed,
# locale-independent order, so the zip is byte-identical across builds.
# -X drops the extra fields (uid/gid, extended timestamps) that would vary.
(
  cd "$STAGE/zip"
  find . -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
  find . -mindepth 1 | LC_ALL=C sort | zip -q -X -@ "$BINARY"
)

log "Verifying the fat APE binary"
file "$BINARY" || true
ls -lh "$BINARY"

log "Writing release metadata"
# Answers "what exactly is inside this binary?" without needing the build
# log. Dep versions/hashes are read back out of deps/*.sh so this
# can't drift from what was actually built.
BUILD_INFO="$LOG_DIR/BUILD-INFO.txt"
{
  echo "cpython-cosmo build information"
  echo "built:          $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
  echo "python:         $("$BINARY" -c 'import sys; print(sys.version.replace(chr(10), " "))')"
  echo "cpython ref:    ${CPYTHON_REF:-v3.14.7}"
  echo "cpython commit: ${CPYTHON_COMMIT:-?} (upstream)"
  echo "  patched tree: $(cd "$SRC_DIR" && git rev-parse HEAD)"
  echo "source date:    ${SOURCE_DATE_EPOCH} ($(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ'))"
  # The toolchain ships no release-version file (the "4.0.2" in the
  # download URL only exists in docs/BUILD.md), so report what it says about
  # itself plus a hash of the driver, which pins it exactly.
  echo "cosmocc:        $("$COSMOCC_BIN/cosmocc" --version 2>/dev/null | head -1)"
  echo "  driver sha256: $(sha256sum "$COSMOCC_BIN/cosmocc" | cut -d' ' -f1)"
  echo "size:           $(stat -c %s "$BINARY") bytes"
  echo "sha256:         $(sha256sum "$BINARY" | cut -d' ' -f1)"
  echo
  for pset in cpython psycopg-c cosmopolitan; do
    echo "patches/$pset:"
    for p in /work/patches/$pset/*.patch /opt/patches/$pset/*.patch; do
      [ -e "$p" ] || continue
      echo "  $(sha256sum "$p" | cut -c1-12)  $(basename "$p")"
    done
  done
  echo
  echo "third-party sources (downloaded, sha256-pinned; see deps/):"
  for d in /opt/deps/*.sh; do
    [ -e "$d" ] || continue
    case "$(basename "$d")" in common.sh) continue ;; esac
    ver="$(grep -m1 -oE '^[A-Z0-9_]+_VERSION="[^"]+"' "$d" | cut -d'"' -f2)"
    echo "  $(basename "$d" .sh)${ver:+ $ver}"
  done
  echo
  echo "embedded data:"
  echo "  Mozilla CA bundle - fetched fresh at build time (curl.se/ca/cacert.pem),"
  echo "    deliberately never pinned, so it is always current as of 'built' above"
  echo "  tzdata - pinned by sha256 in scripts/configure-and-make.sh"
} > "$BUILD_INFO"
cat "$BUILD_INFO"

(cd "$ASSEMBLY" && sha256sum "$ARTIFACT") > "$LOG_DIR/SHA256SUMS"

log "Running the test suite against the binary just built"
# A build that produces a broken interpreter should fail loudly here, not
# silently ship. Runs the Linux half only - the same suite has to be run
# on a Windows host separately (scripts/run-tests.sh), since that is a
# different OS personality of the very same file.
TEST_LOG="$LOG_DIR/test-build-linux-amd64.log" \
  /work/scripts/run-tests.sh "$BINARY"

log "Publishing $ARTIFACT to .bin/"
# Only reached when the tests passed (set -e aborts otherwise). OUT_DIR is
# kept to exactly one file: the binary.
mkdir -p "$OUT_DIR"
find "$OUT_DIR" -mindepth 1 -maxdepth 1 -type f -delete
cp "$BINARY" "$OUT_DIR/$ARTIFACT"
ls -l "$OUT_DIR"

log "Done"
