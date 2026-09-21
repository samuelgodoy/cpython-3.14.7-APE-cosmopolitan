# O que funciona

Estado verificado do `.bin/python-3.14.7-release.com` (CPython 3.14.7,
Cosmopolitan/cosmocc 4.0.2).

## O binário

- Um único arquivo (~52 MB) com CPython 3.14.7 e a stdlib embutida.
- Fat binary APE: contém código x86_64 e aarch64 no mesmo arquivo.
- Roda sem instalação no Windows (PowerShell, cmd, git-bash) e no Linux.
- O banner interativo mostra o SO real (`on win32` / `on linux`) e a linha
  `Cosmopolitan Fat Binary (APE)`.
- `.bin/` recebe só o binário, e só depois de o gate de testes passar;
  `logs/` recebe `BUILD-INFO.txt` (commit, patches com hash, versões) e
  `SHA256SUMS`.

## Alvos verificados

Suíte completa (`scripts/run-tests.sh`, 9 módulos): **0 falhas** em todos.

| Alvo | Resultado |
|---|---|
| Windows 11 x86_64 | PASS |
| Linux x86_64 (Docker) | PASS |
| Linux aarch64 (Docker, QEMU) | PASS |

## Bibliotecas nativas (compiladas do fonte com cosmocc, estáticas)

| Módulo | Estado |
|---|---|
| `ssl` / `hashlib` | HTTPS real com verificação de certificado; CA bundle Mozilla embutido |
| `sqlite3` | OK |
| `zlib`, `bz2`, `lzma` | OK |
| `ctypes` | Tipos, `Structure`, `Union`, arrays, `sizeof`, `byref` |
| `zoneinfo` | Base IANA embutida (tzdata) |
| `psycopg` 3 | PostgreSQL com acelerador C e TLS |

## Módulos próprios embutidos

- `cosmo`: `host_os()`, `arch()`, `is_windows()`/`is_linux()`/`is_macos()`/
  `is_bsd()`, e `exit(code)` (exit code visível para shell do Windows).
- `cosmocrypto`: AES-GCM e AES-CBC sobre o OpenSSL do `ssl`.

## Stdlib e runtime

- `multiprocessing`: `fork` (padrão) e `spawn` em todos os alvos;
  `forkserver` no Linux/aarch64. `Lock`, `Queue`, `Pool`, `Manager`,
  `Barrier`, `Event`, `shared_memory`.
- `concurrent.futures`: `ThreadPoolExecutor` e `ProcessPoolExecutor`.
- `joblib` com o backend padrão `loky` (instalado via pip).
- Imports de módulos grandes dentro de threads.
- `threading`, `asyncio` (incluindo subprocessos), `subprocess`
  (`returncode` correto), sinais, `socket` (IPv4, IPv6, DNS), AF_UNIX no
  Windows e no Linux (incluindo paths sob `C:/` e `/C/...`).
- Filesystem: I/O, nomes unicode, `chmod`, `rename`, `stat`, `walk`,
  hardlinks, `shutil`, `fcntl.flock`, `tempfile`.
- `pip` e `venv` para pacotes Python puros (ex.: `requests`, `joblib`).
- stdlib servida como bytecode pré-compilado.

## Desempenho medido

- Startup do interpretador: ~0,03 s (Linux).
- Iniciar + importar `email`/`http.client`/`xmlrpc.client`: ~0,08 s.
- Build completo: ~4 min com a imagem pronta (uma camada por dependência, downloads em cache).
- Reproduzível: duas imagens refeitas do zero geram binários idênticos byte a byte.

## Auditoria com a suíte oficial do CPython

~4.400 testes upstream executados. Sem falhas em `test_io`, `test_sqlite3`,
`test_ssl`, `test_posixpath`, `test_select`, `test_tempfile`, `test_shutil`,
`test_zipimport`, `test_hashlib`, `test_zlib`, `test_bz2`, `test_lzma`,
`test_zoneinfo`. Falhas restantes classificadas em `ERRORS.md`; nenhuma é
defeito do build.

## Infraestrutura do projeto

- Build 100% em Docker Compose (`build`, `test`, `test-arm64`, `audit`).
- Nenhum código de terceiros no repositório: CPython, cosmocc, a libc do
  Cosmopolitan, psycopg e as bibliotecas C são baixados no build, com
  versão e sha256 fixados; as mudanças sobre eles vivem em `patches/`.
- Imagem reproduzível: base Ubuntu por digest e apt preso a um snapshot
  datado; `SOURCE_DATE_EPOCH` e zip determinístico no binário.
- Suíte de regressão versionada em `tests/`, executada como gate no final
  de todo build.
- `scripts/audit-cpython-tests.sh` para auditar contra a suíte do CPython.
- Checagem prévia no build que detecta o WSLInterop interceptando o cosmocc.
