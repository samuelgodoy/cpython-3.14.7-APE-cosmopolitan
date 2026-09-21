"""Cosmopolitan-level platform defects: what's fixed, and what isn't.

AF_UNIX bind()/connect() used to reject the POSIX-idiomatic address
length CPython passes, which made short paths fail with EINVAL. Fixed by
passing sizeof(struct sockaddr_un) instead (patch 0015) - isolated with a
standalone C repro where identical binds succeeded or failed purely on
addrlen, with no relation to the path.

Cosmopolitan hands sun_path to Windows untranslated, so its own /C/...
drive-mapped form - which is what tempfile.gettempdir() returns - was
never a path Windows understood. Patch 0015 rewrites that prefix to the
native C:/... form, so both shapes now bind.

Exit codes are deliberately NOT worked around; see the check below.
"""
import os
import socket
import subprocess
import sys
import tempfile

from harness import check, report, Skip

import cosmo


def t_exit_code_via_subprocess():
    # What Python itself observes must stay correct - subprocess.run's
    # returncode, check=True, multiprocessing exitcode and pip all rely
    # on it. Cosmopolitan encodes the POSIX wait status into the Windows
    # exit code so its own waitpid() works, which is why this is right
    # while a Windows *shell* sees the code shifted left by 8.
    bad = {}
    for code in (0, 1, 2, 42, 77):
        got = subprocess.run(
            [sys.executable, "-c", f"import sys; sys.exit({code})"]
        ).returncode
        if got != code:
            bad[code] = got
    if bad:
        raise AssertionError(f"subprocess returncode wrong: {bad}")
    return "0, 1, 2, 42, 77 all correct"


check("subprocess.returncode is correct", t_exit_code_via_subprocess)


def t_exit_code_shell_caveat():
    # Documents the known, deliberate trade rather than asserting a fix.
    # Calling Win32 ExitProcess() directly does make a Windows shell read
    # the code verbatim - but it was tried and reverted, because the same
    # integer is the only channel Cosmopolitan has for the wait status, so
    # fixing the shell's view breaks subprocess.returncode above (exit 1
    # started arriving as -1, i.e. "killed by signal 1"). Internal
    # correctness wins; the shell side divides by 256.
    if not cosmo.is_windows():
        raise Skip(f"shell exit-code caveat is Windows-only (on {cosmo.host_os()})")
    return "known: Windows shells see code << 8; divide by 256"


check("Windows shell exit-code caveat (documented, not fixed)",
      t_exit_code_shell_caveat)


def _bind_unix(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.bind(path)
        return s
    except BaseException:
        s.close()
        raise


def t_unix_bind_short_relative():
    # Under 13 characters - the shape that failed with EINVAL before the
    # addrlen fix. The length was a red herring; addrlen was the cause.
    d = tempfile.mkdtemp(prefix="cosmo_un_")
    cwd = os.getcwd()
    os.chdir(d)
    try:
        _bind_unix("x.sock").close()
        return "bound 'x.sock'"
    finally:
        os.chdir(cwd)


check("AF_UNIX bind, short relative path", t_unix_bind_short_relative)


def t_unix_roundtrip_tmp():
    # Full server/client exchange, not just bind.
    path = f"/tmp/sock-rt-{os.getpid()}"
    try:
        os.unlink(path)
    except OSError:
        pass
    server = _bind_unix(path)
    try:
        server.listen(1)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(10)
        client.connect(path)
        conn, _ = server.accept()
        client.sendall(b"ping")
        got = conn.recv(16)
        conn.close()
        client.close()
        if got != b"ping":
            raise AssertionError(f"received {got!r}")
        return got
    finally:
        server.close()
        try:
            os.unlink(path)
        except OSError:
            pass


check("AF_UNIX connect + data roundtrip under /tmp", t_unix_roundtrip_tmp)


def t_unix_drive_mapped_path():
    # tempfile.gettempdir() returns /C/Users/... on Windows, and
    # Cosmopolitan hands sun_path to Windows untranslated, so this used to
    # fail with WSAENETDOWN. Patch 0015 rewrites the prefix to native
    # C:/... - which is the form that works - so the most common way to
    # get an AF_UNIX path now binds.
    if not cosmo.is_windows():
        raise Skip(f"drive-mapped paths are Windows-only (on {cosmo.host_os()})")
    path = os.path.join(tempfile.gettempdir(), f"sock-dm-{os.getpid()}")
    try:
        os.unlink(path)
    except OSError:
        pass
    s = _bind_unix(path)
    s.close()
    try:
        os.unlink(path)
    except OSError:
        pass
    return f"bound under {tempfile.gettempdir()}"


check("AF_UNIX bind under the drive-mapped temp dir",
      t_unix_drive_mapped_path)



def _probe(mode, timeout=120):
    """Run tests/_start_method_probe.py in a fresh interpreter."""
    probe = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "_start_method_probe.py")
    proc = subprocess.run([sys.executable, probe, mode],
                          capture_output=True, text=True, timeout=timeout)
    for line in proc.stdout.splitlines():
        if line.startswith("PROBE-OK "):
            return line[len("PROBE-OK "):]
    tail = (proc.stderr or proc.stdout).strip().splitlines()[-3:]
    raise AssertionError(f"{mode} probe failed: {' | '.join(tail)}")


