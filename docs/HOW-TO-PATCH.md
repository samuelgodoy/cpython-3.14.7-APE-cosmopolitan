# Como aplicar patches neste projeto

Guia de trabalho para mudar o comportamento deste build. Leia inteiro
antes de criar o primeiro patch. Cada regra aqui veio de um erro real.

## Regra de ouro: só patches entram no repositório

Código de terceiros **nunca** é versionado. CPython, a libc do
Cosmopolitan, o psycopg e as bibliotecas C são baixados no build, com
versão e sha256 fixados, e as nossas mudanças sobre eles vivem como
arquivos `.patch`. O que é nosso de verdade (módulos em `modules/`,
scripts, testes) é versionado normalmente.

## Os três conjuntos de patches

| Pasta | Aplicado sobre | Quando | Por quem |
|---|---|---|---|
| `patches/cpython/` | clone do CPython `v3.14.7` | a cada `docker compose run --rm build` | `scripts/build.sh` (`git apply`, em ordem) |
| `patches/cosmopolitan/` | arquivos da libc do Cosmopolitan 4.0.2 baixados por `deps/09-cosmopolitan-libc.sh` | no `docker compose build` | `deps/09-cosmopolitan-libc.sh` (`patch -p1`) |
| `patches/psycopg-c/` | sdist `psycopg_c-3.2.3` | no `docker compose build` | `deps/08-psycopg.sh` (`patch -p1`) |

Consequência prática: mudou algo em `patches/cosmopolitan/`,
`patches/psycopg-c/` ou `deps/`? Rode `docker compose build` antes do
próximo build, senão a imagem antiga continua sendo usada.

## Onde cada tipo de mudança entra

| Quero... | Onde |
|---|---|
| Mudar código do CPython (`Lib/`, `Modules/`, `Python/`) | Novo `patches/cpython/NNNN-descricao.patch` |
| Definir uma macro de configuração (`HAVE_...`, `THREAD_STACK_SIZE`) | `echo '#define ...' >> pyconfig.h` em `scripts/configure-and-make.sh`, logo após o `configure` |
| Corrigir um bug da libc do Cosmopolitan | Patch em `patches/cosmopolitan/` + o arquivo na lista `FILES` de `deps/09-cosmopolitan-libc.sh` (seção própria abaixo) |
| Corrigir algo no psycopg-c | Patch em `patches/psycopg-c/` |
| Adicionar um módulo C nosso | `modules/<nome>/` + linha no `Setup.local` em `scripts/configure-and-make.sh` |
| Adicionar/atualizar uma biblioteca C (zlib, OpenSSL...) | `deps/NN-nome.sh`, com URL, versão e sha256 |
| Mudar o que vai para dentro do binário (trim, dados embutidos) | `scripts/configure-and-make.sh` |
| Fixar/atualizar uma versão | ver "Onde cada versão está fixada" no fim |

## Numeração

- Formato: `NNNN-descricao-curta.patch`, com o próximo número livre **do
  conjunto**.
- `patches/cpython/`: o último é **0017**, o próximo é **0018**. Buracos
  (0002, 0008, 0010, 0014) são patches removidos; não reaproveite.
- `patches/cosmopolitan/` e `patches/psycopg-c/`: o próximo é **0002**.
- A ordem importa: patches que mexem no mesmo arquivo precisam ser gerados
  **em cima** dos anteriores.

Arquivos do CPython que já recebem patch:

| Arquivo | Patches |
|---|---|
| `Modules/_testcapimodule.c` | 0001 |
| `Lib/ctypes/__init__.py` | 0003 |
| `Lib/venv/__init__.py` | 0004 |
| `Lib/socket.py` | 0005 |
| `Lib/multiprocessing/context.py` | 0006, 0016 |
| `Lib/ssl.py` | 0007 |
| `Lib/multiprocessing/heap.py` | 0009 |
| `Lib/multiprocessing/managers.py` | 0011 |
| `Lib/compileall.py` | 0012 |
| `Modules/posixmodule.c` | 0013 |
| `Modules/socketmodule.c` | 0015 |
| `Modules/main.c` | 0017 |

Para regenerar esta tabela:

```bash
for p in patches/cpython/*.patch; do echo "$(basename "$p" | cut -c1-4) $(grep -h '^+++ b/' "$p" | sed 's|+++ b/||')"; done
```

## Passo a passo: patch no CPython

### 1. Obter o arquivo na versão certa

**Não use o volume `cpython-cosmo_cpython-src` como base.** Ele contém o
fonte **já com todos os patches aplicados**; um diff contra ele não aplica
num build novo.

Clone limpo, com os patches existentes aplicados, dentro de `.tmp/`:

