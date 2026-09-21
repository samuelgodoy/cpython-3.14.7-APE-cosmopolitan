"""Tiny shared test harness.

Every test module here follows the same shape: call check() once per thing
being verified, then report() at the end. report() prints a table and exits
non-zero if anything failed, which is what makes these usable as a real
gate (scripts/run-tests.sh, and build.sh's final step) rather than output a
human has to read and judge.

Deliberately dependency-free and assertion-library-free: these run under
the freshly built python.com, so the fewer moving parts between "the
interpreter started" and "the check ran", the better.
"""
import sys

_results = []


class Skip(Exception):
    """Raise from a check to mark it not-applicable rather than failed.

    For conditions that depend on the environment rather than on the build
    being correct - e.g. os.symlink needs Developer Mode or an elevated
    prompt on Windows, exactly as it does for a normal native CPython. A
    gate that goes red for those would train people to ignore it.
    """


def check(name, fn):
    """Run fn(); record OK + its return value, SKIP, or FAIL + the error."""
    try:
        value = fn()
        _results.append((name, "OK", str(value)[:90]))
    except Skip as exc:
        _results.append((name, "SKIP", str(exc)[:90]))
    except BaseException as exc:  # noqa: BLE001 - a crash is a failed check
        _results.append((name, "FAIL", f"{type(exc).__name__}: {exc}"))


def report(title=None):
    """Print the results table and exit non-zero if any check failed."""
    width = 74
    if title:
        print(f"--- {title} ---")
    print("=" * width)
    counts = {"OK": 0, "SKIP": 0, "FAIL": 0}
    for name, status, detail in _results:
        counts[status] += 1
        print(f"[{status:4s}] {name:40s} {detail}")
    print("=" * width)
    print(f"TOTAL: {counts['OK']} OK, {counts['SKIP']} SKIP, "
          f"{counts['FAIL']} FAIL out of {len(_results)}")
    sys.exit(1 if counts["FAIL"] else 0)
