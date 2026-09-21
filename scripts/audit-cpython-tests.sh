#!/bin/bash
# Run a subset of CPython's OWN regression suite against the built binary.
#
#   docker compose run --rm --entrypoint scripts/audit-cpython-tests.sh build
#   docker compose run --rm --entrypoint scripts/audit-cpython-tests.sh build test_os test_socket
#
# This is an AUDIT, not a gate. tests/ in this repo is ~130 hand-written
# checks; upstream's suite is tens of thousands and will exercise corners
# nobody here thought to. Expect real failures, and expect a fair number
# of them to be legitimately inapplicable (this build has no dlopen, no
# _testcapi, sys.platform deliberately lies, etc.) rather than bugs. Read
# the output, don't just count it.
#
# Deliberately does NOT need a special build: `test` is a pure-Python
# package, so it is copied out of the CPython source tree and put on
# PYTHONPATH on its own. Only the `test` package is exposed that way - the
# stdlib under test stays the one embedded in the binary, which is the
# whole point.
#
# KNOWN BLIND SPOT, and it inflates the failure count: upstream tests
# frequently use test.support.script_helper.assert_python_ok(), which runs
# a snippet in a subprocess with -I (isolated). -I ignores PYTHONPATH by
# design, so the staged `test` package above is invisible to that child,
# and any snippet doing `from test import support` dies with
# ModuleNotFoundError and an empty stderr. The binary is fine; the harness
# cannot reach it. This accounts for most of test_threading's failures and
# likely some of test_os/test_socket/test_subprocess/test_venv's.
#
# Fixing it properly means an audit build that keeps Lib/test inside the
# binary (this build trims it - see scripts/configure-and-make.sh), so `test` is
# importable without PYTHONPATH. Until then, check a failure's traceback
# in the saved per-module log before counting it as a real defect.
set -uo pipefail

SRC_DIR="${SRC_DIR:-/work/src/cpython}"
PYTHON="${PYTHON:-$(ls /work/.bin/python-*-release.com 2>/dev/null | head -n1)}"
TESTPKG=/tmp/cpython-testpkg

# Modules worth auditing first: the parts this project actually changed,
# ported or leaned on. Ordered roughly by how much this build depends on
# them being right.
DEFAULT_TESTS=(
  test_os
  test_posixpath
  test_io
  test_socket
  test_subprocess
  test_threading
  test_signal
  test_select
  test_tempfile
  test_shutil
  test_zipimport
  test_importlib
  test_sqlite3
  test_ssl
  test_hashlib
  test_zlib
  test_bz2
  test_lzma
  test_multiprocessing_fork
  test_concurrent_futures
  test_ctypes
  test_zoneinfo
  test_venv
)

if [ ! -x "$PYTHON" ]; then
  echo "error: no interpreter at $PYTHON" >&2
  exit 2
fi
if [ ! -d "$SRC_DIR/Lib/test" ]; then
  echo "error: no CPython source at $SRC_DIR (run a build first - the source" >&2
  echo "       lives in the cpython-src volume and is re-cloned per build)" >&2
  exit 2
fi

# Prove the interpreter runs at all before spending an hour concluding it
# doesn't. On Docker Desktop for Windows, WSLInterop periodically
# re-registers itself and hijacks the APE's MZ header, at which point
# every module "fails" instantly with WSL noise about /proc/1/stat instead
# of any test output - six bogus failures that look exactly like six real
# ones. See docs/BUILD.md, "A note on WSLInterop".
if ! "$PYTHON" -c 'print("ok")' >/dev/null 2>&1; then
  echo "error: $PYTHON cannot execute - the audit would report every module" >&2
  echo "       as failed for reasons that have nothing to do with the tests." >&2
  echo "       On Docker Desktop/WSL2 this is usually WSLInterop intercepting" >&2
  echo "       the APE binary. From PowerShell on the host:" >&2
  echo "         wsl -d docker-desktop -u root -- sh -c \\" >&2
  echo "           \"echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop\"" >&2
  exit 2
