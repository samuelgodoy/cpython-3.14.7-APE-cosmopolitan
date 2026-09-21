# Patches e ajustes reais

Correções de verdade: o comportamento passa a ser o correto, não apenas
contornado. Contornos estão em [WORKAROUNDS.md](WORKAROUNDS.md).

Código de terceiros não é versionado: tudo abaixo é aplicado sobre fontes
baixadas no build, com versão e sha256 fixados.

## Patches no CPython (`patches/cpython/`)

Aplicados em ordem sobre o clone do CPython `v3.14.7`
(commit `823f0323ee6e`) por `scripts/build.sh`.

| Patch | Arquivo | O que faz |
|---|---|---|
| 0001 | `Modules/_testcapimodule.c` | Desativa o uso de `sysctlbyname`, ausente no Cosmopolitan, para o módulo compilar. |
| 0003 | `Lib/ctypes/__init__.py` | `ctypes.pythonapi` vira opcional (`None`) em vez de derrubar o `import ctypes`, já que não existe `dlopen(NULL)`. |
| 0004 | `Lib/venv/__init__.py` | Se o symlink `lib64` não puder ser criado (Windows sem Developer Mode), o `venv` segue sem ele. |
| 0005 | `Lib/socket.py` | Se o `socketpair()` nativo falhar, usa o fallback TCP do próprio stdlib (conserta o self-pipe do `asyncio` no Windows). |
| 0007 | `Lib/ssl.py` | `create_default_context()` também carrega o CA bundle Mozilla embutido no binário. |
| 0009 | `Lib/multiprocessing/heap.py` | Só usa `/dev/shm` se um arquivo de teste puder de fato ser criado lá; senão usa o diretório temporário. |
| 0013 | `Modules/posixmodule.c` | `os.sysconf()` trata `EINVAL` como "indeterminado" (retorna `-1`), como a glibc, em vez de levantar `OSError`. |
| 0015 | `Modules/socketmodule.c` | AF_UNIX: passa `sizeof(struct sockaddr_un)` como `addrlen` e, no Windows, converte `/C/...` para `C:/...`. |
| 0017 | `Modules/main.c` | Banner interativo mostra o SO real (`on win32`, `on linux`, `on darwin`...) e a linha `Cosmopolitan Fat Binary (APE)`. `sys.platform` não muda. |

## Patch na libc do Cosmopolitan (`patches/cosmopolitan/`)

Aplicado sobre `libc/thread/sem_open.c` da tag `4.0.2`, baixado por
`deps/09-cosmopolitan-libc.sh`.

**0001-sem_open-preserve-existing-semaphore** — duas alterações:

- `mode` e `value` só são lidos dos varargs quando há `O_CREAT`.
- O semáforo só é inicializado quando o arquivo de suporte acabou de ser
  criado.

Com isso, reabrir um semáforo nomeado a partir de outro processo preserva
o valor, em vez de gravar lixo e corromper o semáforo do processo dono. O
arquivo corrigido é compilado dentro do `python.com` (fonte extra na linha
`_cosmo` do `Modules/Setup.local`), e o linker estático usa essa versão no
lugar da do `libc.a`. `sem_close` e `sem_unlink`, do mesmo arquivo, vêm
junto. Isso faz `spawn`, `forkserver` e o `loky` do joblib funcionarem.

## Patch no psycopg-c (`patches/psycopg-c/`)

Aplicado sobre o sdist `psycopg_c-3.2.3`, baixado do PyPI por
`deps/08-psycopg.sh`.

**0001-cosmopolitan-endian-header** — o `_psycopg.c` gerado pelo Cython
falha com `#error` em qualquer SO que não reconhece; o Cosmopolitan não se
anuncia como nenhum deles. O patch adiciona um ramo
`#if defined(__COSMOPOLITAN__)` que usa `<endian.h>`, como no Linux.

## Ajustes de configuração do build (`scripts/configure-and-make.sh`)

- **`THREAD_STACK_SIZE` = 8 MB** no `pyconfig.h`: o stack padrão de thread
  do Cosmopolitan é pequeno demais para o parser do CPython.
- **Stdlib pré-compilada**: `compileall` com layout `__pycache__` e
  `--invalidation-mode unchecked-hash`, embutida junto com os `.py`.
- **Versão sem `-dirty`**: `GITVERSION`/`GITTAG`/`GITBRANCH` fixados na
  linha de comando do `make`, capturados logo após o commit dos patches.
- **Build reproduzível**: `SOURCE_DATE_EPOCH` = data do commit upstream
  (usada pelo GCC em `__DATE__`/`__TIME__`, pelo commit dos patches e
  pelas datas do zip); zip embutido em ordem fixa e sem campos extras.
- **Build estático completo**: `MODULE_BUILDTYPE=static`, `--disable-shared`,
  prefixo `/zip/usr/local` servido pelo zipos do próprio binário.
- **Redução de tamanho**: remove `libpython*.a`, cópias duplicadas do
  interpretador, suítes de teste, `tkinter`/`idlelib`/`turtledemo`,
  `share/` e fontes `.c` do psycopg.
- **CA bundle Mozilla** baixado a cada build, sem versão fixa.
- **tzdata** embutido, fixado por sha256.
- **Saída**: `.bin/python-<versão>-release.com`, publicado só depois de o
  gate de testes passar; `BUILD-INFO.txt` e `SHA256SUMS` em `logs/`.

## Módulos próprios (`modules/`, estáticos via `Setup.local`)

- **`cosmo`**: detecção do SO real (`host_os()`, `arch()`, `is_*()`) e
  `exit()`.
- **`cosmocrypto`**: AES-GCM/AES-CBC sobre o `libcrypto` do build.
- **`psycopg`**: `encoding_shim.c` (liga os símbolos de encoding que o
  `libpq.a` espera às versões `_private` do `libpgcommon.a`) e o pacote
  `psycopg_c/__init__.py`, que expõe os builtins `pq`/`_psycopg` com os
  nomes que o psycopg espera.

## Dependências (`deps/`, baixadas e verificadas por sha256)

| Script | Versão | O que produz |
|---|---|---|
| `01-zlib.sh` | 1.3.1 | `libz.a` por arquitetura |
| `02-bzip2.sh` | 1.0.8 | `libbz2.a` |
| `03-xz.sh` | 5.6.4 | `liblzma.a` |
| `04-libffi.sh` | 3.4.6 | `libffi.a` |
| `05-sqlite3.sh` | 3.46.1 | `libsqlite3.a` |
| `06-openssl.sh` | 3.4.0 | `libssl.a`, `libcrypto.a` |
| `07-libpq.sh` | 17.2 | `libpq.a`, `libpgcommon.a`, `libpgport.a` |
| `08-psycopg.sh` | 3.2.3 | fontes do psycopg e do psycopg-c, com patch |
| `09-cosmopolitan-libc.sh` | 4.0.2 | `sem_open.c` do Cosmopolitan, com patch |

Todas rodam no `docker compose build` e ficam cacheadas numa camada da
imagem. As bibliotecas C são compiladas duas vezes, uma por arquitetura
(x86_64 e aarch64).