def t_spawn_works():
    # Works because the patched sem_open.c (patches/cosmopolitan/) replaces Cosmopolitan's
    # sem_open, which reinitialized an existing semaphore (with stack
    # garbage) whenever another process reconnected to it by name.
    return _probe("spawn")


check("spawn start method works end to end", t_spawn_works)


def t_forkserver():
    import multiprocessing as mp
    if cosmo.is_windows():
        # Windows AF_UNIX has no SCM_RIGHTS; patch 0016 rejects this with
        # an explanation instead of an opaque traceback from the helper.
        try:
            mp.get_context("forkserver")
        except ValueError as exc:
            if "SCM_RIGHTS" not in str(exc):
                raise AssertionError(f"unhelpful message: {exc}")
            return "rejected on Windows with an explanation"
        raise AssertionError("forkserver unexpectedly allowed on Windows")
    return _probe("forkserver")


check("forkserver: works on POSIX, explained on Windows", t_forkserver)


def t_fork_still_default():
    import multiprocessing as mp
    method = mp.get_start_method()
    if method != "fork":
        raise AssertionError(f"default start method is {method!r}, expected 'fork'")
    mp.get_context("fork")  # must still work
    return method


check("fork remains the default and works", t_fork_still_default)


def t_cosmo_exit_shell_visible():
    # Windows-only by construction: the wait-status encoding only exists
    # there, so on POSIX cosmo.exit() is just _exit() and is
    # indistinguishable from sys.exit() - which is correct, not a bug.
    #
    # The real assertion (that a Windows *shell* reads 7 rather than 1792)
    # can't be made from here, because this parent is itself a
    # Cosmopolitan process and will misread the bypassed status - that is
    # the documented trade. So assert the bypass happened instead.
    if not cosmo.is_windows():
        raise Skip(f"wait-status encoding is Windows-only (on {cosmo.host_os()})")
    import subprocess
    proc = subprocess.run(
        [sys.executable, "-c", "import cosmo; cosmo.exit(7)"],
        capture_output=True,
    )
    if proc.returncode == 7:
        raise AssertionError(
            "cosmo.exit(7) produced the same status as sys.exit(7); the "
            "ExitProcess bypass did not happen"
        )
    return f"bypassed encoding (parent reads {proc.returncode}, as documented)"


check("cosmo.exit bypasses the wait-status encoding",
      t_cosmo_exit_shell_visible)


def t_cosmo_exit_flushes():
    import subprocess
    proc = subprocess.run(
        [sys.executable, "-c",
         "import cosmo; print('written before exit'); cosmo.exit(0)"],
        capture_output=True, text=True,
    )
    if "written before exit" not in proc.stdout:
        raise AssertionError(f"output lost on exit: {proc.stdout!r}")
    return "stdout survives cosmo.exit()"


check("cosmo.exit flushes buffered output", t_cosmo_exit_flushes)

report("Cosmopolitan platform defects: fixed and outstanding")
