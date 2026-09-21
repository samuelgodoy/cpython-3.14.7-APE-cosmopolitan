import sys, os, platform, traceback

from harness import check, report

check("sys.version", lambda: sys.version.splitlines()[0])
check("sys.platform", lambda: sys.platform)
check("os.name", lambda: os.name)
check("platform.machine", lambda: platform.machine())
check("os.getcwd", lambda: os.getcwd())
check("os.listdir", lambda: len(os.listdir(".")))

def t_fileio():
    p = "stress_tmp_file.txt"
    with open(p, "w") as f:
        f.write("hello\nworld\n")
    with open(p) as f:
        data = f.read()
    os.remove(p)
    return len(data)
check("file io", t_fileio)

def t_tempfile():
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "x.txt")
        with open(p, "w") as f:
            f.write("x")
        return os.path.exists(p)
check("tempfile", t_tempfile)

def t_subprocess():
    import subprocess
    out = subprocess.run([sys.executable, "-c", "print('sub-ok')"], capture_output=True, text=True)
    return out.stdout.strip()
check("subprocess self-exec", t_subprocess)

def t_threading():
    import threading
    results_list = []
    def worker(i):
        results_list.append(i*i)
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
    for t in threads: t.start()
    for t in threads: t.join()
    return sum(results_list)
check("threading", t_threading)

def _sq(x): return x*x  # module-level: Pool.map's args must be picklable,
                         # which a local/closure function never is on any
                         # platform (not a cosmocc limitation)

def t_multiprocessing():
    import multiprocessing as mp
    with mp.Pool(2) as pool:
        r = pool.map(_sq, range(5))
    return r
check("multiprocessing", t_multiprocessing)

def t_asyncio():
    import asyncio
    async def main():
        await asyncio.sleep(0.01)
        return "async-ok"
    return asyncio.run(main())
check("asyncio", t_asyncio)

def t_socket():
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port > 0
check("socket bind", t_socket)

def t_http_server_client():
    import http.server, threading, urllib.request, socket
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"pong")
        def log_message(self, *a): pass
    srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_port
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    try:
        resp = urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=5)
        data = resp.read()
    finally:
        srv.shutdown()
    return data
check("http.server + urllib (loopback, no TLS)", t_http_server_client)

def t_zlib_roundtrip():
    import zlib
    data = b"hello world" * 1000
    c = zlib.compress(data)
    d = zlib.decompress(c)
    return d == data
check("zlib roundtrip", t_zlib_roundtrip)

def t_ctypes_struct():
    import ctypes
    class Point(ctypes.Structure):
        _fields_ = [("x", ctypes.c_int), ("y", ctypes.c_int)]
    p = Point(3, 4)
    return (p.x, p.y, ctypes.sizeof(p))
check("ctypes struct", t_ctypes_struct)

def t_ctypes_array():
    import ctypes
    arr = (ctypes.c_int * 5)(1,2,3,4,5)
    return sum(arr)
check("ctypes array", t_ctypes_array)

def t_json():
    import json
    return json.loads(json.dumps({"a": [1,2,3], "b": "x"}))
check("json roundtrip", t_json)

def t_hashlib():
    import hashlib
    return hashlib.sha256(b"x").hexdigest()[:8]
check("hashlib sha256", t_hashlib)

def t_decimal():
    import decimal
    return str(decimal.Decimal("1.1") + decimal.Decimal("2.2"))
check("decimal", t_decimal)

def t_datetime():
    import datetime
    return str(datetime.datetime(2024,1,1))
check("datetime", t_datetime)

def t_pathlib():
    import pathlib
    p = pathlib.Path(".")
    return p.resolve().exists()
check("pathlib", t_pathlib)

def t_glob():
    import glob
    return len(glob.glob("*"))
check("glob", t_glob)

def t_shutil():
    import shutil
    src, dst = "stress_src.txt", "stress_dst.txt"
    with open(src, "w") as f: f.write("copyme")
    shutil.copy(src, dst)
    ok = open(dst).read() == "copyme"
    os.remove(src); os.remove(dst)
    return ok
check("shutil copy", t_shutil)

def t_signal():
    import signal
    return hasattr(signal, "SIGTERM")
check("signal module", t_signal)

def t_random():
    import random
    random.seed(42)
    return random.randint(1,100)
check("random", t_random)

def t_re():
    import re
    return re.findall(r"\d+", "a1b22c333")
check("re", t_re)

def t_struct():
    import struct
    return struct.unpack(">I", struct.pack(">I", 12345))[0]
check("struct", t_struct)

def t_array():
    import array
    a = array.array("i", [1,2,3])
    return sum(a)
check("array module", t_array)

def t_venv_import_ensurepip():
    import ensurepip
    return True
check("ensurepip importable", t_venv_import_ensurepip)

def t_sysconfig():
    import sysconfig
    return sysconfig.get_platform()
check("sysconfig.get_platform", t_sysconfig)

def t_locale():
    import locale
    return locale.getpreferredencoding()
check("locale", t_locale)

def t_ssl_absent():
    try:
        import ssl
        return "ssl AVAILABLE (unexpected at this stage)"
    except ImportError as e:
        return f"expected missing: {e}"
check("ssl (expected missing for now)", t_ssl_absent)

def t_sqlite3_absent():
    try:
        import sqlite3
        return "sqlite3 AVAILABLE (unexpected at this stage)"
    except ImportError as e:
        return f"expected missing: {e}"
check("sqlite3 (expected missing for now)", t_sqlite3_absent)

def t_bz2_absent():
    try:
        import bz2
        return "bz2 AVAILABLE (unexpected at this stage)"
    except ImportError as e:
        return f"expected missing: {e}"
check("bz2 (expected missing for now)", t_bz2_absent)

def t_env_vars():
    os.environ["STRESS_TEST_VAR"] = "hello"
    return os.environ.get("STRESS_TEST_VAR")
check("env vars", t_env_vars)

def t_cwd_chdir():
    orig = os.getcwd()
    os.chdir("..")
    back = os.getcwd()
    os.chdir(orig)
    return back != orig
check("chdir", t_cwd_chdir)

def t_stat():
    st = os.stat(".")
    return st.st_size >= 0
check("os.stat", t_stat)

def t_walk():
    n = 0
    for root, dirs, files in os.walk("."):
        n += len(files)
        if n > 50: break
    return n
check("os.walk", t_walk)

def t_argv_encoding():
    return sys.getdefaultencoding()
check("default encoding", t_argv_encoding)

report("core interpreter, stdlib and build features")
