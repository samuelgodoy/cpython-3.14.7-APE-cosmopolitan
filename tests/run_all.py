"""Run every test_*.py in this directory and aggregate the result.

Usage:  python.com tests/run_all.py

Each test module runs as its own subprocess of the *same* interpreter.
That isolation is deliberate rather than incidental: these tests fork,
install signal handlers, spawn process pools and bind sockets, so letting
one module's leftovers reach the next one would make failures much harder
to attribute. It also means a hard crash in one module (segfault, hang
killed by timeout) is reported as that module failing, instead of taking
the whole run down with it.

Exits non-zero if any module fails, so it works as a build gate.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Generous: the slowest modules fork process pools and do real DNS/TLS.
PER_MODULE_TIMEOUT = 300


def main():
    modules = sorted(
        f for f in os.listdir(HERE)
        if f.startswith("test_") and f.endswith(".py")
    )
    if not modules:
        print("no test_*.py modules found", file=sys.stderr)
        return 1

    print(f"Running {len(modules)} test modules with {sys.executable}")
    print(f"Python: {sys.version.splitlines()[0]}")

    failures = []
    for module in modules:
        print(f"\n{'#' * 74}\n# {module}\n{'#' * 74}", flush=True)
        try:
            completed = subprocess.run(
                [sys.executable, os.path.join(HERE, module)],
                timeout=PER_MODULE_TIMEOUT,
            )
            if completed.returncode != 0:
                failures.append((module, f"exit code {completed.returncode}"))
        except subprocess.TimeoutExpired:
            failures.append((module, f"timed out after {PER_MODULE_TIMEOUT}s"))
            print(f"!! {module} TIMED OUT", flush=True)

    print(f"\n{'=' * 74}")
    if failures:
        print(f"{len(failures)} of {len(modules)} modules failed")
        for module, why in failures:
            print(f"  - {module}: {why}")
    else:
        print(f"all {len(modules)} modules passed")
    print("=" * 74)

    # Machine-readable verdict. This exists because an APE binary's exit
    # code does not survive the trip back to a Windows shell: the process
    # exits with the POSIX wait status (code << 8), so PowerShell sees 256
    # for exit(1) and MSYS/git-bash takes the low byte and sees 0 - i.e.
    # a failing run looks successful. See docs/BUILD.md. Exit codes *within*
    # this process tree are fine, which is why the per-module returncode
    # checks above are trustworthy; it's only the final hand-off out that
    # is lossy. Callers on Windows should grep for this line instead.
    print(f"RESULT: {'FAIL' if failures else 'PASS'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
