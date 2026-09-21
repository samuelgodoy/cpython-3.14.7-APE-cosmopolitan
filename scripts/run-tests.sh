#!/bin/bash
# Runs the test suite (tests/) against a built binary.
#
#   scripts/run-tests.sh [path/to/python-X.Y.Z-release.com]
#
# Defaults to the binary in .bin/. Works inside the build and test
# containers and on a Windows host under git-bash. Set TEST_LOG to also
# write the output to a file.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
PYTHON="${1:-$(ls "$ROOT"/.bin/python-*-release.com 2>/dev/null | head -n1)}"
TESTS="$ROOT/tests/run_all.py"

if [ -z "$PYTHON" ] || [ ! -x "$PYTHON" ]; then
  echo "error: no built interpreter found (looked in $ROOT/.bin/)" >&2
  echo "       build one first: docker compose run --rm build" >&2
  exit 2
fi
if [ ! -f "$TESTS" ]; then
  echo "error: $TESTS not found" >&2
  exit 2
fi

# The exit code of an APE binary does not survive back to a Windows shell
# (it arrives as the POSIX wait status, code << 8, so git-bash reads the
# low byte as 0 - see docs/ERRORS.md). Decide pass/fail from the RESULT:
# line run_all.py prints instead, which is reliable on every platform. Keep
# streaming output live so a hang is visible rather than silent.
output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

"$PYTHON" "$TESTS" 2>&1 | tee "$output_file"

if [ -n "${TEST_LOG:-}" ]; then
  mkdir -p "$(dirname "$TEST_LOG")"
  cp "$output_file" "$TEST_LOG"
fi

if grep -q '^RESULT: PASS' "$output_file"; then
  exit 0
fi
if grep -q '^RESULT: FAIL' "$output_file"; then
  exit 1
fi

echo "error: test runner did not print a RESULT: line (crashed or hung?)" >&2
exit 1
