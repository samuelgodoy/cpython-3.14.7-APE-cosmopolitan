# Building CPython 3.14.7 with Cosmopolitan (cosmocc)

Engineering notes: how the build works, and why each non-obvious decision
was made. The reasoning sections are kept as a record because the *why* is
usually the part worth having later.

For the current state rather than the reasoning, see:

- [../FEATURES.md](../FEATURES.md) - what ships in the binary
- [SUCCESS.md](SUCCESS.md) - what is verified working, and where
- [PATCHES.md](PATCHES.md) - every change to CPython, Cosmopolitan and psycopg
- [WORKAROUNDS.md](WORKAROUNDS.md) - what is worked around rather than fixed
- [ERRORS.md](ERRORS.md) - what still does not work
- [HOW-TO-PATCH.md](HOW-TO-PATCH.md) - how to change the build

**Hard rules for this project:**
- Every C library CPython links against must be compiled from source with
  `cosmocc`, never pulled in from `apt`/the OS package manager. `apt`
  packages in the Docker image are host build tools only (gcc/make/autoconf
  for running `configure`/`make` themselves) — nothing they provide is ever
  linked into the final binary.
- Only pure-C (buildable with cosmocc, no other toolchain) or pure-Python
  packages are in scope. No Rust (rules out `cryptography`/pyca), no
  Fortran/meson-heavy builds (rules out `numpy`, and transitively `pandas`),
  no huge C++ frameworks like Arrow (`pyarrow`). If it can't be built with
  just `cosmocc` + `make`/`configure`/plain C, it's out of scope.

## Nothing third-party is stored in this repository

The repository holds only this project's own code and its patches. Every
external input is downloaded during the build and checked against a pinned
version and sha256:

| Input | Pinned in | Fetched |
|---|---|---|
| Ubuntu 22.04 base image | `docker/Dockerfile` (digest) | image build |
| apt host tools | `docker/Dockerfile` (`snapshot.ubuntu.com` date) | image build |
| cosmocc 4.0.2 toolchain | `docker/Dockerfile` (sha256) | image build |
| zlib, bzip2, xz, libffi, sqlite, OpenSSL, libpq | `deps/01-07-*.sh` (sha256) | image build |
| psycopg / psycopg-c 3.2.3 | `deps/08-psycopg.sh` (sha256) | image build |
| Cosmopolitan libc files to patch | `deps/09-cosmopolitan-libc.sh` (sha256) | image build |
| CPython v3.14.7 | `docker-compose.yml` (tag + commit) | every build |
| tzdata | `scripts/configure-and-make.sh` (sha256) | every build |
| Mozilla CA bundle | not pinned, by design | every build |
| joblib (tests only) | `tests/requirements.txt` (hash) | test runs |

The CA bundle is the one deliberate exception: it is fetched fresh every
build so the binary always ships current root certificates.

## Project layout

```
.
├── README.md               # entry point
├── FEATURES.md             # what ships in the binary
├── docker-compose.yml      # build / test / test-arm64 / audit services
├── docker/Dockerfile       # pinned builder image
├── deps/                   # download + build scripts for third-party sources
├── patches/
│   ├── cpython/            # NNNN-*.patch applied to CPython, in order
│   ├── cosmopolitan/       # patches to Cosmopolitan libc source files
│   └── psycopg-c/          # patches to the psycopg-c sdist
├── modules/                # this project's built-in C modules and shims
│   ├── cosmo/              #   runtime host detection, cosmo.exit()
│   ├── cosmocrypto/        #   AES over the build's OpenSSL
│   └── psycopg/            #   glue for the psycopg C accelerator
├── scripts/                # build.sh, configure-and-make.sh, test and audit runners
├── tests/                  # regression suite (the build gate)
├── docs/                   # this file and the current-state docs
├── .bin/                   # OUTPUT: python-<version>-release.com, nothing else (ignored)
├── logs/                   # OUTPUT: build/test/audit logs, BUILD-INFO.txt, SHA256SUMS (ignored)
└── .tmp/                   # local scratch space (ignored)
```

The CPython checkout and the build tree are not host folders: they live
in the Docker volumes `cpython-cosmo_cpython-src` and
`cpython-cosmo_cpython-build` (see "Why named volumes" below) and are
recreated on every build.

CPython's source is **never** stored in this repo. Every build run does a
fresh `git clone --depth 1 --branch v3.14.7` into a Docker-managed named
volume (`cpython-src`), so the pristine upstream tree is immutable and
disposable. All customization lives in `patches/cpython/*.patch`, applied with
`git apply` right after cloning, then committed locally in that throwaway
clone (the real upstream tag/history is never touched - this commit only
ever exists in a volume that gets wiped and re-cloned on the next run).
This is why `sys.version` shows something like `v3.14.7-1-g<hash>` rather
than a bare `v3.14.7`: that's `git describe` correctly reporting "1 commit
past the v3.14.7 tag" — i.e. our patches are applied. That's accurate and
intentional, not a bug to chase further; hiding it would mean pretending
this is bit-identical to vanilla CPython, which it isn't.

