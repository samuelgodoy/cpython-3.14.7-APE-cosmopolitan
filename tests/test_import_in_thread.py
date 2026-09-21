"""Importing heavy stdlib modules from a thread must not blow the parser.

Regression test for a real failure found by the CPython test-suite audit
(test_multiprocessing_fork):

    MemoryError: Parser stack overflowed - Python source too complex to parse

Cause: the embedded stdlib shipped only .py, so every import parsed source
at runtime (zipimport can't write a cache back into a read-only zip).
Threads get a much smaller stack than the main thread, and CPython's
parser recurses on it, so a complex enough module blew the stack when
imported from a thread. Shipping .pyc alongside the source removes the
parse entirely. See docs/BUILD.md.

The modules below are the actual chain that failed, reached from
multiprocessing.managers -> xmlrpc.client -> http.client -> email.
"""
import sys
import threading

from harness import check, report


def _import_in_thread(module_names):
    """Import each name in a fresh thread; return the first failure."""
    failures = []

    def worker():
        for name in module_names:
            try:
                __import__(name)
            except BaseException as exc:  # MemoryError is not an Exception
                failures.append(f"{name}: {type(exc).__name__}: {exc}")

    t = threading.Thread(target=worker)
    t.start()
    t.join(timeout=60)
    if t.is_alive():
        raise AssertionError("import thread hung")
    if failures:
        raise AssertionError("; ".join(failures))
    return "ok"


def t_email_chain_in_thread():
    # The exact chain that used to fail.
    return _import_in_thread([
        "email._policybase",
        "email.header",
        "email.parser",
        "http.client",
        "xmlrpc.client",
    ])


check("import email/xmlrpc chain in a thread", t_email_chain_in_thread)


def t_heavy_modules_in_thread():
    # A broader sweep of modules big enough to stress the parser.
    return _import_in_thread([
        "argparse", "asyncio", "decimal", "difflib", "inspect",
        "logging.config", "pydoc", "typing", "unittest.mock", "zipfile",
    ])


check("import heavy stdlib modules in a thread", t_heavy_modules_in_thread)


def t_manager_uses_that_chain():
    # multiprocessing.managers is what surfaced this in the audit: its
    # accepter thread imports xmlrpc.client lazily.
    import multiprocessing
    with multiprocessing.Manager() as manager:
        d = manager.dict()
        d["x"] = 1
        return dict(d)


check("multiprocessing.Manager (lazy import in accepter thread)",
      t_manager_uses_that_chain)


def t_stdlib_is_precompiled():
    # Guards the fix itself: if the .pyc stop being embedded, the tests
    # above might still pass by luck on a roomier stack, so assert the
    # mechanism directly.
    #
    # Deliberately NOT os/io/abc/codecs: CPython freezes those into the
    # executable, so they never come from /zip at all and always report
    # __cached__ = None regardless of what was built. email.header is a
    # genuinely file-loaded module, and is the one that actually failed.
    import importlib.util
    import email.header

    cached = getattr(email.header, "__cached__", None)
    loader = type(email.header.__loader__).__name__
    if not cached or not cached.endswith(".pyc"):
        raise AssertionError(
            f"email.header is not loading from bytecode (__cached__={cached!r}, "
            f"loader={loader}) - did compileall run at build time?"
        )

    # __cached__ is just the path the loader *would* use; make sure the
    # bytecode is really there, otherwise the source was parsed anyway.
    import os
    if not os.path.exists(cached):
        raise AssertionError(f"no bytecode at {cached} - source was parsed")
    return f"{loader} <- {cached}"


check("stdlib is served as precompiled bytecode", t_stdlib_is_precompiled)


def t_startup_is_not_parsing():
    # Not a hard threshold (machines vary), just records it so a
    # regression is visible in the log next to everything else.
    import subprocess
    import time
    start = time.time()
    subprocess.run([sys.executable, "-c", "import email.header, xmlrpc.client"],
                   check=True)
    return f"{time.time() - start:.3f}s to start + import the heavy chain"


check("startup + heavy import time", t_startup_is_not_parsing)

report("importing from threads / precompiled stdlib")