```bash
cd .tmp && rm -rf base && git clone -q --branch v3.14.7 --depth 1 https://github.com/python/cpython.git base
cd base && for p in ../../patches/cpython/*.patch; do git apply "$p"; done
cp Lib/alvo.py ../alvo.py.orig
```

Se o arquivo não é tocado por nenhum patch existente, o clone limpo sem
patches serve.

### 2. Editar uma cópia

Gere `alvo.py.new` a partir de `alvo.py.orig`. Para edições além do
trivial, escreva um script Python com a ferramenta de escrever arquivo e
rode com o próprio binário (`.bin/python-*-release.com script.py`).

### 3. Gerar o diff com cabeçalhos `a/` `b/`

```bash
diff -u alvo.py.orig alvo.py.new \
  | sed -e '1s|.*|--- a/Lib/alvo.py|' -e '2s|.*|+++ b/Lib/alvo.py|' \
  > patches/cpython/0018-descricao.patch
```

Nunca escreva o hunk (`@@ ... @@`) à mão: a contagem de linhas sai errada
e o patch fica malformado.

### 4. Validar a sequência inteira num clone limpo

```bash
cd .tmp && rm -rf check && git clone -q --branch v3.14.7 --depth 1 https://github.com/python/cpython.git check
cd check && for p in ../../patches/cpython/*.patch; do
  git apply --check "$p" && git apply "$p" || echo "FAIL $(basename "$p")"
done
```

Só siga se nenhum `FAIL` aparecer.

## Patch na libc do Cosmopolitan (`patches/cosmopolitan/`)

Usado quando o defeito está dentro da libc, que vem pré-compilada no
`cosmocc`. O arquivo corrigido é compilado dentro do `python.com`, e o
linker estático usa essa versão no lugar do membro do `libc.a`.

1. Baixe o arquivo original na tag exata do toolchain:
   `https://raw.githubusercontent.com/jart/cosmopolitan/4.0.2/<caminho>`.
2. **Sobrescreva todos os símbolos públicos do arquivo juntos** (ex.:
   `sem_open`, `sem_close` e `sem_unlink`), porque eles compartilham
   estado interno.
3. Faça só as mudanças necessárias, marcadas com `// cpython-cosmo:`. Para
   compilar fora da árvore do Cosmopolitan, o topo do arquivo precisa de:
   ```c
   #define _COSMO_SOURCE
   #include <stdbool.h>
   ```
4. Gere o patch com caminhos relativos à raiz do Cosmopolitan
   (`--- a/libc/thread/sem_open.c`).
5. Adicione `"<caminho> <sha256 do original>"` à lista `FILES` em
   `deps/09-cosmopolitan-libc.sh`.
6. Adicione `/opt/sources/cosmopolitan/<caminho>` como fonte extra na
   linha do `_cosmo` em `Modules/Setup.local` (`scripts/configure-and-make.sh`).
7. Teste primeiro isolado: compile um reprodutor em C junto com o arquivo
   corrigido, usando o `cosmocc` de dentro da imagem, e rode no Windows e
   no Linux. Para bugs entre processos, o reprodutor precisa usar
   **processos diferentes**: o `sem_open` tem cache por processo, e um
   teste num processo só passa mesmo com o bug.

Ao atualizar o toolchain, verifique se o upstream corrigiu o bug; se sim,
apague o patch e a entrada em `FILES`.

## Regras de código

- **Isole tudo que é específico deste build.** Em C, use
  `#ifdef __COSMOPOLITAN__ ... #else <original> #endif`, mantendo o código
  original no `#else`.
- **SO em tempo de execução, em C**: `IsWindows()`, `IsLinux()`, `IsXnu()`
  etc. exigem, nesta ordem:
  ```c
  #define _COSMO_SOURCE
  #include <libc/dce.h>
  ```
  Sem `_COSMO_SOURCE` o header é encontrado mas as macros não são
  definidas, e o erro aparece como `implicit declaration of function`.
- **SO em tempo de execução, em Python** (dentro da stdlib): `import _cosmo`
  e `_cosmo.host_os() == 'windows'`, dentro de `try/except ImportError`.
- **Nunca mude `sys.platform`, `os.name` nem `Py_GetPlatform()`.** São
  constantes de compilação que escolhem os módulos de SO carregados pelo
  importlib; trocar para `win32` impede o interpretador de iniciar. Para
  mostrar o SO real, mude só texto de exibição (como o banner no 0017).
- **Comentário explicando o porquê** em cada mudança: qual o defeito,
  como foi confirmado, e onde está documentado.
- **Confira a ordem das operações no código original.** No 0015, a
  reescrita do path precisou ir **depois** do `memcpy` que preenche o
  `sun_path`; antes dele, lia um buffer zerado e não fazia nada, e mesmo
  assim compilava sem erro.
