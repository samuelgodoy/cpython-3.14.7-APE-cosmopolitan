# O que ainda não funciona

Estado atual. Cada item diz se existe contorno.

## Limitações do runtime

| Problema | Onde | Contorno |
|---|---|---|
| `sys.exit(n)` chega a um shell do Windows como `n * 256`; o git-bash lê `0`, então uma falha aparece como sucesso. | Windows | `cosmo.exit(n)`, ou dividir `$LASTEXITCODE` por 256 no PowerShell. Dentro do Python (`subprocess.returncode`) o valor está correto. |
| `multiprocessing` com `forkserver` não funciona: o AF_UNIX do Windows não tem `SCM_RIGHTS`. Recusado com `ValueError`. | Windows | Usar `fork` (padrão) ou `spawn`. |
| pip não instala pacotes com extensão C (`numpy`, `pandas`, `cryptography`, `pyarrow`...). Não há `dlopen()`. | Todos | Nenhum. Bibliotecas C só entram compiladas dentro do binário. |
| `ctypes.CDLL` e `ctypes.pythonapi` não carregam bibliotecas; callbacks `CFUNCTYPE` dão segfault ao serem chamados. | Todos | Usar `ctypes` só para layout de memória (`Structure`, `Union`, arrays). |
| `sys.platform` é sempre `'linux'` e `os.name` é sempre `'posix'`. | Windows, macOS | `cosmo.host_os()`. O banner mostra o SO real. |
| `os.environ` diferencia maiúsculas de minúsculas (`PATH` ≠ `Path`). | Windows | Comparar os nomes em maiúsculas. |
| `os.symlink` exige Developer Mode ou prompt elevado (igual ao Python nativo). | Windows | Ativar o Developer Mode. |
| Tkinter, IDLE e turtle ausentes (precisam de Tcl/Tk). | Todos | Nenhum. |
| `socket.inet_pton` aceita o IPv4 malformado `'0.0.0.'`. | Todos | Nenhum (cosmético). |

## Falhas restantes na auditoria com a suíte oficial do CPython

Nenhuma é defeito do build; são recursos ausentes, diferenças de mensagem
ou limitações da forma de auditar.

| Módulo | Motivo |
|---|---|
| `test_os` | Sem `sched_getaffinity` e sem pty; texto de `errno` diferente para descritores inválidos. |
| `test_socket` | Sem namespace abstrato de AF_UNIX (Linux); `getservbyname` precisa de `/etc/services`; `getaddrinfo` num caso de borda; `inet_pton` laxo. |
| `test_subprocess` | Testes que exigem o usuário `nobody` e setuid (ausentes no container); um caso de troca de descritores. |
| `test_signal` | Nomes e tabela de sinais diferentes (ex.: `SIGEMT`). |
| `test_threading`, `test_importlib`, `test_venv` | Limitação do harness: subprocessos com `-I` ignoram `PYTHONPATH`, e a stdlib embutida é somente leitura. |
| `test_ctypes` | Segfault nos testes de callback (item acima). |

## Ambiente de build

- No Docker Desktop do Windows, o `WSLInterop` volta a se registrar
  sozinho e impede o `cosmocc` de rodar. O build detecta e mostra o
  comando de correção, mas a correção precisa ser reaplicada manualmente.

## Não validado

- macOS e ARM64 em hardware físico. O ARM64 foi validado só com emulação
  QEMU.
