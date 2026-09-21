"""Runtime facts about the machine this APE binary is actually running on.

In this build ``sys.platform`` is always ``'linux'`` and ``os.name`` is
always ``'posix'``, on every host, by design: they are compile-time facts
that select CPython's OS-personality modules, and this binary is a single
POSIX-personality build that runs everywhere (see docs/BUILD.md). They are
therefore useless for "which OS am I on?", which is what this module is
for.

    >>> import cosmo
    >>> cosmo.host_os()
    'windows'
    >>> cosmo.is_windows()
    True
    >>> sys.platform          # unchanged, still lying, still load-bearing
    'linux'

Use this for behaviour that genuinely depends on the host - picking a
config directory, shelling out to a platform tool, choosing a line ending
for something other than a text-mode file. Do *not* use it to second-guess
the stdlib: ``os.path``, ``subprocess``, ``tempfile`` and friends already
do the right thing on every host through Cosmopolitan's POSIX layer.
"""
import sys as _sys

from _cosmo import arch, exit_process as _exit_process, host_os

__all__ = [
    "arch",
    "exit",
    "host_os",
    "is_bsd",
    "is_linux",
    "is_macos",
    "is_windows",
]


def is_windows():
    """True if running on Windows right now."""
    return host_os() == "windows"


def is_linux():
    """True if running on Linux right now."""
    return host_os() == "linux"


def is_macos():
    """True if running on macOS right now."""
    return host_os() == "macos"


def is_bsd():
    """True if running on FreeBSD, OpenBSD or NetBSD right now."""
    return host_os() in ("freebsd", "openbsd", "netbsd")


def exit(code=0):
    """Exit with `code` as the status a Windows shell will actually read.

    Only needed on Windows, and only when something outside this process
    inspects the exit status. Cosmopolitan encodes the POSIX wait status
    into the Windows exit code (shifting it left by 8) so that its own
    waitpid() works, which means ``sys.exit(1)`` reaches PowerShell as
    256 and git-bash, reading the low byte, sees 0 - a failed run looks
    successful. This bypasses that encoding.

    The trade is the mirror image, so pick deliberately:

    * ``sys.exit()``  - correct for ``subprocess.run(...).returncode`` and
      anything else reading it from inside a Cosmopolitan process; wrong
      for a Windows shell.
    * ``cosmo.exit()`` - correct for a Windows shell; a Cosmopolitan
      parent reading it via waitpid() will misread it as death by signal.

    Use it at the top level of a script that CI or a shell runs directly.
    Unlike ``sys.exit()`` this cannot be caught, runs no ``atexit``
    handlers and skips ``finally`` blocks, so call it last. Python's own
    stdout/stderr are flushed first.
    """
    for stream in (_sys.stdout, _sys.stderr):
        try:
            if stream is not None:
                stream.flush()
        except (ValueError, OSError):
            pass
    _exit_process(int(code))
