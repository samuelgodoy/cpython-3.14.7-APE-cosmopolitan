"""The `cosmo` module: real host detection, since sys.platform can't be."""
import os
import sys

from harness import check, report, Skip


def t_import():
    import cosmo
    return cosmo.__name__


check("import cosmo", t_import)


def t_host_os():
    import cosmo
    value = cosmo.host_os()
    valid = {"windows", "linux", "macos", "freebsd", "openbsd", "netbsd"}
    if value not in valid:
        raise AssertionError(f"host_os() returned {value!r}, expected one of {valid}")
    return value


check("cosmo.host_os()", t_host_os)


def t_arch():
    import cosmo
    value = cosmo.arch()
    if value not in {"x86_64", "aarch64"}:
        raise AssertionError(f"arch() returned {value!r}")
    return value


check("cosmo.arch()", t_arch)


def t_arch_agrees_with_platform():
    # platform.machine() goes through uname(); cosmo.arch() is compile-time.
    # They must agree, or the fat binary dispatched to the wrong half.
    import platform
    import cosmo
    machine, arch = platform.machine(), cosmo.arch()
    if machine != arch:
        raise AssertionError(f"platform.machine()={machine!r} != cosmo.arch()={arch!r}")
    return arch


check("cosmo.arch() == platform.machine()", t_arch_agrees_with_platform)


def t_exactly_one_predicate():
    import cosmo
    flags = {
        "windows": cosmo.is_windows(),
        "linux": cosmo.is_linux(),
        "macos": cosmo.is_macos(),
        "bsd": cosmo.is_bsd(),
    }
    true_ones = [name for name, value in flags.items() if value]
    if len(true_ones) != 1:
        raise AssertionError(f"expected exactly one true predicate, got {true_ones}")
    return true_ones[0]


check("exactly one is_*() predicate is true", t_exactly_one_predicate)


def t_predicate_matches_host_os():
    import cosmo
    host = cosmo.host_os()
    expected = {
        "windows": cosmo.is_windows(),
        "linux": cosmo.is_linux(),
        "macos": cosmo.is_macos(),
    }.get(host, cosmo.is_bsd())
    if not expected:
        raise AssertionError(f"predicate disagrees with host_os()={host!r}")
    return host


check("is_*() agrees with host_os()", t_predicate_matches_host_os)


def t_sys_platform_still_linux():
    # Guards the documented invariant: adding cosmo must NOT have tempted
    # anyone into "fixing" sys.platform, which breaks the interpreter
    # outright (see docs/BUILD.md).
    return (sys.platform, os.name)


check("sys.platform/os.name unchanged", t_sys_platform_still_linux)


def t_detects_windows_when_on_windows():
    # Cross-check against something independent of Cosmopolitan's __hostos.
    # Matched case-insensitively on purpose: os.environ is case-SENSITIVE
    # in this build even on Windows (it's a POSIX-personality build, where
    # native Windows Python would fold case), and shells disagree about
    # the spelling - git-bash exports SYSTEMROOT, cmd uses SystemRoot.
    import cosmo
    upper = {k.upper() for k in os.environ}
    windows_markers = {"SYSTEMROOT", "WINDIR", "COMSPEC"}
    looks_like_windows = bool(upper & windows_markers)

    # One-directional on purpose: a scrubbed environment proves nothing, so
    # only a positive signal that contradicts cosmo is a real failure.
    if looks_like_windows and not cosmo.is_windows():
        raise AssertionError(
            f"environment looks like Windows ({sorted(upper & windows_markers)}) "
            f"but cosmo.host_os()={cosmo.host_os()!r}"
        )
    if not looks_like_windows and cosmo.is_windows():
        raise Skip("on Windows but the shell scrubbed the usual markers")
    return f"windows={cosmo.is_windows()} (consistent with environment)"


check("host detection agrees with environment", t_detects_windows_when_on_windows)


def t_environ_is_case_sensitive():
    # Documents a real portability gotcha rather than testing cosmo: on
    # native Windows Python os.environ folds case, so os.environ['PATH']
    # and os.environ['Path'] are the same key. Here they are not, because
    # this is a POSIX-personality build (see docs/BUILD.md / README.md).
    import cosmo
    if not cosmo.is_windows():
        raise Skip("only meaningful on Windows")
    os.environ["CosmoCaseProbe"] = "mixed"
    try:
        folded = os.environ.get("COSMOCASEPROBE")
    finally:
        del os.environ["CosmoCaseProbe"]
    return f"case-sensitive={folded is None} (COSMOCASEPROBE -> {folded!r})"


check("os.environ case sensitivity (documented gotcha)", t_environ_is_case_sensitive)

report("cosmo module: runtime host detection")
