import sys, os, tempfile, shutil, stat, time

from harness import check, report, Skip

check("sys.platform/os.name", lambda: (sys.platform, os.name))
check("os.sep / os.pathsep", lambda: (os.sep, os.pathsep))
check("os.getcwd", lambda: os.getcwd())
check("os.path module", lambda: os.path.__name__)

def t_abspath():
    return os.path.abspath("foo/bar.txt")
check("os.path.abspath", t_abspath)

def t_mkdir_tree():
    base = os.path.join(tempfile.gettempdir(), "cosmo_interop_test")
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(os.path.join(base, "a", "b", "c"))
    ok = os.path.isdir(os.path.join(base, "a", "b", "c"))
    shutil.rmtree(base, ignore_errors=True)
    return ok
check("os.makedirs nested + isdir", t_mkdir_tree)

def t_write_read_binary():
    p = os.path.join(tempfile.gettempdir(), "cosmo_bin_test.bin")
    data = bytes(range(256))
    with open(p, "wb") as f:
        f.write(data)
    with open(p, "rb") as f:
        got = f.read()
    os.remove(p)
    return got == data
check("binary file roundtrip", t_write_read_binary)

def t_unicode_filename():
    p = os.path.join(tempfile.gettempdir(), "cosmo_tëst_文件_🎉.txt")
    with open(p, "w", encoding="utf-8") as f:
        f.write("unicode filename test")
    ok = os.path.exists(p)
    content = open(p, encoding="utf-8").read()
    os.remove(p)
    return (ok, content)
check("unicode filename + content", t_unicode_filename)

def t_chmod():
    p = os.path.join(tempfile.gettempdir(), "cosmo_chmod_test.txt")
    with open(p, "w") as f:
        f.write("x")
    os.chmod(p, stat.S_IREAD)
    mode_readonly = os.stat(p).st_mode
    os.chmod(p, stat.S_IREAD | stat.S_IWRITE)
    os.remove(p)
    return oct(mode_readonly)
check("os.chmod", t_chmod)

def t_rename():
    d = tempfile.gettempdir()
    p1 = os.path.join(d, "cosmo_rename_a.txt")
    p2 = os.path.join(d, "cosmo_rename_b.txt")
    with open(p1, "w") as f: f.write("x")
    if os.path.exists(p2): os.remove(p2)
    os.rename(p1, p2)
    ok = os.path.exists(p2) and not os.path.exists(p1)
    os.remove(p2)
    return ok
check("os.rename", t_rename)

def t_stat_times():
    p = os.path.join(tempfile.gettempdir(), "cosmo_stat_test.txt")
    with open(p, "w") as f: f.write("x")
    st = os.stat(p)
    os.remove(p)
    return (st.st_mtime > 0, st.st_size)
check("os.stat mtime/size", t_stat_times)

def t_walk_and_scandir():
    d = tempfile.mkdtemp(prefix="cosmo_walk_")
    os.makedirs(os.path.join(d, "sub1"))
    open(os.path.join(d, "f1.txt"), "w").close()
    open(os.path.join(d, "sub1", "f2.txt"), "w").close()
    found = []
    for root, dirs, files in os.walk(d):
        for fn in files:
            found.append(os.path.relpath(os.path.join(root, fn), d))
    with os.scandir(d) as it:
        entries = [e.name for e in it]
    shutil.rmtree(d)
    return (sorted(found), sorted(entries))
check("os.walk + os.scandir", t_walk_and_scandir)

def t_symlink():
    d = tempfile.mkdtemp(prefix="cosmo_symlink_")
    target = os.path.join(d, "target.txt")
    link = os.path.join(d, "link.txt")
    with open(target, "w") as f: f.write("hi")
    try:
        try:
            os.symlink(target, link)
        except (PermissionError, OSError) as exc:
            # Creating symlinks on Windows needs Developer Mode or an
            # elevated prompt. Native CPython has the same requirement, so
            # this is the environment, not the build - skip rather than
            # fail (see harness.Skip).
            raise Skip(f"no symlink privilege: {exc}") from None
        ok = os.path.islink(link) and open(link).read() == "hi"
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return ok
check("os.symlink (needs privilege on Windows)", t_symlink)

def t_hardlink():
    d = tempfile.mkdtemp(prefix="cosmo_hardlink_")
    target = os.path.join(d, "target.txt")
    link = os.path.join(d, "hardlink.txt")
    with open(target, "w") as f: f.write("hi")
    try:
        os.link(target, link)
        ok = open(link).read() == "hi"
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return ok
check("os.link (hardlink)", t_hardlink)

def t_environ_path():
    return os.environ.get("PATH", "")[:60]
check("os.environ PATH", t_environ_path)

def t_expanduser():
    return os.path.expanduser("~")
check("os.path.expanduser", t_expanduser)

def t_cwd_roundtrip_drive():
    # Windows-specific: drive letter handling should not crash even
    # though we're a POSIX-personality build.
    cwd = os.getcwd()
    drive, tail = os.path.splitdrive(cwd)
    return (drive, tail[:30])
check("os.path.splitdrive", t_cwd_roundtrip_drive)

def t_normcase():
    return os.path.normcase("FooBar.TXT")
check("os.path.normcase", t_normcase)

def t_realpath_dotdot():
    return os.path.realpath(os.path.join(os.getcwd(), "..", os.path.basename(os.getcwd())))
check("os.path.realpath with ..", t_realpath_dotdot)

def t_copy_tree():
    src = tempfile.mkdtemp(prefix="cosmo_ct_src_")
    dst = os.path.join(tempfile.gettempdir(), "cosmo_ct_dst")
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(os.path.join(src, "sub"))
    open(os.path.join(src, "sub", "f.txt"), "w").write("data")
    shutil.copytree(src, dst)
    ok = open(os.path.join(dst, "sub", "f.txt")).read() == "data"
    shutil.rmtree(src, ignore_errors=True)
    shutil.rmtree(dst, ignore_errors=True)
    return ok
check("shutil.copytree", t_copy_tree)

def t_disk_usage():
    du = shutil.disk_usage(os.getcwd())
    return du.total > 0
check("shutil.disk_usage", t_disk_usage)

def t_which():
    return shutil.which("python") or shutil.which("ls") or shutil.which("dir") or "not found (ok)"
check("shutil.which", t_which)

def t_getlogin_or_user():
    import getpass
    return getpass.getuser()
check("getpass.getuser", t_getlogin_or_user)

def t_file_locking_flock():
    # POSIX-only concept; exercised since os.name is always 'posix' here.
    import fcntl
    p = os.path.join(tempfile.gettempdir(), "cosmo_flock_test.txt")
    with open(p, "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        fcntl.flock(f, fcntl.LOCK_UN)
    os.remove(p)
    return True
check("fcntl.flock", t_file_locking_flock)

report("filesystem and OS interop")
