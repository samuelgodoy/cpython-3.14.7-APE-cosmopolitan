# cpython-cosmo — one Python binary that runs anywhere

CPython 3.14.7 and its standard library in a **single file** that runs
unmodified on Windows, Linux, macOS and the BSDs, on both x86_64 and ARM64.
No installer, no runtime, no unpacking: copy it and run it.

It is built with [Cosmopolitan](https://justine.lol/cosmopolitan/) as an
*Actually Portable Executable* (APE): one file that is at the same time a
valid Windows PE, Linux ELF, macOS Mach-O and shell script, carrying both
x86_64 and aarch64 machine code. The standard library lives inside the
binary.

```
$ ./python-3.14.7-release.com
Python 3.14.7 (tags/v3.14.7-1-g...) [GCC 14.1.0] on win32
Cosmopolitan Fat Binary (APE)
Type "help", "copyright", "credits" or "license" for more information.
>>>
```

What ships inside (OpenSSL, SQLite, PostgreSQL client, zlib/bz2/lzma,
ctypes, tzdata, pip...) is listed in **[FEATURES.md](FEATURES.md)**.

## Using it

```bash
./python-3.14.7-release.com                  # REPL
./python-3.14.7-release.com script.py        # run a script
./python-3.14.7-release.com -m http.server   # stdlib modules as usual
# The internal zip filesystem is read-only; install packages to a host directory:
./python-3.14.7-release.com -m pip install --target ./packages requests
PYTHONPATH=./packages ./python-3.14.7-release.com -c "import requests; print(requests.__version__)"
```

On Windows it runs from PowerShell, cmd or Git Bash. The file name does
not matter to the binary; rename it freely, keeping `.com` or `.exe` if
Windows should run it.

### Things that will surprise you

- **`sys.platform` is always `'linux'`** (and `os.name` is `'posix'`),
  even on Windows. They are compile-time constants that select which OS
  modules CPython loads, and this is one POSIX-personality build that runs
  everywhere. Behaviour is still correct on the real host; only the string
  lies. For the real OS use the bundled `cosmo` module:
  ```python
  import cosmo
  cosmo.host_os()      # 'windows' | 'linux' | 'macos' | 'freebsd' | ...
  cosmo.is_windows()
  cosmo.arch()         # 'x86_64' | 'aarch64'
  ```
- **Exit codes reach a Windows shell multiplied by 256** (`sys.exit(1)` →
  `256`, and Git Bash reads `0`). Inside Python (`subprocess`) they are
  correct. If a shell or CI must read the code, end the script with
  `cosmo.exit(code)`.
- **pip targets an internal read-only filesystem by default.**
  CPython resolves its standard library and default \site-packages\ inside an
  embedded, read-only zip filesystem bundled directly into the executable. Because
  this internal filesystem cannot be written to at runtime, \pip install\ without
  flags will fail. Always install pure-Python packages to an external host folder
  using \--target\ (e.g. \./python-3.14.7-release.com -m pip install --target ./packages <pkg>\)
  and load them via \PYTHONPATH\. Additionally, static APEs cannot load dynamic
  \.so\/\.pyd\ extensions, so packages with native C extensions will not work.

The full list of limitations, and what each one's workaround costs, is in
[docs/ERRORS.md](docs/ERRORS.md) and [docs/WORKAROUNDS.md](docs/WORKAROUNDS.md).

## Building

Requirements: Docker with Compose v2, about 6 GB of free disk space, and
network access (every external source is downloaded during the build).

```bash
docker compose build              # builder image; once, and after changes to docker/, deps/, patches/cosmopolitan/ or patches/psycopg-c/
docker compose run --rm build     # -> .bin/python-3.14.7-release.com
```

The first `docker compose build` compiles the C libraries for both
architectures and takes a while; after that a build takes about 5 minutes.

Output:

| Path | Contents |
|---|---|
| `.bin/` | `python-3.14.7-release.com` and nothing else, copied there only after the test suite passed against it |
| `logs/` | `configure.log`, `make.log`, `install.log`, test transcripts, `BUILD-INFO.txt` (exactly what went into the binary), `SHA256SUMS` |

**Windows (Docker Desktop):** run every `docker` command from Git Bash
with `MSYS_NO_PATHCONV=1` in front, and if the build stops with *"cosmocc
cannot execute"*, disable the WSL interop handler (it re-enables itself
after WSL restarts) from PowerShell:

```powershell
wsl -d docker-desktop -u root -- sh -c "echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop"
```

## Testing

The build already runs the suite on Linux x86_64 before publishing. To run
it on the other targets:

```bash
docker compose run --rm test         # Linux x86_64
docker compose run --rm test-arm64   # Linux aarch64, emulated with QEMU
./scripts/run-tests.sh               # Windows host, from Git Bash
docker compose run --rm audit        # a curated slice of CPython's own test suite
```

## Reproducibility

Every input is pinned by version and checksum — base image by digest, apt
through a dated snapshot mirror, the cosmocc toolchain, CPython (tag *and*
commit), every third-party library and source — and the build sets
`SOURCE_DATE_EPOCH` and writes the embedded zip deterministically. The one
deliberate exception is the Mozilla CA bundle, which is always fetched
fresh so the binary ships current root certificates. See
[docs/BUILD.md](docs/BUILD.md#nothing-third-party-is-stored-in-this-repository)
for where each pin lives.

No third-party code is committed. The repository holds this project's own
code and the patches it applies to the downloaded sources.

## Repository layout

```
.
├── docker-compose.yml   # build, test, test-arm64, audit
├── docker/Dockerfile    # pinned builder image
├── deps/                # download + build scripts for third-party sources
├── patches/
│   ├── cpython/         # applied to CPython
│   ├── cosmopolitan/    # applied to Cosmopolitan libc sources
│   └── psycopg-c/       # applied to the psycopg-c sdist
├── modules/             # this project's built-in modules (cosmo, cosmocrypto, psycopg glue)
├── scripts/             # build, test and audit entry points
├── tests/               # regression suite
├── docs/                # engineering notes and status docs
├── .bin/                # build output (ignored)
└── logs/                # build/test logs (ignored)
```

## Documentation

| Document | What it covers |
|---|---|
| [FEATURES.md](FEATURES.md) | What ships in the binary |
| [docs/SUCCESS.md](docs/SUCCESS.md) | What is verified working, and on which targets |
| [docs/PATCHES.md](docs/PATCHES.md) | Every change made to CPython, Cosmopolitan and psycopg |
| [docs/WORKAROUNDS.md](docs/WORKAROUNDS.md) | What is worked around rather than fixed |
| [docs/ERRORS.md](docs/ERRORS.md) | What still does not work |
| [docs/BUILD.md](docs/BUILD.md) | How the build works and why |
| [docs/HOW-TO-PATCH.md](docs/HOW-TO-PATCH.md) | How to change the build |

## Verifying a binary

```bash
sha256sum .bin/python-3.14.7-release.com   # compare with logs/SHA256SUMS
./.bin/python-3.14.7-release.com -c "import sys; print(sys.version)"
```

The version reads `3.14.7 (tags/v3.14.7-1-g<hash>...)`: "one commit past
the v3.14.7 tag", that commit being this project's patches. The hash
depends only on the patches, so it is the same for every build of the same
patch set.

## License

This repository's own files are MIT licensed (see [LICENSE](LICENSE)). The binaries it builds also contain CPython, Cosmopolitan, OpenSSL, libpq, psycopg and other libraries, each under its own license.
