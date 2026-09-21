import sys

from harness import check, report

def t_zoneinfo():
    import zoneinfo
    tz = zoneinfo.ZoneInfo("America/Sao_Paulo")
    import datetime
    dt = datetime.datetime(2024, 6, 1, 12, 0, tzinfo=tz)
    return (str(dt), dt.utcoffset())
check("zoneinfo America/Sao_Paulo", t_zoneinfo)

def t_zoneinfo_utc():
    import zoneinfo
    return str(zoneinfo.ZoneInfo("UTC"))
check("zoneinfo UTC", t_zoneinfo_utc)

def t_shared_memory():
    from multiprocessing import shared_memory
    shm = shared_memory.SharedMemory(create=True, size=64)
    try:
        shm.buf[0:5] = b"hello"
        return bytes(shm.buf[0:5])
    finally:
        shm.close()
        shm.unlink()
check("multiprocessing.shared_memory", t_shared_memory)

def t_shared_memory_cross_process():
    from multiprocessing import shared_memory, Process
    shm = shared_memory.SharedMemory(create=True, size=64)
    try:
        def writer(name):
            from multiprocessing import shared_memory as sm2
            s = sm2.SharedMemory(name=name)
            s.buf[0:11] = b"from child!"
            s.close()
        p = Process(target=writer, args=(shm.name,))
        p.start()
        p.join(10)
        data = bytes(shm.buf[0:11])
        return (p.exitcode, data)
    finally:
        shm.close()
        shm.unlink()
check("shared_memory cross-process (fork)", t_shared_memory_cross_process)

def t_locale():
    import locale
    loc = locale.setlocale(locale.LC_ALL, '')
    return (loc, locale.getlocale(), locale.getpreferredencoding())
check("locale setlocale/getlocale", t_locale)

def t_secrets():
    import secrets
    tok = secrets.token_hex(16)
    return (len(tok), secrets.randbelow(100) < 100)
check("secrets", t_secrets)

def t_asyncio_subprocess():
    import asyncio
    async def main():
        proc = await asyncio.create_subprocess_exec(
            sys.executable, "-c", "print('async subprocess ok')",
            stdout=asyncio.subprocess.PIPE)
        out, _ = await proc.communicate()
        return out.decode().strip(), proc.returncode
    return asyncio.run(main())
check("asyncio.create_subprocess_exec", t_asyncio_subprocess)

def t_process_pool_executor():
    from concurrent.futures import ProcessPoolExecutor
    with ProcessPoolExecutor(max_workers=2) as ex:
        results_ = list(ex.map(pow, [2, 3, 4], [3, 3, 3]))
    return results_
check("concurrent.futures.ProcessPoolExecutor", t_process_pool_executor)

def t_thread_pool_executor():
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=4) as ex:
        results_ = list(ex.map(lambda x: x * 2, range(5)))
    return results_
check("concurrent.futures.ThreadPoolExecutor", t_thread_pool_executor)

def t_mp_manager():
    from multiprocessing import Manager
    with Manager() as manager:
        d = manager.dict()
        d['x'] = 42
        return dict(d)
check("multiprocessing.Manager", t_mp_manager)

def t_mp_event_condition():
    from multiprocessing import Event, Process
    ev = Event()
    def setter(e):
        e.set()
    p = Process(target=setter, args=(ev,))
    p.start()
    got = ev.wait(timeout=10)
    p.join(3)
    return (got, p.exitcode)
check("multiprocessing.Event cross-process", t_mp_event_condition)

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

report("concurrency: multiprocessing and futures")
