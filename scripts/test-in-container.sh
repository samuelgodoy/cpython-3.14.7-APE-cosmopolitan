#!/bin/bash
# Test entry point for the `test` and `test-arm64` compose services.
#
# Installs the pinned test-only extras from tests/requirements.txt (joblib,
# which exercises a third-party process pool that bypasses multiprocessing's
# own contexts), then runs the suite against the binary in .bin/.
set -euo pipefail

ROOT=/work
PY="$(ls "$ROOT"/.bin/python-*-release.com 2>/dev/null | head -n1)"
if [ -z "$PY" ]; then
  echo "error: no binary in .bin/ - run: docker compose run --rm build" >&2
  exit 2
fi
TARGET="${TEST_TARGET:-linux-$(uname -m)}"
EXTRAS="$(mktemp -d)"

echo "binary: $PY"
echo "target: $TARGET ($(uname -m))"
"$PY" -m pip install --quiet --disable-pip-version-check --no-deps \
    --require-hashes --target "$EXTRAS" -r "$ROOT/tests/requirements.txt"

PYTHONPATH="$EXTRAS" TEST_LOG="$ROOT/logs/test-$TARGET.log" \
  exec "$ROOT/scripts/run-tests.sh" "$PY"
