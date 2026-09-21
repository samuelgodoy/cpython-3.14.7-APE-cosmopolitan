# Workarounds

Contornos para limitações que não são corrigidas na origem. Cada um diz o
que resolve e o que continua de fora (o que continua de fora está também
em `ERRORS.md`).

## `multiprocessing` usa `fork` por padrão — patch 0006

`Lib/multiprocessing/context.py` define `fork` como método de início
padrão em todos os sistemas, inclusive no Windows. É o método mais
testado aqui e o mais rápido. `spawn` e `forkserver` também funcionam
(veja `PATCHES.md`, override do `sem_open`), mas quem não escolhe nada
fica com `fork`.

## `Manager` escuta em TCP local — patch 0011

`multiprocessing.managers.BaseManager` usa `('127.0.0.1', 0)` como
endereço padrão em vez de AF_UNIX. O `Manager` não precisa de nada
específico de AF_UNIX, e TCP local funciona igual em todos os sistemas.

## `compileall` não força `forkserver` — patch 0012

O `Lib/compileall.py` original troca para `forkserver` sempre que o
padrão é `fork`. Aqui ele usa o contexto padrão, então a compilação
paralela funciona também em ambientes onde `forkserver` não está
disponível.

## `forkserver` recusado no Windows — patch 0016

`get_context('forkserver')` levanta `ValueError` no Windows, explicando o
motivo e sugerindo `fork` ou `spawn`. O `forkserver` passa file
descriptors por AF_UNIX (`SCM_RIGHTS`), e o AF_UNIX do Windows não
implementa isso. Sem o patch, o erro aparece como um traceback confuso
vindo do processo auxiliar.

## `HAVE_BROKEN_SEM_GETVALUE`

Definido à força no `pyconfig.h`. Faz o CPython não confiar no valor de
`sem_getvalue()` ao liberar um `Lock`/`Semaphore`. Continua ativo por
segurança.

## Exit code visível para o shell do Windows — `cosmo.exit()`

`sys.exit(n)` chega a um shell do Windows como `n * 256`. `cosmo.exit(n)`
chama `ExitProcess(n)` diretamente e o shell lê `n`. É opcional e não
substitui o `sys.exit()`, porque um processo Cosmopolitan pai que lê esse
status via `waitpid()` o interpreta errado. Regra: `sys.exit()` quando
quem lê é o próprio Python (`subprocess`), `cosmo.exit()` no fim de um
script que um shell ou CI executa. `cosmo.exit()` não roda `finally` nem
`atexit`.

Alternativa sem código: no PowerShell, dividir `$LASTEXITCODE` por 256.

## SO real — `cosmo.host_os()`

`sys.platform` é sempre `linux` e `os.name` é sempre `posix`. Para saber
o sistema de verdade, use `cosmo.host_os()` / `cosmo.is_windows()`. O
banner interativo também mostra o SO real.

## Build no Docker Desktop (Windows): WSLInterop

O handler `WSLInterop` do WSL intercepta binários APE (cabeçalho `MZ`) e
impede o `cosmocc` de rodar. Ele se reativa sozinho após reinícios do
WSL/Docker. O `build.sh` e o script de auditoria detectam isso antes de
começar e mostram o comando de correção:

```powershell
wsl -d docker-desktop -u root -- sh -c "echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop"
```

## Testes

- `tests/run_all.py` imprime `RESULT: PASS` / `RESULT: FAIL`, e o
  `scripts/run-tests.sh` decide por essa linha, não pelo exit code (que no
  git-bash sai sempre 0).
- Os testes que usam `spawn`/`forkserver`/joblib rodam num script separado
  (`tests/_start_method_probe.py`), porque `spawn` reimporta o `__main__`.
- Os testes que dependem do ambiente usam `Skip` (ex.: `os.symlink` sem
  Developer Mode, joblib não instalado).
