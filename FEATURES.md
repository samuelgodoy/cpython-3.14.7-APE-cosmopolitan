# Features

Everything below is inside the single `python-3.14.7-release.com` file.
Every native library is compiled from source with the Cosmopolitan
toolchain and linked statically, once for x86_64 and once for aarch64.
Nothing is loaded from the host system.

## Runtime

| | |
|---|---|
| Python | CPython **3.14.7**, full standard library, precompiled to bytecode |
| Binary format | Cosmopolitan APE fat binary: x86_64 + aarch64 in one file |
| Runs on | Windows, Linux, macOS, FreeBSD, OpenBSD, NetBSD — no install |
| Toolchain | cosmocc **4.0.2** (GCC 14.1.0) |

Verified on Windows 11 x86_64, Linux x86_64 and Linux aarch64 (QEMU); see
[docs/SUCCESS.md](docs/SUCCESS.md).

## Embedded native libraries

| Library | Version | Enables |
|---|---|---|
| **OpenSSL** | 3.4.0 | `ssl` (real HTTPS with certificate verification), `hashlib` algorithms, `cosmocrypto` |
| **libpq** (PostgreSQL client) | 17.2 | `psycopg` — PostgreSQL, including TLS connections |
| **SQLite** | 3.46.1 | `sqlite3` |
| **zlib** | 1.3.1 | `zlib`, `gzip`, `zipfile` compression |
| **bzip2** | 1.0.8 | `bz2` |
| **xz / liblzma** | 5.6.4 | `lzma` |
| **libffi** | 3.4.6 | `ctypes` (memory layout: `Structure`, `Union`, arrays) |

## Embedded Python packages and data

| Package / data | Version | Notes |
|---|---|---|
| **psycopg** | 3.2.3 | PostgreSQL driver with its **C accelerator built in** (`psycopg.pq.__impl__ == "c"`), TLS support via OpenSSL |
| **pip** | 26.2.1 | Installs pure-Python packages from PyPI over HTTPS |
| **tzdata** | 2026.4 | IANA time zone database for `zoneinfo` — no system tzdata needed |
| **Mozilla CA bundle** | latest at build time | Root certificates for `ssl`, so HTTPS works out of the box on every OS |

## Modules added by this project

| Module | What it does |
|---|---|
| `cosmo` | The real host OS and CPU at runtime (`host_os()`, `arch()`, `is_windows()`, `is_linux()`, `is_macos()`, `is_bsd()`), and `exit(code)` for exit codes a Windows shell can read |
| `cosmocrypto` | AES-GCM and AES-CBC encryption over the embedded OpenSSL |

## Highlights of the standard library

- `multiprocessing` with `fork` (default) and `spawn` on Windows and
  Linux, and `forkserver` on Linux (not available on Windows); `Pool`,
  `Queue`, `Lock`, `Manager`, `Barrier`, `shared_memory`.
- `concurrent.futures`: `ThreadPoolExecutor` and `ProcessPoolExecutor`.
- Third-party process pools work too, e.g. joblib with its default `loky`
  backend.
- `asyncio` (including subprocesses), `threading`, `subprocess`, signals.
- `socket`: IPv4, IPv6, DNS, and AF_UNIX sockets on Windows as well as
  Linux.
- `venv`.

## Not included

- Tkinter, IDLE and turtle (need Tcl/Tk).
- Loading compiled extensions from outside the binary (`.so`/`.pyd`,
  `ctypes.CDLL`): a static APE has no `dlopen()`. Any C library must be
  compiled into the binary instead.

See [docs/ERRORS.md](docs/ERRORS.md) for every current limitation.
