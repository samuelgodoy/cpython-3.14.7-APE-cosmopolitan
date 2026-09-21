"""Exercised by the tests via subprocess, never collected by run_all.py.

Start methods other than 'fork' re-import the main module in each child,
and the test modules run their checks at import time - so the process
work has to live in a script with a proper __main__ guard.

Prints "PROBE-OK <detail>" and exits 0 on success; anything else is a
failure.
"""
import sys


def sq(x):
    return x * x


def locker(lock, queue):
    with lock:
        queue.put("got lock")


def start_method(method):
    import multiprocessing as mp
    ctx = mp.get_context(method)
    with ctx.Pool(2) as pool:
        got = pool.map(sq, range(5))
    assert got == [0, 1, 4, 9, 16], got
    lock, queue = ctx.Lock(), ctx.Queue()
    proc = ctx.Process(target=locker, args=(lock, queue))
    proc.start()
    msg = queue.get(timeout=30)
    proc.join(30)
    # Cosmopolitan's sem_open corrupted the PARENT's semaphore when a child
    # reconnected to it by name; the parent must still be able to lock.
    assert lock.acquire(timeout=10), "parent's lock unusable after child"
    lock.release()
    return f"{method}: Pool, Lock, Queue ok; parent lock intact ({msg})"


def joblib_default():
    from joblib import Parallel, delayed
    got = Parallel(n_jobs=2)(delayed(sq)(i) for i in range(6))
    assert got == [0, 1, 4, 9, 16, 25], got
    return f"loky (default backend): {got}"


if __name__ == "__main__":
    mode = sys.argv[1]
    detail = joblib_default() if mode == "joblib" else start_method(mode)
    print("PROBE-OK", detail, flush=True)