**No trailing `-dirty`, despite CPython's own build dirtying its source
tree.** `Modules/getbuildinfo.c`'s build rule shells out *live* to `git
describe --all --always --dirty` (configure.ac's `GITTAG`) on every single
relink, not just once at configure time. CPython's own build regenerates
several files that are tracked in git (`Python/frozen_modules/*.h`,
`Python/deepfreeze/deepfreeze.c`, etc.) via `.PHONY` `regen-frozen`/
`regen-importlib` Makefile targets that unconditionally rerun on *every*
`make` invocation - so the source tree is never actually clean by the time
`getbuildinfo.o` compiles, no matter how many times you commit and rerun
`make` (each rerun just dirties it again before getbuildinfo.o gets its
turn - confirmed empirically, a "commit after build, rebuild" approach
doesn't converge). The fix (`scripts/configure-and-make.sh`): capture
`git describe`/`rev-parse`/`name-rev`'s output once, immediately after
`build.sh`'s post-patch commit (the one point the tree is guaranteed
clean - before `make` has run at all), and pass them to every `make`
invocation as literal command-line variable overrides
(`GITVERSION="echo <hash>"`, etc.). Make command-line variables take
precedence over the Makefile's own `=` assignments, so the live
`git describe --dirty` shell command in the recipe never actually runs -
`make` substitutes the fixed, pre-captured string instead, regardless of
how many times `regen-frozen` dirties the tree afterward. Verified:
`sys.version` now reports a clean `v3.14.7-1-g<hash>` tag on every build,
identically on Windows and Linux from the same binary.

## Why named volumes instead of bind mounts

Docker Desktop on Windows (WSL2 backend) was unstable (`WSL ... ERROR:
UtilBindVsockAnyPort`) specifically when compiling heavily through a
Windows bind mount. The toolchain is downloaded into the image (not bind
mounted), and the cloned source + build tree live in Docker-managed named
volumes (inside the WSL2 VM's own filesystem), never touching the Windows
filesystem. Only small things cross the boundary: `patches/cpython/`,
`modules/`, `scripts/`, `tests/`, and the `.bin/` and `logs/` outputs.

If the vsock error resurfaces, or if `docker compose run` behaves
inconsistently between two runs for no apparent code reason, wipe the named
volumes and start clean before spending time debugging further — we hit
real, reproducible container/volume-state corruption once (see git history
around the `sys.platform` false alarm) that a full `docker volume rm
cpython-cosmo_cpython-src cpython-cosmo_cpython-build` fixed instantly:

```bash
docker volume rm cpython-cosmo_cpython-src cpython-cosmo_cpython-build
```

## A note on WSLInterop

Cosmopolitan's APE binaries start with a DOS/MZ header (they're valid
PE/ELF/Mach-O/shell-script polyglots). Inside WSL2, Windows' `WSLInterop`
binfmt handler intercepts that MZ header and tries to hand the file to the
Windows PE loader instead of letting Linux run it as the POSIX shell-script
polyglot it actually is — this breaks `cosmocc` itself (it invokes its own
APE-format subtools). Fix (until the next WSL/Docker Desktop restart):

```powershell
wsl -d docker-desktop -u root -- sh -c "echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop"
```

**Know the symptom, because it doesn't look like this.** When WSLInterop
is intercepting, the failure surfaces as the *first* thing that tries to
compile something — in practice zlib's `configure`, which reports:

```
Compiler error reporting is too harsh for ./configure (perhaps remove -Werror).
```

That message is a red herring: nothing is wrong with the compiler flags.
`cosmocc` simply can't execute at all, so every compile probe fails. You
may also see WSL noise on stderr like `UtilGetPpid: Failed to parse:
/proc/1/stat`. Before debugging any build failure that looks like a broken
toolchain, check whether the handler is registered:

```powershell
wsl -d docker-desktop -u root -- sh -c "cat /proc/sys/fs/binfmt_misc/WSLInterop"
```

`enabled` with `magic 4d5a` ("MZ") means it is intercepting APE binaries —
apply the fix above. Writing `-1` unregisters the entry entirely, so the
file disappears; that is success, not an error. This resets on every
WSL/Docker Desktop restart, so it recurs.

## sys.platform is stuck as "linux" (deliberately, permanently)

We tried making `Py_GetPlatform()` detect the real host OS at runtime via
Cosmopolitan's `IsWindows()`/`IsXnu()`/etc. so `sys.platform` would
correctly say `win32` when the binary runs on Windows. This **broke the
interpreter**: CPython's frozen `importlib._bootstrap_external` (baked into
the binary at build time) branches on `sys.platform == 'win32'` to decide
whether to `import nt` or `import posix` for OS-level primitives. Our build
is a POSIX `./configure` build — only the `posix` C module exists, `nt` was
never compiled — so telling it `sys.platform == 'win32'` while only `posix`
exists crashes startup with `ModuleNotFoundError: No module named 'nt'`.

`sys.platform`/`os.name` are load-bearing compile-time facts in CPython, not
cosmetic strings — they select which OS-personality module set was actually
built. Since we only ever build the POSIX personality (cosmocc gives us a
real POSIX layer on every target OS, which is the entire point), the correct
and only safe value is `sys.platform == 'linux'` everywhere, permanently.
This is not a bug — the filesystem/OS interop test suite (24/24 on both
Windows and Linux) confirms the actual behavior is correct even though the
string says "linux". Code that specifically wants to know "am I really on
Windows" needs a different signal than `sys.platform`/`os.name` here; we
haven't needed one yet.

## Known limitations

- **`ctypes` cannot call foreign code**: `ctypes.pythonapi` / `CDLL(None)`
  are unavailable (APE is fully static; no `dlopen(NULL)` to reach the
  running executable's own symbols), and **`CFUNCTYPE` callbacks segfault
  on invocation** - creating one succeeds, calling it crashes. Found by
  the CPython audit (`test_ctypes.test_random_things`); ruled out
  executable-memory permissions as the cause with a standalone C repro
  (both `mmap(PROT_EXEC)` and `mprotect(RW->RX)` work fine under
  Cosmopolitan), so it is something in libffi's closure allocation, most
  likely related to the same unreliable `/dev/shm` that patch 0009 had to
  work around. **Deliberately not pursued**: with no loadable library
  there is no foreign function to pass a callback to, so the feature has
  no consumer here even if it worked. `ctypes` data types, `Structure`,
  `Union`, arrays, `sizeof` and `byref` all work fine, and that
  memory-layout use is the only ctypes use this build supports.
- **Compiled (non-pure-Python) pip packages**: cannot be installed. See
  "pip and compiled packages" below — this is structural, not a missing
  feature we can add later without a fundamentally different design.
- **`os.symlink` on Windows**: needs Developer Mode or admin, exactly like
  real native Windows Python. Not cosmo/cosmocc-specific.
- **`multiprocessing`'s `forkserver` start method**: hangs; never use it
  explicitly (`get_context('forkserver')`). `fork` is the default here and
  works - see "ProcessPoolExecutor and compileall" below. Nothing in the
  stdlib reaches for `forkserver` on its own any more (patch 0012).
- **Raw `AF_UNIX` sockets on Windows**: `bind()` fails for absolute paths
  and for relative paths under 13 characters. Only affects code binding
  Unix-domain sockets directly; nothing in the stdlib's own paths hits it
  after patch 0011. Details in "ProcessPoolExecutor and compileall" below.
- **Process exit codes are lost on Windows**: see the next section. This
  one matters for automation, so it's worth reading before wiring
  `python.com` into any script that checks whether it succeeded.
- **`os.environ` is case-sensitive on Windows**: native Windows Python
  folds environment variable names (`os.environ['PATH']` and
  `['Path']` are one key); this build doesn't, being a POSIX personality.
  Shells disagree on spelling too - git-bash exports `SYSTEMROOT`, cmd
  uses `SystemRoot` - so code looking for a specific variable on Windows
  should fold case itself. Covered by `tests/test_cosmo_module.py`.

## Exit codes don't survive back to a Windows shell

A cosmocc-built binary exits with the **POSIX wait status** rather than the
exit code when it returns to Windows — i.e. the code shifted left by 8:

| `sys.exit(n)` | PowerShell `$LASTEXITCODE` | git-bash `$?` |
|---|---|---|
| 0 | 0 | 0 |
| 1 | 256 | 0 |
| 2 | 512 | 0 |
| 42 | 10752 | 0 |
| 255 | 65280 | 0 |

PowerShell sees `n * 256` (recoverable — divide by 256). MSYS/git-bash
takes the low byte, which is always zero, so **every run looks
successful**, including crashes and failed test runs. That silent-success
mode is the dangerous part.

Not Python-specific: a three-line C program built with `cosmocc` that just
`return 3;` behaves identically, so this is in the APE runtime, below
anything this project controls — there is nothing to patch here. Linux and
macOS are unaffected, and exit codes *within* a process tree (`subprocess`,
`multiprocessing`, the test runner's per-module checks) are fine — it is
only the final hand-off out to Windows that is lossy.

The practical consequence, and the reason `tests/run_all.py` prints a
`RESULT: PASS`/`RESULT: FAIL` line: on Windows, decide success by parsing
output, not by reading an exit code. `scripts/run-tests.sh` does exactly
that and works correctly on both platforms.

## multiprocessing: two real cosmocc bugs, found and fixed

`Lock`/`Queue`/`Pool` used to hang or crash here. Both underlying bugs are
now understood and fixed - this is worth documenting in full because the
debugging path is reusable if something similar turns up elsewhere.

**Bug 1: `sem_getvalue()` returns success with a garbage count.**
`multiprocessing.synchronize.Lock`/`Semaphore.release()` sanity-checks
against `maxvalue` using `sem_getvalue()` before posting. Cosmopolitan's
`sem_getvalue()` doesn't error, but the count it writes back is garbage
(confirmed with a minimal standalone C repro - `sem_getvalue` after a
known-good `sem_post`/`sem_wait` sequence returned `4128480`). Every
`release()` call then spuriously fails with `ValueError: semaphore or lock
released too many times`, even for a correctly-paired acquire/release.
CPython already ships an alternate code path for exactly this failure mode
(`HAVE_BROKEN_SEM_GETVALUE`, defined historically for real platforms with
the same issue) that never trusts the returned count - `configure`'s own
detection just doesn't catch this specific flavor of "broken" (it only
checks whether the call errors, not whether the value is sane), so
`scripts/configure-and-make.sh` forces the define directly into
`pyconfig.h` after `configure` runs.

**Bug 2: a semaphore reconnected by name in a spawned child is silently
disconnected from the parent's.** With bug 1 fixed, `Lock.acquire()` in a
`spawn`-created child still timed out forever. Isolated with a minimal
Python repro (`_multiprocessing.SemLock._rebuild` calls `sem_open(name, 0)`
- that's the whole reconnect mechanism on POSIX) and a battery of
standalone C reproductions to rule out hypotheses one at a time:
- A plain `sem_open`/`sem_post`/`sem_wait` round trip between two
  *independent* processes (one exits, then the other opens by name): works.
- The same, but with the poster staying alive while a second, genuinely
  concurrent process opens and waits: works.
- The poster `fork()`+`exec()`ing the waiter directly (matching how
  `spawn` actually creates its child): works.
- The same, with the child closing every fd above 2 before `exec`
  (matching `_posixsubprocess.fork_exec(..., close_fds=True, passfds)`,
  which is exactly what `multiprocessing`'s spawn bootstrap does): works.

All four ruled out. The one thing that reliably reproduced the failure was
a *real, multi-threaded Python interpreter* reconnecting the semaphore via
`_rebuild`, which none of the minimal C repros are. The exact mechanism
inside Cosmopolitan's semaphore implementation that a real Python process
trips and a small C program doesn't is still unidentified - we don't have
its source, only the precompiled `libc.a`/headers, which limits how far
this can be pushed from here.

**The fix**: sidestep the whole reconnect-by-name mechanism. `fork()`
doesn't need it at all - the child inherits the semaphore's shared memory
directly via normal `fork()` semantics, and this is verified fully working
(`Lock`, `Queue`, `Pool.map`) on both Windows and Linux. Patch 0006 changes
`multiprocessing`'s default start method to `'fork'` (previously changed to
`'spawn'` earlier in this project's history, when `forkserver`'s AF_UNIX
listener was the only known-broken piece - `fork()` wasn't tried yet
because named-Windows-semaphore-via-fork felt like it shouldn't work
before it was actually tested). No `set_start_method()` call is needed;
`multiprocessing.Lock()`/`Queue()`/`Pool()` just work.

**`Arena`'s `/dev/shm` probe (patch 0009).** `multiprocessing.heap.Arena`
picks `/dev/shm` over a regular temp dir when available, checking with
`os.statvfs()`. This build's synthetic `/dev/shm` reports a plausible-but-
fake `statvfs()` result (looks like a working tmpfs mount with free space)
without actually supporting file creation there - real Linux guarantees
`/dev/shm` works, which is why upstream never double-checks past `statvfs`.
Fixed by adding a real `tempfile.mkstemp()` create+delete probe alongside
the `statvfs` check, falling back to `util.get_temp_dir()` on any `OSError`
(first iteration only guarded the `statvfs()` call itself, which wasn't
the actual failure point - insufficient until the real-file-creation probe
was added). Confirmed fixed via `multiprocessing.Barrier`, which allocates
through this path.

## ProcessPoolExecutor and compileall (patches 0012 + 0013)

`ProcessPoolExecutor` works here. Getting there took two wrong turns worth
documenting, because both were caused by *reasoning* errors rather than by
anything actually broken in the build - and the first "fix" made things
worse in a way that looked convincing.

**Symptom**: `make install`'s `compileall.py -o0 -o1 -o2 -j0 ...` step
(pre-compiling the embedded stdlib's `.pyc` files) hung indefinitely - the
build container sat at 0% CPU with no log output for as long as it was left
running. `ps aux` inside the container showed a `forkserver` process plus a
dozen idle worker processes, all in state `S` (sleeping), none making
progress.

**What actually hangs**: only the `forkserver` start method. `Lib/compileall.py`'s
parallel path contains:
```python
if multiprocessing.get_start_method() == 'fork':
    mp_context = multiprocessing.get_context('forkserver')
```
Upstream deliberately refuses to use `fork` directly for this pool (forking
a process that has already imported much of the stdlib is risky in general)
and switches to `forkserver` whenever the default is `fork` - which patch
0006 makes our permanent default. So `compileall.py` is the one and only
stdlib caller that *forces* the broken method; nothing else reaches for it.

**Wrong turn #1 - the guard that hid the problem.** `compileall.py` only
attempts the parallel path if a guard passes first:
```python
try:
    _check_system_limits()   # concurrent.futures.process
except NotImplementedError:
    workers = 1               # fall back to serial - safe
else:
    from concurrent.futures import ProcessPoolExecutor
```
`_check_system_limits()` calls `os.sysconf("SC_SEM_NSEMS_MAX")`, which
raises `OSError` (errno `EINVAL`) on this build rather than the
`ValueError`/`AttributeError` upstream anticipates for "sysconf doesn't
know this name". Uncaught, that `OSError` aborted `compile_dir()` with a
raw traceback that `make install`'s `-` prefix ignored ("Error 1 (ignored)"
in older logs) - so the stdlib's `.pyc` files silently never got
pre-compiled. An early version of patch 0010 "fixed" that by catching the
`OSError` and returning - which removed the accidental guard and let
`compileall.py` proceed straight into the `forkserver` deadlock. A
harmless, ignorable error had been turned into an unbounded build hang.

**Wrong turn #2 - blaming the wrong component.** The next attempt made
`_check_system_limits()` raise `NotImplementedError` instead, on the
reasoning that `ProcessPoolExecutor` "always ends up needing `forkserver`"
and should therefore fail fast and loudly. That stopped the hang, and the
`NotImplementedError` was clean and well-documented - but the premise was
simply wrong, and it disabled a feature that works. The mistake was never
testing `ProcessPoolExecutor` on its own: every observation came from
`compileall.py`, which is the one caller that overrides the context.

**What's actually true**: `ProcessPoolExecutor()` uses `mp.get_context()` -
the *default* context, which patch 0006 pins to `fork`. `fork` is already
proven working here (it's what makes `multiprocessing.Lock`/`Queue`/`Pool`
work). Verified directly, by bypassing the guard and exercising the real
API: `map`, `submit`/`Future`, and context-manager shutdown all work
correctly with both the explicit `fork` context and the default one, on
Windows and on Linux.

**The fix** is therefore the inverse of wrong turn #2:
- **Patch 0012** stops `compileall.py` forcing `forkserver`, leaving
  `mp_context = None` so it uses the default (`fork`) context like any
  other caller.
- The `OSError` itself is handled at its source by **patch 0013**, so
  `_check_system_limits()` sees the `-1` sentinel it expects and
  `ProcessPoolExecutor` becomes available. (Originally this was a
  narrower patch 0010 against `concurrent.futures` alone; a later audit
  against CPython's own test suite showed the problem was general, and
  0010 was replaced by 0013 — see "os.sysconf's EINVAL" below.)

Verified after rebuilding: `ProcessPoolExecutor` works natively (no
bypass) on Windows and Linux, and `make install`'s `compileall.py` step now
genuinely runs and compiles the stdlib in parallel - the "Error 1
(ignored)" line is gone from the build log too, since nothing raises any
more.

### How far the forkserver investigation got

`forkserver` itself is still broken, and is now the only thing that is. The
layers were isolated one at a time on Linux, which ruled out the obvious
suspects:

- Raw `AF_UNIX` `bind()`/`listen()`/`connect()`/`accept()`, using the exact
  `multiprocessing.util.get_temp_dir()`-based paths `forkserver` generates:
  **works**.
- Real `SCM_RIGHTS` file-descriptor passing (`socket.send_fds`/`recv_fds`)
  over a connected `AF_UNIX` pair: **works**.
- `get_context('forkserver').Pool(2)` creating its worker processes (fork +
  challenge/response authentication handshake): **works** - construction
  completes.
- Dispatching a task to a worker: **hangs**. Confirmed by having the worker
  function write a marker file as its very first statement - the file is
  never created, so the task never arrives. The stall is in `Pool`'s
  internal task queue (a `Pipe` guarded by a `Lock` backed by
  `_multiprocessing.SemLock`), not in socket I/O.

That profile matches the unresolved Bug 2 above (a real, multi-threaded
Python process reconnecting a named semaphore via `sem_open` fails
silently, cause unidentified, no Cosmopolitan Libc source available).
`forkserver`'s workers are `fork()`ed from the *forkserver helper*, not
from the original parent, so primitives shared with the caller must be
reconnected by name - hitting Bug 2 through a different code path than the
original `spawn` repro. Not a new bug, and nothing further to fix: `fork`
never needs name-based reconnection, and it is the default.

### A separate, real AF_UNIX bug (Windows only)

Turned up while isolating the above, unrelated to the hang. On **Windows**,
`bind()` on an `AF_UNIX` socket fails outright - an immediate error, not a
hang - for **any absolute path** (`OSError: [Errno 10050] Network is
down`), regardless of length, and for **relative paths shorter than 13
characters** (`OSError: [Errno 87] Invalid argument`). Relative paths of
13+ characters bind correctly. This is almost certainly why `forkserver`'s
Windows failure mode was originally an immediate "Network is down" rather
than the Linux hang - `multiprocessing.util.get_temp_dir()` always returns
an absolute path. Nothing in the stdlib's own paths depends on this any
more (patch 0011 moved `Manager` to `AF_INET`), so it's documented rather
than worked around; it would only bite code binding Unix-domain sockets
directly on Windows.

## multiprocessing.Manager on Windows: fixed via AF_INET (patch 0011)

`Manager()` used to fail on Windows with `EOFError`/`OSError: [Errno 10045]
Operation not supported`, while working fine on Linux - traced to the same
family of `AF_UNIX` unreliability documented above, but fixable here
because `Manager`'s protocol doesn't need anything AF_UNIX-specific.

**Root cause**: `multiprocessing.connection`'s `default_family` picks
`'AF_UNIX'` whenever `hasattr(socket, 'AF_UNIX')` is true - which it is in
this build (cosmocc provides the constant even though the underlying
support is unreliable on real Windows). `BaseManager.__init__` passes
`address=None` through to `Listener`, which then resolves to an arbitrary
`AF_UNIX` address by default. Unlike `forkserver` (see above), `Manager`'s
own wire protocol is just pickled proxy requests/responses over a plain
byte stream - it never uses `AF_UNIX`-specific features like `SCM_RIGHTS`
file-descriptor passing, so the address family is an implementation detail
with a safe substitute available.

**The fix**: patch 0011 changes `BaseManager.__init__` so that when
`address` is `None` (i.e. the caller didn't explicitly ask for a specific
address/family), it defaults to `('127.0.0.1', 0)` - an ephemeral-port
loopback `AF_INET` address - instead of falling through to `Listener`'s
`AF_UNIX` default. `Listener`/`Client` already fully support `AF_INET`
(it's the cross-platform default on real Windows in upstream CPython,
exactly for this class of problem), so this is a small, targeted change:
one `if` block, no protocol changes. Verified: `Manager().dict()`
round-trips real data correctly on **both** Windows and Linux now. This
doesn't help `forkserver`, which needs `AF_UNIX`'s `SCM_RIGHTS`
file-descriptor passing and has no `AF_INET` equivalent - but nothing
depends on `forkserver` any more (see above).

## Importing from a thread: two bugs behind one error

Importing a large stdlib module from a non-main thread used to die with:

```
MemoryError: Parser stack overflowed - Python source too complex to parse
```

Found by the CPython test-suite audit (`test_multiprocessing_fork`, and
all three `test_importlib` failures were `test_threaded_import`). It is
reachable in ordinary use — any lazy import inside a worker thread, and
anything importing through `multiprocessing.managers`' accepter thread.
Two independent causes had to be fixed.

**Cause 1: the stdlib shipped as source only.** The build byte-compiled
nothing and excluded `*.pyc` from the zip, so every import parsed source
at runtime, forever — there is no writable cache to amortize into. That
put the PEG parser on the call stack for every import.

Getting this right took two wrong attempts, both worth recording:

- *`/zip` is not served by `zipimport`.* The obvious assumption is that an
  APE's embedded zip is read by `zipimport`, which only understands the
  legacy `foo.pyc`-beside-`foo.py` layout — so the first fix used
  `compileall -b`. Wrong: Cosmopolitan's zipos presents `/zip/...` as a
  **real filesystem**, so CPython's ordinary `FileFinder`/
  `SourceFileLoader` handles it and looks only in `__pycache__/`.
  Confirmed at runtime: `email.header.__loader__` is `SourceFileLoader`
  and its `__cached__` is
  `/zip/.../email/__pycache__/header.cpython-314.pyc`. The `-b` build
  shipped 1067 `.pyc` that nothing could ever load. The script had also
  been *deleting* `__pycache__` before zipping to save space — which was
  the original cause.
- *Timestamp invalidation can't work in a zip.* A default `.pyc` records
  the source's mtime and size and is discarded unless they still match.
  Zip entries store time with DOS granularity (2 seconds, no timezone),
  so the mtime never matches and every `.pyc` is judged stale.
  `--invalidation-mode unchecked-hash` (PEP 552) drops that check, which
  is exactly right for bytecode frozen into a read-only artifact.

Net effect once correct: importing the heavy chain went from 0.369s to
0.080s, and interpreter startup from 0.042s to 0.029s.

**Cause 2: Cosmopolitan's thread stack is much smaller than glibc's.**
Shipping bytecode avoids the parser for stdlib imports, but anything that
*does* parse source in a thread still died. Isolated cleanly: `import
asyncio` inside a `threading.Thread` fails at the default stack size and
succeeds verbatim after `threading.stack_size(8 << 20)`.

Fixed with `THREAD_STACK_SIZE` in `pyconfig.h` (CPython's own knob for
this — see `Python/thread_pthread.h`), set to 8MB to match what glibc
gives the main thread. `configure` leaves it undefined because on a normal
POSIX platform the OS default is already generous; that assumption doesn't
hold here. This restores the environment the stdlib is written against
rather than inventing a new one.

`tests/test_import_in_thread.py` covers both, including asserting that
bytecode is genuinely being loaded — otherwise the thread tests could pass
by luck on a roomier stack while the `.pyc` silently stopped shipping.

## Key build decisions

- `MODULE_BUILDTYPE=static` + `--disable-shared`: cosmocc cannot produce
  `-shared` objects (APE has no dynamic loader), so every stdlib extension
  module is linked statically into the single `python.com` instead of
  building `.so` files.
- `--prefix=/zip/usr/local`: baked into the binary as CPython's compiled-in
  fallback prefix. At runtime, Cosmopolitan's `zipos` maps `/zip/...`
  transparently onto a zip archive appended to the running executable, so
  `import encodings` etc. work from a single file with no install step, on
  any OS.
- `--with-openssl=/opt/cosmocc`: points CPython's `ssl`/`hashlib` detection
  at where `deps/06-openssl.sh` installs headers/libs. Needed because
  (unlike zlib/bz2/sqlite3) CPython's configure.ac only searches a fixed
  list of conventional OpenSSL install prefixes for `ssl.h`, not the
  compiler's own default include path.
- `--disable-test-modules`, `--without-readline`, `--without-pymalloc`:
  trimmed; readline would need a cosmo-built libedit/readline (not done -
  low value, `input()` still works, just without fancy line editing).
- A Mozilla CA bundle (`cacert.pem`, fetched fresh at build time from
  `curl.se/ca/cacert.pem`) is embedded in the zip next to the stdlib and
  loaded as a fallback root store by patch 0007, because this build's
  OpenSSL has no real `--openssldir` on the machine that actually runs
  `python.com`.

## Running a build

```bash
docker compose build              # builder image: once, and after changing docker/ or deps/
docker compose run --rm build     # -> .bin/python-3.14.7-release.com
```

On Windows under Git Bash, prefix every `docker` command with
`MSYS_NO_PATHCONV=1`, or Git Bash rewrites the container-side paths.

`build` clones CPython, verifies the commit, applies `patches/cpython/`,
compiles, runs the test suite against the result, and only then copies the
binary into `.bin/`. `.bin/` always holds exactly one file. Everything else
- `configure.log`, `make.log`, `install.log`, the test transcript,
`BUILD-INFO.txt` (what went into the binary) and `SHA256SUMS` - goes to
`logs/`.

**The third-party sources are built into the image, not on every run.**
The C libraries (compiled twice each, once per architecture), psycopg and
the patched Cosmopolitan files are produced by a `RUN` layer in
`docker/Dockerfile`. That is most of a from-scratch build, and it is
identical every time, so caching it takes a build from ~16 minutes to ~5.
The trade: after editing anything in `deps/`, `patches/psycopg-c/` or
`patches/cosmopolitan/`, run `docker compose build` before building again.

### Reproducibility

- Every input is pinned (table above), and the CPython tag must resolve to
  the pinned commit or the build stops.
- `SOURCE_DATE_EPOCH` is set to the upstream commit time. GCC uses it for
  `__DATE__`/`__TIME__`, the patch commit uses it (so the `g<hash>` in
  `sys.version` depends only on the patches), and every entry of the
  embedded zip gets that timestamp.
- The embedded zip is written in sorted order without extra fields, and
  the stdlib bytecode uses hash-based invalidation, which records no
  timestamps.
- The third-party libraries are built with `SOURCE_DATE_EPOCH` set to the
  apt snapshot date (`DEPS_SOURCE_DATE_EPOCH`), so e.g. OpenSSL's
  "built on" string does not depend on when the image was built.

Verified: two builder images rebuilt from scratch (`--no-cache`) produced
byte-identical `python.com` binaries.

### Caching

- Each dependency in `deps/` is its own image layer, ordered from most
  stable to most edited; changing a psycopg or Cosmopolitan patch rebuilds
  only those last steps, not OpenSSL/libpq.
- All downloads (cosmocc included) go through a BuildKit cache mount keyed
  by sha256, which survives `--no-cache`; files are re-verified on reuse.
- The CPython checkout and object files live in the `cpython-src` and
  `cpython-build` volumes between runs.

The CA bundle is fetched fresh, so two builds reproduce the same binary as
long as Mozilla has not published a new bundle in between.

## Testing

`tests/` is the regression suite, and it runs as a gate at the end of every
build.

```bash
docker compose run --rm test         # Linux x86_64
docker compose run --rm test-arm64   # Linux aarch64, emulated with QEMU
./scripts/run-tests.sh               # on a Windows host, from Git Bash
```

The container runs also install the pinned test-only extras from
`tests/requirements.txt` (joblib, to exercise a third-party process pool)
and write their transcript to `logs/test-<target>.log`. The same file is a
different OS personality on Windows, so run the suite there too after any
change worth trusting.

Structure: `tests/run_all.py` discovers every `tests/test_*.py` and runs
each as a **separate subprocess** of the interpreter under test, so a crash
or hang is attributed to the module that caused it. Modules use
`tests/harness.py`: `check(name, fn)` per assertion and `report()` at the
end. A check can `raise Skip(...)` when it depends on the environment
rather than on the build (`os.symlink` without Developer Mode, joblib not
installed). Work that needs `spawn`/`forkserver` lives in
`tests/_start_method_probe.py` and is run by subprocess, because `spawn`
re-imports `__main__` and the test modules run their checks at import
time.

The verdict is the `RESULT: PASS` / `RESULT: FAIL` line, not the exit
code: on Windows the exit code does not survive (see "Exit codes don't
survive back to a Windows shell"). `run-tests.sh` handles this.

### Auditing against CPython's own test suite

`tests/` is this project's evidence, but it's hand-written and therefore
only covers what someone thought to check. `scripts/audit-cpython-tests.sh`
runs a curated subset of **upstream CPython's** regression suite against
the built binary, which exercises corners nobody here anticipated:

```bash
docker compose run --rm audit                        # the default module list
docker compose run --rm audit test_socket test_ssl   # specific modules
```

Per-module transcripts are written to `logs/audit/`.

It needs no special build: `test` is a pure-Python package, so the script
copies it out of the CPython source tree in the `cpython-src` volume and
puts *only* that package on `PYTHONPATH`. The stdlib under test stays the
one embedded in the binary, which is the entire point — pointing
`PYTHONPATH` at the whole source `Lib/` instead would silently test the
source tree rather than the artifact.

This is an **audit, not a gate**, and is deliberately not wired into the
build. Expect failures, and expect a meaningful share of them to be
legitimately inapplicable rather than bugs — upstream tests assume things
this build knowingly doesn't provide (`dlopen`, `_testcapi`, a truthful
`sys.platform`, `forkserver`). Triage the output; don't just count it.

**Read failures against the harness's blind spot before believing them.**
Upstream leans on `test.support.script_helper.assert_python_ok()`, which
runs a snippet in an `-I` (isolated) subprocess. `-I` ignores
`PYTHONPATH`, so the staged `test` package is invisible to that child, and
any snippet doing `from test import support` dies with
`ModuleNotFoundError` and empty stderr — the parent then reports only
"Process return code is 1". Nothing is wrong with the binary. This
accounts for most of `test_threading`'s failures and probably some of
`test_os`/`test_socket`/`test_subprocess`/`test_venv`'s. Closing the gap
properly needs an audit build that keeps `Lib/test` embedded (the normal
build trims it), so `test` is importable without `PYTHONPATH`. Until then,
read the traceback in `logs/audit/<module>.log` before counting a
failure as a defect.

#### First audit results

Roughly **3,900 upstream tests executed**, 12 of 20 modules fully clean:

| Clean | Failures |
|---|---|
| `test_posixpath`, `test_io`, `test_select`, `test_tempfile`, `test_shutil`, `test_zipimport`, `test_sqlite3`, `test_ssl`, `test_hashlib`, `test_zlib`, `test_bz2`, `test_lzma` | `test_os` (7/377), `test_socket` (9/749), `test_subprocess` (5/353), `test_threading` (8/228), `test_signal` (3/57), `test_importlib`, `test_multiprocessing_fork` |

That `test_sqlite3` (510 tests), `test_ssl` (196) and `test_io` (667) pass
outright is a much stronger statement about those subsystems than
anything in `tests/` here.

**Full triage, after reading every saved log: no confirmed defect in this
build.** Every failing module was classified (`logs/audit/`):

| Module | Failures | Verdict |
|---|---|---|
| `test_os` | 6 of 377 | 1 harness blind spot (`test_fork` via `assert_python_ok` — `os.fork()` itself works and is covered by `tests/`), 2 unsupported syscalls (pty, `sched_getaffinity`), 3 `errno` wording on bad fds |
| `test_socket` | 8 of 749 | 5 Linux abstract `AF_UNIX` namespace (not implemented), `testGetServBy` needs `/etc/services`, `testGetaddrinfo` resolver edge, `testIPv4toString` — Cosmopolitan's `inet_pton` accepts the malformed `'0.0.0.'` |
| `test_subprocess` | 5 of 353 | 4 need a real `nobody` user and setuid; 1 fd-swap edge case |
| `test_signal` | 3 of 57 | 1 harness blind spot, 2 signal-name/table differences |
| `test_multiprocessing_fork` | 4 of 438 | abstract `AF_UNIX`, `get_all_start_methods` expecting `forkserver`, and 2 manager-related — all in already-documented territory |
| `test_venv` | crash in regrtest | `venv` itself works and is covered by `tests/` and patch 0004 |
| `test_ctypes` | SIGSEGV | callbacks, documented above — no consumer without `dlopen` |

The single finding of any substance is `inet_pton` being laxer than glibc
about trailing-dot IPv4 strings. Cosmetic, upstream's business, and not
worth a patch here.

Triaging the named failures:

- **Genuinely inapplicable** — the build knowingly lacks the feature:
  `test_process_cpu_count_affinity` (no `sched_getaffinity`),
  `test_posix_pty_functions` (pty), `TestLinuxAbstractNamespace` ×4
  (Linux's abstract `AF_UNIX` namespace), `test_user` ×4 (needs a real
  `nobody` user and setuid privileges, absent in the build container).
- **Semantic deviations, cosmetic** — Cosmopolitan reports different
  `errno`/strings than glibc for edge cases: `test_fpathconf_bad_fd`,
  `test_pathconf_negative_fd_uses_fd_semantics`, `test_ttyname`,
  `test_strsignal`, `test_valid_signals[SIGEMT]`.
- **One real bug, found and fixed**: `test_multiprocessing_fork` reported
  `run=0` — it never started, because its `check_enough_semaphores()`
  helper calls `os.sysconf("SC_SEM_NSEMS_MAX")` and got `OSError`. Same
  root cause this project had already patched in *one* caller
  (`concurrent.futures`); the audit showed it was broader than that and
  belonged at the source. See patch 0013 below.
- **Not yet triaged**, worth a look if any of these subsystems misbehave:
  `test_os.test_fork`, `test_socket`'s `testGetaddrinfo`/`testIPv4toString`/
  `testClose`/`testGetServBy`, `test_subprocess.test_swap_std_fds_with_one_closed`,
  `test_signal.test_interprocess_signal`, and `test_threading`'s 8
  failures (names not captured — rerun with `-v`).

That single fix justified the exercise: it was invisible to `tests/` here
because nothing in it called `os.sysconf` directly.

### os.sysconf's EINVAL is "indeterminate", not an error (patch 0013)

`sysconf()` under Cosmopolitan sets `errno = EINVAL` for names it
recognizes but cannot answer — `_SC_SEM_NSEMS_MAX` being the one that bit
us. glibc instead returns `-1` and leaves `errno` untouched, which POSIX
defines as "indeterminate; limited only by available resources". CPython's
`os_sysconf_impl` raises `OSError` whenever `sysconf()` sets `errno`, so
on this build every caller written against the `-1` sentinel got an
exception instead.

This was originally patched in exactly one place
(`concurrent.futures.process._check_system_limits`, old patch 0010) —
which fixed the symptom that had been noticed and nothing else. The audit
showed the same failure in `multiprocessing`'s own test helper, i.e. the
problem was general.

Patch 0013 normalizes it at the source, in `Modules/posixmodule.c`: if
`sysconf()` returns `-1` with `EINVAL`, clear `errno` so the `-1`
propagates as glibc's indeterminate sentinel. This is safe because
`conv_confname()` has already validated the name against CPython's own
table before `sysconf()` is called — EINVAL at that point cannot mean
"unknown name", only "this libc has no answer". Old patch 0010 was
**removed**: with 0013 in place its `OSError` branch is unreachable, and
leaving it would have meant carrying a patch whose stated premise is no
longer true.

## Building a third-party C dependency

See `deps/common.sh`. cosmocc's fat-binary trick only really applies
at the *final link* stage (it compiles+links twice, once per real arch
compiler, then `apelink`s the two executables together). A plain
`cosmocc`/`cosmoar`-built static library does NOT reliably work for both
archs later (confirmed empirically: `aarch64 failed to link executable:
cannot find -lz` when the .a was built via the fat `cosmocc` wrapper). The
robust pattern used by every dep (`zlib.sh`, `libffi.sh`, `bzip2.sh`,
`xz.sh`, `sqlite3.sh`, `openssl.sh`):

1. Build once with `x86_64-unknown-cosmo-cc`/`-ar`, once with
   `aarch64-unknown-cosmo-cc`/`-ar` (the single-arch-but-still-APE wrapper
   compilers - NOT the raw `{arch}-linux-cosmo-gcc`, which needs manual ABI
   flags we don't want to hand-maintain).
2. `{arch}-linux-cosmo-ranlib` works fine for indexing either arch's archive.
3. Install the arch-independent headers into `$COSMOCC/include` (shared).
4. Install each arch's static lib into `$COSMOCC/{arch}-linux-cosmo/lib/`.
   cosmocc's fat driver already searches these dirs by default, so usually
   nothing extra is needed in CPython's own `./configure` invocation - it
   just finds `-lz`/`-lffi`/etc. like it finds its own libc. (OpenSSL is the
   exception - see `--with-openssl` above.)
5. Watch out for headers that are genuinely arch-specific content (like
   libffi's `ffitarget.h`) - those can't be shared as-is; ship both variants
   under arch-tagged names plus a tiny `#if defined(__x86_64__) ... #elif
   defined(__aarch64__) ...` dispatcher header (see `deps/04-libffi.sh`).
6. After extracting the tarball, flatten every file's mtime to the same
   instant (`find src -exec touch -t 202001010000 {} +`). Tarball extraction
   can leave mtimes out of order, tricking autotools-generated Makefiles
   into thinking `configure.ac`/`Makefile.am` changed and trying to
   regenerate with an `aclocal`/`automake` version we don't have installed.
   Repeat this touch again after `cp -r`-ing the source into each arch's
   build dir, since the copy itself can re-shuffle mtimes for a large tree.

## pip and compiled (non-pure-Python) packages

`pip` (pure Python) works, and **real installs from PyPI over HTTPS are
verified working** (`pip install requests` succeeds and the installed
package runs, on both Windows and Linux, from the exact same binary).

Installing packages with C extensions does not work, for two independent,
structural reasons - this cannot be fixed without a fundamentally different
design:
1. No prebuilt wheel on PyPI targets cosmocc/Cosmopolitan's ABI, so pip
   falls back to building from source (sdist).
2. Building from source shells out to `cosmocc` as a *separate* process.
   That process's own Cosmopolitan `zipos` (`/zip/...`) is scoped to its
   own embedded zip, not `python.com`'s — so it can't even see Python.h and
   friends to compile against.

In practice pip's own dependency resolver already tends to fail cleanly on
these (no compatible wheel found) rather than limping into a confusing
compiler error - verified with `requests` and its pure-Python dependency
tree. Packages that genuinely need a compiled extension (the ones ruled out
by the "pure C/pure Python only" project rule above) simply aren't
installable here.

**Verified empirically** (this matters enough to spell out, since it's a
natural question): even a *prebuilt* wheel with a matching OS/arch/ABI tag
cannot work here, on either OS. Tested with `msgpack` (small package,
ships both a C extension and a pure-Python fallback, so failure is easy to
observe cleanly):
- `.pyd` from a `win_amd64` wheel, run on Windows: fails to import.
- `.pyd` from a `win_amd64` wheel, run on Linux: fails to import.
- `.so` from a `manylinux2014_x86_64` wheel, run on Linux: fails to import.
- In all three cases `import msgpack` "succeeds" because msgpack silently
  falls back to its pure-Python implementation when the C extension can't
  load - `import msgpack._cmsgpack` directly gives the real
  `ModuleNotFoundError` in every case.

This isn't a wheel-tag-matching problem, it's structural: APE has no
`dlopen()` for external files, full stop, so a compiled `.pyd`/`.so` can
never be loaded no matter which OS/arch it was built for or how it got onto
disk.

Side finding along the way: this build's `sysconfig.get_platform()` reports
a non-standard tag on Windows (`windows-10.0-x86_64` instead of the real
PyPI convention `win-amd64`), because that formatting logic in CPython's
`sysconfig` is gated on `os.name == 'nt'`, which we don't have (see
"sys.platform is stuck as linux" above - same root cause). This means pip
never even finds a tag-matching platform wheel to *attempt*, and falls
back to the sdist (source) instead, which then fails to compile per the
structural reasons above. **We deliberately did not "fix" this tag to match
`win-amd64`/`manylinux`**: doing so would make pip successfully download a
wheel that then fails at `import` time instead of failing earlier and more
legibly during dependency resolution - a worse failure mode, not a better
one, given compiled extensions can never actually load here regardless.

If a package needs a C library we *do* build here (e.g. something wanting
sqlite3, zlib, ssl) but ships its own optional C accelerator, pip installing
the pure-Python fallback is normal and expected - that's what happened for
`requests`' dependencies in testing.

## Adding a package with a C extension but no other exotic toolchain

Since pip can't build extensions (see above), the way to add native crypto/
etc. capability is the same way zlib etc. got added to Python itself:
compile C sources with cosmocc and statically link them into `python.com`
as a *built-in* extension module. `Modules/Setup.local` is CPython's own
supported hook for this (auto-included by `make` alongside `Modules/Setup`
when generating `Makefile`/`config.c` - see `Makefile.pre.in`, rule for
`Modules/Setup.local`): a line like

```
_cosmocrypto /work/modules/cosmocrypto/_cosmocrypto.c -lcrypto
```

statically links a new built-in module with zero changes to CPython's own
source tree. `scripts/configure-and-make.sh` writes this file into
`$BUILD_DIR/Modules/Setup.local` right before the first `make` invocation.
New modules following this pattern live in `modules/<name>/`
(bind-mounted into the container, see `docker-compose.yml`) - a `.c` file
with a normal `PyInit_<name>` entry point, optionally paired with a
pure-Python wrapper `.py` file that `configure-and-make.sh` copies into the
embedded stdlib zip.

**Implemented this way:** `cosmo` (`modules/cosmo/`) - the
smallest possible example of this pattern, and a good one to copy from.
`_cosmo.c` exposes Cosmopolitan's `IsWindows()`/`IsLinux()`/`IsXnu()`/etc.
(`libc/dce.h`, resolved from `__hostos` at startup) plus the compile-time
architecture, and `cosmo.py` wraps that in `host_os()`, `arch()` and
`is_windows()`-style predicates. It exists because `sys.platform` is
permanently `'linux'` here for load-bearing reasons (see above), which
left portable scripts with *no* way to ask which OS they were actually
running on - even though the APE runtime knows exactly. Note that
`cosmo.arch()` is a compile-time constant and still correct, precisely
because cosmocc compiles each architecture separately before `apelink`
joins them.

**Implemented this way:** `cosmocrypto` (`modules/cosmocrypto/`) -
AES-GCM/AES-CBC via this build's own `libcrypto.a`. See Status above.

**Investigated and ruled out:**
- `pycryptodome`: looked like the obvious candidate (self-contained C, no
  external deps) but its architecture is fundamentally incompatible - its
  `Crypto.Util._raw_api.load_pycryptodome_raw_lib()` compiles each
  primitive as a *plain shared library* and loads it at **runtime via
  ctypes** (`ctypes.CDLL`), not as a normal `PyInit_`-based CPython
  extension. There is no static-linking entry point to hook into; making it
  work would mean forking pycryptodome to rewrite its C/Python glue layer
  entirely, not just recompiling it. This is why `cosmocrypto` exists as our
  own minimal replacement instead.
- `cryptography` / `pyOpenSSL` / `egenix-pyopenssl`: all ruled out, see
  "Explicitly out of scope" below.

**Implemented this way too:** `psycopg` (v3) - see Status above. Notes on
what it actually took, since it's the most involved integration here and a
template for the next one:

- `deps/07-libpq.sh` builds `libpq.a` from PostgreSQL 17.2's source
  (client library only, `make -C src/interfaces/libpq libpq.a` - not the
  server). Three cosmocc-specific snags, each with a small, targeted fix
  rather than a patch to vendored postgres code:
  - `-Werror=vla`: configure auto-adds it (cosmocc's GCC accepts the flag,
    so the "does the compiler support this" probe says yes), and a couple
    of `src/common` files use a VLA upstream considers portable. Stripped
    from the generated `src/Makefile.global` post-configure.
  - `StaticAssertDecl(SIGUSR2 < PG_NSIG, ...)` (and 3 similar): fails to
    compile because Cosmopolitan Libc resolves signal numbers like
    `SIGUSR2` at *runtime* (same binary, different signal numbering per
    host OS), so they aren't preprocessor constants the way glibc's are.
    It's a sanity check, not behavior - the 4 lines are deleted from
    `src/port/pqsignal.c` post-extract.
  - `libpq.a` alone isn't enough to link against - it needs `libpgcommon.a`
    and `libpgport.a` too (matches `libpq.pc`'s own `Libs.private`), and
    those two aren't `install_fat_static_lib`'d by default. Fixed by
    installing all three.
- `psycopg-c` 3.2.3's sdist ships **pre-generated Cython C output**
  (`psycopg_c/pq.c`, `psycopg_c/_psycopg.c`, ~150K lines combined) - no
  Cython needed at build time, just a C compiler. Both compiled with
  cosmocc essentially unmodified; the one real fix needed was a classic
  `portable_endian.h`-style shim in `_psycopg.c` that `#error`s on any OS
  it doesn't explicitly recognize (`__linux__`/`__APPLE__`/`_WIN32`/
  `__sun`) - cosmocc deliberately advertises none of those. Added an
  `#elif defined(__COSMOPOLITAN__)` branch that just does what the Linux
  branch does (`#include <endian.h>`, which Cosmopolitan Libc already
  provides).
- One more link-time surprise: `libpq.a`'s own objects (`fe-connect.c` etc.)
  expect plain `pg_char_to_encoding()`/`pg_encoding_to_char()`, but our
  separately-built `libpgcommon.a` compiled them as
  `..._private()` (postgres's own `src/interfaces/libpq` build sets
  `USE_PRIVATE_ENCODING_FUNCS` for its bundled copy of `src/common` - see
  `src/include/mb/pg_wchar.h`). Bridged directly with a 10-line shim
  (`modules/psycopg/encoding_shim.c`) rather than
  chasing exact flag parity between the two separately-built copies.
- Setup module names can't contain dots (`psycopg_c._psycopg` isn't valid),
  but Cython's generated `PyInit_<name>` always matches the extension's
  *last* dotted component regardless of what the full name was
  (`PyInit_pq`, `PyInit__psycopg`) - so the Setup.local names have to be
  exactly `pq` and `_psycopg`, and `modules/psycopg/psycopg_c/__init__.py`
  is a tiny shim package that imports those flat builtins and re-exposes
  them as `psycopg_c.pq` / `psycopg_c._psycopg`, matching what upstream
  `psycopg`'s pure-Python layer actually imports.

**PostgreSQL SSL/TLS: done and verified.** `libpq.sh` builds with
`--with-ssl=openssl` against our own cosmocc-built OpenSSL. Two things had
to be fixed:
- Dep script execution order: `deps/*.sh` run in the order `bash`'s
  glob returns them (alphabetical), and `libpq` needs OpenSSL already
  installed before its own `configure` runs. Files are numbered
  (`01-zlib.sh` ... `07-libpq.sh`) to make that order explicit and correct
  rather than an accident of naming.
- The single-arch `${arch}-unknown-cosmo-cc` compiler (used by every
  `deps/*.sh`, see "Building a third-party C dependency") doesn't
  automatically search `$COSMOCC/${arch}-linux-cosmo/lib` for our
  cosmocc-built deps the way the fat `cosmocc` wrapper does. Every other
  dep only ever compiles+archives with it (no link-time external-lib
  test); `libpq`'s own `configure` is the first to actually link against
  one (`-lcrypto`, `-lssl`, for `--with-ssl=openssl`), so it's the first
  to need `LDFLAGS="-L$COSMOCC/${arch}-linux-cosmo/lib"` spelled out.

Verified with a self-signed cert against a real `postgres:17` container
(`ssl=on`), `sslmode=require`, on both Windows and Linux:
`conn.pgconn.ssl_in_use == True`, plus the same cross-OS round-trip test
as the plaintext case (data written from Linux read back correctly from
Windows over the encrypted connection, and vice versa).

## Binary size: 101MB → 43MB, without touching the fat/dual-arch nature

All of this trims **stdlib content embedded in the `zipos` zip store**, or
drops files that were never read at runtime in the first place - none of it
touches `apelink`'s dual-arch executable machinery (still one `.com` with a
real x86_64 half and a real aarch64 half, still runs unmodified everywhere
cosmocc supports). Cut in `scripts/configure-and-make.sh`, right after
`make install`, before embedding the zip:

- **`libpython3.14.a` (~81MB)**: only useful for compiling *new* C
  extensions against this install, which is structurally impossible here
  anyway (see "pip and compiled packages" - no `dlopen()`, no way to build
  against a static-only install outside this exact build). Deleted wherever
  `make install` put it (`find ... -name 'libpython*.a' -delete`, rather
  than assuming a fixed path).
- **`bin/python3.14` + `bin/python3` (~73MB combined)**: `make install`
  installs a full second copy of the interpreter binary itself into the
  stdlib tree it's about to zip up. Nothing ever reads these at runtime -
  the thing actually running is `python.com` itself, and `sys.executable`
  always resolves to the real on-disk `python.com` (verified) - so shipping
  a complete duplicate of the running binary *inside* the running binary is
  pure waste. Both removed.
- **`psycopg_c`'s `.c` source files (~6.5MB)**: `pq.c`, `_psycopg.c`, and
  `types/numutils.c` were already compiled into `libpython3.14.a`
  (`-static-*` per `Modules/Setup.local`) at build time - shipping the
  source again inside the zip is dead weight. Only `psycopg_c/__init__.py`
  (the shim re-exposing the flat `pq`/`_psycopg` builtins under their
  expected dotted names) is embedded.
- **`test`, `idlelib`, `turtledemo`, `turtle.py`, `tkinter`,
  `lib2to3/tests`, `ctypes/test`, `unittest/test`, all `__pycache__` dirs**:
  `tkinter`/`idlelib`/`turtledemo` need Tcl/Tk, which is never built here
  (see "Explicitly out of scope" - not pure-C/pure-Python, low value for a
  CLI-oriented binary), so `import tkinter` fails regardless of whether
  these ship - pure dead weight, not a feature being removed. The various
  `test`/`tests` dirs are upstream's own test suites for the stdlib itself,
  irrelevant at runtime. `share/` (docs/man pages) is dropped too.

**Result**: 101MB → 43MB (57% reduction), verified zero functional
regression - the full `round2_test.py`/`mp_final_test.py`/`stress_test.py`
batteries pass identically before and after, on both Windows and Linux.

Looked further for additional savings (`unzip -l` directory-size
aggregation over the embedded zip) and didn't find another candidate
of comparable size - the remaining `.symtab.amd64`/`.symtab.arm64` debug
symbol tables (~3MB combined, baked in by `apelink` itself, not the zip
store) are the only thing left, and stripping them is lower-value/
higher-risk (loses `faulthandler`/`gdb` symbol names) for a small gain, so
deliberately left alone for now.

## Explicitly out of scope

`cryptography` (pyca) needs a Rust toolchain (`setuptools-rust`/PyO3) -
cross-compiling Rust to target Cosmopolitan's ABI would be its own
multi-day porting project. `pyOpenSSL` and `egenix-pyopenssl` were both
checked as potential shortcuts: `pyOpenSSL` hard-depends on `cryptography`
(same Rust blocker); `egenix-pyopenssl` turned out to be an empty ~2016,
Python-2-only *installer script* (it downloads the real pyOpenSSL + a
prebuilt Windows OpenSSL at install time) with no crypto source in its
sdist at all - nothing to compile. `numpy` needs `meson` + a
Fortran-capable BLAS/LAPACK and has deep SIMD-dispatch machinery; `pandas`
inherits that same difficulty via its numpy dependency; `pyarrow` needs the
full Apache Arrow C++ library (bigger than numpy); `duckdb` is the same
order of difficulty as `pyarrow` (its own large C++ engine). None of these
fit the "cosmocc + make/configure + plain C or pure Python" rule this
project runs on, and none are planned.

## Next steps (rough priority order)

1. Verify on real Linux (bare metal/VM, not just Docker-for-Linux-on-WSL2)
   and macOS, and on real ARM64 hardware (QEMU emulation via
   `docker run --platform linux/arm64` already verified the fat binary's
   aarch64 half genuinely works - see Status above - but real hardware is
   still worth a check). `scripts/run-tests.sh` is the thing to run there.
2. Run a curated subset of **CPython's own regression suite** once, as an
   audit. This build ships `--disable-test-modules` and deletes `Lib/test`,
   so upstream's tests have never run against it - `tests/` here is about
   130 checks, where `test_os`/`test_socket`/`test_subprocess`/`test_ssl`/
   `test_sqlite3`/`test_zipimport`/`test_multiprocessing_fork` alone are
   tens of thousands. It would very likely surface real bugs. Worth doing
   as a one-off `--enable-test-modules` audit build rather than wiring into
   every build; budget for triaging a flood of failures, many of which will
   be legitimately-inapplicable rather than real.
3. Consider embedding `.pyc` files. The zip currently holds 1066 `.py` and
   zero `.pyc`, so every import compiles from source at runtime - Windows
   startup is ~0.14s against ~0.035s on Linux. This only became possible
   once `compileall` actually worked (patches 0012/0013). Measure first:
   shipping `.pyc` *instead of* `.py` would be smaller and faster but loses
   source lines in tracebacks and breaks `inspect.getsource()`; shipping
   both costs size.
2. Optionally root-cause *why* a real Python process reconnecting a named
   semaphore via `sem_open` fails while every minimal C repro succeeds
   (see "multiprocessing: two real cosmocc bugs, found and fixed"). Not
   blocking anything - `fork` sidesteps it entirely and is the default -
   but understanding it might be useful if Cosmopolitan's semaphore
   implementation trips the same way somewhere else.
3. `libpq` currently builds with a fairly minimal feature set (no ICU, no
   LDAP, no LZ4/ZSTD compression). None of that has come up as a real need
   yet; revisit only if `psycopg` usage actually requires one of them.
4. `multiprocessing`'s `forkserver` start method is the last known-broken
   piece, and it's blocked on item 2 above (same unresolved
   named-semaphore-reconnect bug - see "ProcessPoolExecutor and compileall"
   for how far the isolation got). Nothing depends on it any more:
   `fork` is the default, `ProcessPoolExecutor` and `compileall.py` both
   use it, and `Manager` runs over `AF_INET`. Only worth revisiting if
   Cosmopolitan's libc source becomes available.
5. The Windows-only `AF_UNIX` `bind()` bug (absolute paths always fail;
   relative paths under 13 characters fail) is real and reproducible but
   affects nothing in the stdlib's own paths. Worth reporting upstream to
   Cosmopolitan if a minimal C reproduction is ever worth packaging up.

## The named-semaphore bug behind spawn and forkserver

This is the single upstream defect that caused most of the multiprocessing
trouble in this project, and it went unidentified for a long time because
every minimal C reproduction of it *passed*. With Cosmopolitan 4.0.2's
source in hand it is precise, and reproducible in ten lines.

**`sem_open(name, 0)` from a second process returns garbage and corrupts
the semaphore for its original owner.**

```
PARENT created value=5
CHILD  sees value=4591654       <- garbage
PARENT after child:  value=4591654   <- the parent's semaphore, now broken too
```

The mechanism, in `libc/thread/sem_open.c`:

- `sem_open()` first consults a **per-process** cache (`sem_open_reopen`).
  A second `sem_open` in the *same* process hits that cache and behaves
  correctly - which is exactly why single-process C repros never showed
  anything, and why this looked like "only real Python processes trip it".
- A different process misses the cache and reaches `sem_open_impl()`,
  which ends with:

  ```c
  sem = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (sem != MAP_FAILED) {
      atomic_store_explicit(&sem->sem_value, value, memory_order_relaxed);
      ...
  ```

  The store is **unconditional** - it runs even when the semaphore already
  exists and `O_CREAT` was not requested. POSIX requires the opposite:
  without `O_CREAT`, `sem_open` must not reinitialize. Worse, in the
  two-argument call `sem_open(name, 0)` the `value` parameter is a
  variadic argument that was never passed, so what gets written into
  shared memory is whatever happened to be on the stack.

That one defect explains everything this project worked around
separately:

- `sem_getvalue()` returning nonsense (hence `HAVE_BROKEN_SEM_GETVALUE`) -
  the value had been overwritten with stack garbage.
- `spawn` children hanging forever in `Lock.acquire()` - `SemLock._rebuild`
  reconnects by name, so the semaphore it gets is garbage.
- `forkserver` hanging in task dispatch - its workers are forked from the
  forkserver helper, not the caller, so shared primitives must likewise be
  reconnected by name.
- Why `fork` is unaffected, and therefore why patch 0006 works: a forked
  child inherits the existing mapping and never calls `sem_open` again.

**Fixed here by overriding `sem_open` (`patches/cosmopolitan/0001-sem_open-preserve-existing-semaphore.patch`).**
It can't be patched from CPython, since the corruption happens inside libc,
but it doesn't have to be. The override is Cosmopolitan 4.0.2's own
`libc/thread/sem_open.c`, verbatim except for two marked changes: the
variadic `mode`/`value` are read only when `O_CREAT` is given, and the
semaphore is initialized only when its backing file was just created
(shorter than a page). It's listed as an extra source on the `_cosmo` line
in `Modules/Setup.local`, so it is compiled into `python.com`, and the
static linker resolves `sem_open`/`sem_close`/`sem_unlink` to it rather
than to the `libc.a` member. All three are overridden together because
they share the file's private `g_semaphores` bookkeeping.

Verified with the cross-process C repro (child and parent both see 5, 10/10
runs on Windows and Linux) and end to end: `spawn` works on Windows, Linux
and ARM64, `forkserver` works on Linux and ARM64, and joblib's default
`loky` backend, which bypasses the stdlib's contexts and so could never
have been caught by guarding a start-method name, works too.

When bumping the toolchain, re-diff this file against the new upstream
`sem_open.c`. If upstream has fixed the bug, delete the override.

## Workarounds and overrides for upstream defects

Both root causes above live in Cosmopolitan's libc and can't be fixed
from CPython. What can be done is make their failure modes safe and
give an escape hatch.

**`forkserver` on Windows is rejected up front (patch 0016).** Everything
else about multiprocessing is fixed by the `sem_open` override above. The
one remaining case is `forkserver` on Windows: it hands workers their
descriptors over AF_UNIX as `SCM_RIGHTS`, which Windows' AF_UNIX doesn't
implement, so the helper's `recvmsg()` fails with `EINVAL` and the parent
sees an opaque traceback. `_check_available()` now raises a `ValueError`
that says so. (An earlier version of this patch rejected `spawn` and
`forkserver` everywhere. That was the right call before the override
existed, but it guarded names, not the mechanism: joblib's `loky` reached
the same bug without going through either.)

**`cosmo.exit(code)` for shell-visible exit codes.** Opt-in. Calls
Win32 `ExitProcess()` directly on Windows (`_exit()` elsewhere), so a
shell reads `code` instead of `code << 8`. Verified: `cosmo.exit(7)` →
PowerShell sees 7; `sys.exit(7)` still → 1792. It is deliberately not the
default - the trade is exact, and applying it globally (tried as a patch
to `main()`, then reverted) broke `subprocess.returncode` for every
Cosmopolitan parent. `sys.exit()` for anything read from inside Python;
`cosmo.exit()` at the end of a script a shell or CI runs directly.

`scripts/build.sh` now also checks `cosmocc` can execute before cloning
anything, since WSLInterop re-registering itself cost five build cycles
in one session behind a misleading "C compiler cannot create
executables".

## The interactive banner (patch 0017)

`Modules/main.c`'s `pymain_header()` is changed in two ways when built
with cosmocc:

```
Python 3.14.7 (tags/v3.14.7-1-g...) [GCC 14.1.0] on win32
Cosmopolitan Fat Binary (APE)
```

- **The platform word reflects the real host.** Stock CPython prints
  `Py_GetPlatform()`, a compile-time constant that is always `linux` here,
  so the banner said "on linux" on Windows. A small `cosmo_banner_platform()`
  asks Cosmopolitan at runtime (`IsWindows()`, `IsXnu()`, ...) and prints
  the name a native CPython on that OS would show: `win32`, `darwin`,
  `freebsd`, etc. This changes *only the banner text*. `Py_GetPlatform()`
  and therefore `sys.platform` are untouched, deliberately - they select
  which OS modules importlib loads, and reporting `win32` there stops the
  interpreter from starting (see "sys.platform is stuck as linux").
- **A line saying how it was built**, for people who don't know what
  they're running.

Both follow the rest of the banner's rules: `-q`, `-c`, and
non-interactive stdin suppress them.
