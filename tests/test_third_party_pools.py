"""Third-party process pools that bypass multiprocessing's own contexts.

joblib's default backend, loky, registers its own start method and
reconnects semaphores by name - so it hit Cosmopolitan's sem_open bug
directly, and no amount of guarding the stdlib's 'spawn' name would have
caught it. It is also one of the most common pure-Python dependencies that
starts processes, which makes it the right canary for the override in
patches/cosmopolitan/ (the patched sem_open.c).

Skipped when joblib isn't importable: it is not shipped in the binary,
and the build gate must not depend on network access to PyPI.
"""
from harness import check, report, Skip


import os
import subprocess
import sys


def t_joblib_default_backend():
    try:
        import joblib  # noqa: F401
    except ImportError:
        raise Skip("joblib not installed (pip install joblib to exercise loky)")
    # Run in a fresh interpreter: loky's workers re-import __main__, and
    # this module runs its checks at import time.
    probe = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "_start_method_probe.py")
    proc = subprocess.run([sys.executable, probe, "joblib"],
                          capture_output=True, text=True, timeout=180)
    for line in proc.stdout.splitlines():
        if line.startswith("PROBE-OK "):
            return line[len("PROBE-OK "):]
    tail = (proc.stderr or proc.stdout).strip().splitlines()[-3:]
    raise AssertionError(f"joblib probe failed: {' | '.join(tail)}")


check("joblib Parallel with the default loky backend", t_joblib_default_backend)

report("third-party process pools")