fi

tests=("$@")
[ ${#tests[@]} -eq 0 ] && tests=("${DEFAULT_TESTS[@]}")

echo "Staging the 'test' package (source stdlib stays out of the way)"
rm -rf "$TESTPKG"
mkdir -p "$TESTPKG"
cp -r "$SRC_DIR/Lib/test" "$TESTPKG/test"

echo "Interpreter: $("$PYTHON" -c 'import sys; print(sys.version.replace(chr(10), " "))')"
echo "Auditing ${#tests[@]} test modules"
echo

# Keep every module's full output. The summary tail is what you read now;
# the saved logs are what triage needs later, and re-running a module
# verbosely just to see a traceback costs minutes each time.
LOGDIR="${LOGDIR:-/work/logs/audit}"
mkdir -p "$LOGDIR"
rm -f "$LOGDIR"/*.log
echo "Per-module logs: $LOGDIR"

module_log="$(mktemp)"
trap 'rm -f "$module_log"' EXIT

passed=() failed=() errored=() crashed=()
for t in "${tests[@]}"; do
  printf '%s\n' "----------------------------------------------------------------"
  printf 'running %s\n' "$t"

  # -m test runs one module through CPython's own regrtest harness, which
  # knows about resource gating, skips and timeouts. Wall-clock capped so
  # a hang costs minutes, not the whole audit.
  #
  # Output goes to a file rather than straight into `| tail`, which looks
  # equivalent but deadlocks here: some modules (test_concurrent_futures)
  # deliberately exercise the 'forkserver' start method, which hangs on
  # this build. `timeout` then kills the test process but NOT its orphaned
  # forkserver children, and those children still hold the write end of
  # the pipe - so `tail` waits for an EOF that never comes and the whole
  # audit stalls indefinitely. A plain redirect has no such reader.
  # -v so the saved log names the individual failing tests and keeps their
  # tracebacks; only the tail is echoed, so the console stays readable.
  rc=0
  PYTHONPATH="$TESTPKG" timeout --kill-after=30 600 \
      "$PYTHON" -m test -v --timeout 300 "$t" > "$module_log" 2>&1 || rc=$?
  cp "$module_log" "$LOGDIR/$t.log"
  tail -25 "$module_log"

  # Classify. `timeout` exits 124 on SIGTERM, or 128+signal when it has to
  # escalate to --kill-after; a module that was killed mid-crash comes back
  # as 139 (SIGSEGV) and would otherwise be filed as an ordinary failure.
  # The utility also announces itself in the log, which is the one
  # unambiguous signal, so trust that first.
  if [ "$rc" -eq 0 ]; then
    passed+=("$t")
  elif grep -q '^timeout: ' "$module_log" || [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    errored+=("$t (timed out after ${rc})")
  elif [ "$rc" -ge 128 ]; then
    crashed+=("$t (killed by signal $((rc - 128)))")
  else
    failed+=("$t")
  fi

  # Reap anything the module left behind. Orphaned forkserver/resource
  # tracker processes otherwise accumulate across modules and can hold
  # semaphores and ports that later modules need. Safe because modules run
  # strictly one at a time.
  pkill -f "$PYTHON" 2>/dev/null || true
done

echo
echo "================================================================"
echo "AUDIT SUMMARY"
echo "  passed:  ${#passed[@]}"
echo "  failed:  ${#failed[@]}"
echo "  crashed: ${#crashed[@]}"
echo "  timeout: ${#errored[@]}"
[ ${#failed[@]} -gt 0 ]  && printf '  FAILED:  %s\n' "${failed[@]}"
[ ${#crashed[@]} -gt 0 ] && printf '  CRASHED: %s\n' "${crashed[@]}"
[ ${#errored[@]} -gt 0 ] && printf '  TIMEOUT: %s\n' "${errored[@]}"
echo "================================================================"
echo "Reminder: failures here are findings to triage, not necessarily bugs."