- **Contorno com efeito global precisa de teste nos dois sentidos.** Um
  patch que corrigiu o exit code para o shell quebrou o
  `subprocess.returncode`. Quando só um lado pode ficar certo, deixe o
  contorno opcional (como o `cosmo.exit()`).
- **Proteja o mecanismo, não um nome.** Recusar `spawn` pelo nome não
  pegava o `loky` do joblib, que reconecta semáforos por conta própria; a
  correção certa foi no `sem_open`.

## Build e testes

```bash
docker compose build                 # após mudar docker/, deps/, patches/cosmopolitan/ ou patches/psycopg-c/
docker compose run --rm build        # build + gate -> .bin/
docker compose run --rm test         # Linux x86_64 (com joblib)
docker compose run --rm test-arm64   # Linux aarch64 (QEMU, com joblib)
./scripts/run-tests.sh               # Windows (Git Bash)
docker compose run --rm audit        # suíte oficial do CPython (auditoria)
```

- **No Windows/Git Bash, todo comando `docker` precisa de
  `MSYS_NO_PATHCONV=1`**.
- **Antes de buildar no Docker Desktop**, desative o WSLInterop (o build
  detecta e avisa, mas não corrige):
  ```powershell
  wsl -d docker-desktop -u root -- sh -c "echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop"
  ```
  "C compiler cannot create executables" ou "Compiler error reporting is
  too harsh" quase sempre é isso, não o compilador.
- O gate do build só cobre o Linux x86_64. **Rode também `test-arm64` e a
  suíte no Windows** antes de considerar pronto.
- No Git Bash o exit code do binário sai sempre 0. Decida pelo
  `RESULT: PASS` / `RESULT: FAIL` impresso pelos testes.
- Logs de tudo ficam em `logs/`.

## Armadilhas do ambiente (Windows + Git Bash)

- **O `/tmp` do Git Bash não é o mesmo que o Docker monta.** Para tirar um
  arquivo de um volume, use redirecionamento:
  `docker run --rm -v VOL:/src alpine cat /src/arquivo > local`.
- **Não há `python3` nem `make` no host.** Use o próprio binário de
  `.bin/` como Python.
- **Heredoc no shell engole barras invertidas.** Scripts com `\` (C,
  continuação de linha) devem ser escritos com a ferramenta de escrever
  arquivo, não via `cat <<EOF`.
- **Não edite um script enquanto um build o executa.** O bash lê o
  arquivo aos poucos; mate o build e rode de novo.
- `sed -i` apagando linhas por número é arriscado depois de outras
  edições; prefira substituição por conteúdo.
- Rascunhos e clones temporários vão em `.tmp/` (ignorado pelo git).

## Onde cada versão está fixada

| O quê | Arquivo |
|---|---|
| Imagem base Ubuntu 22.04 (digest) | `docker/Dockerfile` (`UBUNTU_DIGEST`) e `docker-compose.yml` (`test-arm64`) |
| Snapshot do apt | `docker/Dockerfile` (`APT_SNAPSHOT`) |
| cosmocc | `docker/Dockerfile` (`COSMOCC_VERSION`, `COSMOCC_SHA256`) |
| CPython | `docker-compose.yml` (`CPYTHON_REF`, `CPYTHON_COMMIT`) |
| Bibliotecas C | `deps/01-07-*.sh` |
| psycopg / psycopg-c | `deps/08-psycopg.sh` |
| Arquivos da libc do Cosmopolitan | `deps/09-cosmopolitan-libc.sh` |
| tzdata | `scripts/configure-and-make.sh` |
| joblib (só testes) | `tests/requirements.txt` |
| CA bundle Mozilla | não fixado, de propósito: sempre o mais recente |

Ao atualizar o CPython, troque `CPYTHON_REF` **e** `CPYTHON_COMMIT` juntos
(`git ls-remote https://github.com/python/cpython.git refs/tags/vX.Y.Z^{}`)
e revalide todos os patches.

## Checklist ao terminar

1. `git apply --check` da sequência completa num clone limpo (CPython) ou
   `patch --dry-run` sobre o original baixado (Cosmopolitan/psycopg-c).
2. `docker compose build` (se aplicável) e `docker compose run --rm build`
   com gate verde.
3. `test`, `test-arm64` e a suíte no Windows, todos verdes.
4. Teste de regressão novo em `tests/` cobrindo a mudança (use `Skip` para
   o que depende de SO/ambiente; trabalho com `spawn` vai em
   `tests/_start_method_probe.py`, chamado por subprocesso).
5. Atualizar `docs/PATCHES.md`, `docs/WORKAROUNDS.md`, `docs/ERRORS.md`,
   `docs/SUCCESS.md`, `FEATURES.md` (estado atual apenas) e a seção
   correspondente do `docs/BUILD.md`.
6. Atualizar a tabela de arquivos com patch e o próximo número livre neste
   documento.
7. Commit.
