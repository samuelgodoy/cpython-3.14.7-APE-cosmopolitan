import sys, os, time

from harness import check, report

# --- zoneinfo / Barrier / Manager / ProcessPoolExecutor retest ---
def t_zoneinfo():
    import zoneinfo, datetime
    tz = zoneinfo.ZoneInfo("America/Sao_Paulo")
    dt = datetime.datetime(2024, 6, 1, 12, 0, tzinfo=tz)
    return (str(dt), str(dt.utcoffset()))
check("zoneinfo America/Sao_Paulo", t_zoneinfo)

def t_barrier():
    from multiprocessing import Barrier, Process, Queue
    b = Barrier(2)
    q = Queue()
    def worker(bar, qq):
        bar.wait()
        qq.put("reached")
    p = Process(target=worker, args=(b, q))
    p.start()
    b.wait(timeout=10)
    msg = q.get(timeout=10)
    p.join(3)
    return (msg, p.exitcode)
check("multiprocessing.Barrier", t_barrier)

def t_mp_manager():
    from multiprocessing import Manager
    with Manager() as manager:
        d = manager.dict()
        d['x'] = 42
        return dict(d)
check("multiprocessing.Manager", t_mp_manager)

def t_process_pool_executor():
    # Must actually work: ProcessPoolExecutor uses the default start method,
    # which patch 0006 pins to 'fork'. Only 'forkserver' is broken here, and
    # nothing reaches for it any more (patch 0012). See docs/BUILD.md.
    from concurrent.futures import ProcessPoolExecutor
    with ProcessPoolExecutor(max_workers=2) as ex:
        results_ = list(ex.map(pow, [2, 3, 4], [3, 3, 3]))
    return results_
check("concurrent.futures.ProcessPoolExecutor", t_process_pool_executor)

# --- tempfile ---
def t_tempdir():
    import tempfile
    d = tempfile.gettempdir()
    return (d, os.path.isdir(d))
check("tempfile.gettempdir", t_tempdir)

def t_namedtempfile():
    import tempfile
    with tempfile.NamedTemporaryFile(delete=False, mode='w') as f:
        f.write("hi")
        path = f.name
    ok = open(path).read() == "hi"
    os.remove(path)
    return ok
check("tempfile.NamedTemporaryFile", t_namedtempfile)

# --- argparse ---
def t_argparse():
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--name", default="world")
    p.add_argument("count", type=int)
    ns = p.parse_args(["--name", "cosmo", "5"])
    return (ns.name, ns.count)
check("argparse", t_argparse)

# --- logging ---
def t_logging():
    import logging, io
    buf = io.StringIO()
    logger = logging.getLogger("cosmo-test")
    logger.setLevel(logging.INFO)
    handler = logging.StreamHandler(buf)
    logger.addHandler(handler)
    logger.info("hello %s", "logging")
    logger.removeHandler(handler)
    return buf.getvalue().strip()
check("logging", t_logging)

# --- codecs ---
def t_latin1():
    s = "café"
    b = s.encode("latin-1")
    return (b, b.decode("latin-1"))
check("codec latin-1", t_latin1)

def t_shiftjis():
    s = "こんにちは"
    b = s.encode("shift_jis")
    return (len(b), b.decode("shift_jis"))
check("codec shift_jis", t_shiftjis)

def t_big5():
    s = "你好"
    b = s.encode("big5")
    return (len(b), b.decode("big5"))
check("codec big5", t_big5)

# --- socket / DNS / IPv6 ---
def t_getaddrinfo():
    import socket
    infos = socket.getaddrinfo("localhost", 80, proto=socket.IPPROTO_TCP)
    return len(infos) > 0
check("socket.getaddrinfo localhost", t_getaddrinfo)

def t_ipv6_socket():
    import socket
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    s.bind(("::1", 0))
    port = s.getsockname()[1]
    s.close()
    return port > 0
check("IPv6 socket bind ::1", t_ipv6_socket)

def t_dns_real():
    import socket
    try:
        addr = socket.gethostbyname("dns.google")
        return addr
    except socket.gaierror as e:
        return f"gaierror (maybe offline/sandboxed): {e}"
check("DNS resolve dns.google", t_dns_real)

# --- raw os.fork() ---
def t_raw_fork():
    import os
    pid = os.fork()
    if pid == 0:
        os._exit(42)
    else:
        _, status = os.waitpid(pid, 0)
        return os.WEXITSTATUS(status)
check("raw os.fork()", t_raw_fork)

# --- signals ---
def t_sigterm_handler():
    import signal
    got = []
    def handler(signum, frame):
        got.append(signum)
    old = signal.signal(signal.SIGTERM, handler)
    os.kill(os.getpid(), signal.SIGTERM)
    signal.signal(signal.SIGTERM, old)
    return got
check("SIGTERM self-signal + handler", t_sigterm_handler)

def t_sigint_handler():
    import signal
    got = []
    def handler(signum, frame):
        got.append(signum)
    old = signal.signal(signal.SIGINT, handler)
    os.kill(os.getpid(), signal.SIGINT)
    signal.signal(signal.SIGINT, old)
    return got
check("SIGINT self-signal + handler", t_sigint_handler)

# --- faulthandler ---
def t_faulthandler():
    # faulthandler writes at the fd level, so it needs a real file object -
    # io.StringIO has no fileno() and fails here on any Python, not just
    # this build.
    import faulthandler, tempfile
    with tempfile.TemporaryFile('w+') as f:
        faulthandler.dump_traceback(file=f)
        f.seek(0)
        return len(f.read()) > 0
check("faulthandler.dump_traceback", t_faulthandler)

def t_traceback_format():
    import traceback
    try:
        1 / 0
    except ZeroDivisionError:
        tb = traceback.format_exc()
    return "ZeroDivisionError" in tb
check("traceback.format_exc", t_traceback_format)

# --- startup time ---
def t_startup_time():
    import subprocess
    start = time.time()
    subprocess.run([sys.executable, "-c", "pass"], check=True)
    return round(time.time() - start, 3)
check("interpreter startup time (s)", t_startup_time)

report("stdlib breadth: tz, codecs, sockets, signals")
