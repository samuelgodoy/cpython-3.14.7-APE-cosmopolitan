import multiprocessing as mp

def sq(x):
    return x * x

def worker_queue(q):
    q.put("hello from child")

def worker_lock(l):
    with l:
        pass
    print("CHILD: lock acquired/released OK", flush=True)

if __name__ == "__main__":
    print("start method:", mp.get_start_method())

    # 1. Lock across processes
    lock = mp.Lock()
    with lock:
        pass
    print("Lock acquire/release in parent: OK")

    p = mp.Process(target=worker_lock, args=(lock,))
    p.start()
    p.join(10)
    print("Lock child exitcode:", p.exitcode)

    # 2. Queue
    q = mp.Queue()
    p2 = mp.Process(target=worker_queue, args=(q,))
    p2.start()
    print("Queue got:", q.get(timeout=10))
    p2.join(5)
    print("Queue child exitcode:", p2.exitcode)

    # 3. Pool
    with mp.Pool(3) as pool:
        result = pool.map(sq, range(10))
    print("Pool.map result:", result)

    print("ALL MULTIPROCESSING TESTS PASSED")
