---
name: crew-setup
description: >
  Use when the Kiro Crew environment needs setup or repair after an update — STT
  stopped, voice broke, CUDA vanished, pywhispercpp failed to build, extra venv
  packages disappeared, voice_reply turned itself back on, subagents fail with
  "model is not available", config changed after the update, errors or warnings
  in the gateway log need a double check, a linked skill (voxlocal, browser
  automation) lost its packages, or when setting Crew up on a new Linux machine,
  with or without a GPU.
inclusion: auto
---

# Skill: crew-setup

## Visão Geral

Configura e restaura o Kiro Crew num Linux conforme o **perfil da máquina**: STT local na
GPU ou na CPU, Amazon Transcribe ou desligado; voz do TTS nativo; e as **skills
vinculadas** (voxlocal e browser-automation). Na primeira execução detecta o ambiente,
pergunta o perfil e o guarda em `.data/profile.env`. Nos updates seguintes reusa o perfil
sem perguntar. Depois do restart, a auditoria revisa log, modelos e drift de config.

## Quando Usar

- Após `kirocrew update` ou update automático do Crew (o venv novo vem sem os extras)
- STT parou, caiu para CPU ("no GPU found") ou sumiu do dashboard
- `ModuleNotFoundError` de pacote que estava no venv (pywhispercpp, edge_tts, piper...)
- Áudio indesejado no Telegram (`voice_reply.enabled` ou `telegram.voice_replies` voltaram a `true`)
- TTS do dashboard falando com sotaque errado depois do update (provider `piper` removido no 0.11)
- Sub-agentes falham com "model is not available"
- Configurar o Crew numa máquina nova, com ou sem GPU

**Quando NÃO usar:** macOS/Windows nativos (sem `systemctl`/`ldconfig`); ajuste pontual de
config que não envolve venv, STT, voz ou skills vinculadas.

## Referência Rápida

| Operação | Comando |
|---|---|
| Diagnóstico (só lê) | `bash ~/.kiro/skills/crew-setup/tools/crew-check.sh` |
| Ver o plano, sem alterar | `bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh --plan` |
| Setup/restauração | `bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh` |
| Mudar o perfil | `bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh --reconfigure` |
| Sem perguntas (automação) | `bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh --yes` |
| Recompilar o pywhispercpp | `bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh --rebuild` |
| Auditoria pós-update | `python3 ~/.kiro/skills/crew-setup/tools/crew-audit.py` (`--no-save`, `--since "2 hours ago"`) |
| Confirmar CUDA no STT | `journalctl -u kirocrew.service -n 80 --no-pager \| grep -E 'CUDA0\|no GPU'` |
| Confirmar libs do whisper | `ldconfig -p \| grep ggml` |

Nenhum script roda com `sudo`: o setup pede a senha sozinho só nos passos que mexem no sistema.

**Quem roda o quê:** o agente roda `crew-check.sh`, `crew-setup.sh --plan` e `crew-audit.py`
(só leem). O `crew-setup.sh` sem `--plan` pede `sudo`, altera a config do Crew e reinicia o
gateway (o que derruba a sessão do próprio agente), então quem roda é o usuário, no terminal.

## Perfil da máquina

O setup não presume GPU nem CUDA. Na primeira execução (ou com `--reconfigure`) ele mostra
o que detectou e pergunta, com o detectado como padrão:

| Pergunta | Opções | Padrão |
|---|---|---|
| Transcrição (STT) | `gpu` (whisper na GPU NVIDIA), `cpu` (whisper na CPU), `transcribe` (Amazon Transcribe), `off` | `gpu` com GPU NVIDIA **e** CUDA toolkit; senão `cpu` |
| Modelo do whisper | `large-v3-turbo`, `medium`, `small`, `base` | `large-v3-turbo` na GPU, `small` na CPU |
| Idioma do STT | código BCP-47 | o do locale (`LANG`), senão `pt-BR` |
| Voz do TTS nativo | voz do espeak-ng (`-` = não mexer) | idioma do STT em minúsculas (`pt-br`) |
| Skills vinculadas | uma pergunta S/n por skill do `linked-skills.txt` | todas |

O perfil fica em `.data/profile.env` (gitignored), em texto `CHAVE=valor`. Pode ser editado à
mão. Sem terminal interativo (cron, agente) ou com `--yes`, o setup usa o perfil salvo ou o
detectado, sem perguntar.

**Validação antes de mexer em nada:** perfil `gpu` sem GPU NVIDIA, sem CUDA toolkit ou sem
compilador (quando não há wheel guardado) para o setup com a correção e a sugestão de
trocar o perfil. Falta de `ffmpeg` ou `espeak-ng` vira pendência no resumo final.

## O que o crew-setup.sh faz

| Passo | O que faz | Perfis |
|---|---|---|
| 1/7 | Pacotes extras: `requirements-transcribe.txt` (perfil `transcribe`) e `.data/extras.txt` do usuário | todos |
| 2/7 | pywhispercpp: na GPU, do wheel com CUDA guardado (ou compila e guarda); na CPU, do PyPI | `gpu`, `cpu` |
| 3/7 | ldconfig: registra o site-packages do venv pelo **caminho estável** `<KIROCREW_HOME>-venv-current` | `gpu` |
| 4/7 | Remove o `LD_PRELOAD` legado do systemd (`--ld-preload` grava, como plano B) | todos |
| 5/7 | Config do gateway: STT do perfil, TTS nativo (`system` + voz), modelos de LLM em `auto` | todos |
| 6/7 | Skills vinculadas: clona se faltar, roda o `tools/install.py` e o `tools/check.py` de cada uma | todos |
| 7/7 | Reinicia o serviço e confirma `using CUDA0 backend` no log do start atual | todos |

## Skills vinculadas

`tools/linked-skills.txt` lista as skills que o setup restaura, uma por linha
(`<pasta> <url-do-repo>`). A lista é fechada: o setup só executa código das skills listadas.

| Skill | O que o setup faz por ela |
|---|---|
| [voxlocal](https://github.com/eliasrosa/voxlocal-skill) (TTS no Telegram) | roda `tools/install.py`: Edge, Piper, voz pt-BR e, se optado, F5-TTS; desliga o áudio nativo duplicado |
| [browser-automation](https://github.com/eliasrosa/browser-automation-skill) (Chrome via CDP) | roda `tools/check.py`: playwright-cli, Node, Chrome, remote debugging |

O que é específico de cada skill fica nela (fonte única): o crew-setup só chama o
`install.py` e o `check.py`. Para vincular outra skill, siga a convenção da skill
`create-skill` (seção "Instalação") e adicione a linha no `linked-skills.txt`.

## Fluxo recomendado

1. **Diagnóstico:** `bash tools/crew-check.sh`. Confere o ambiente contra o perfil e roda o
   `check.py` de cada skill vinculada.
2. **Plano:** `bash tools/crew-setup.sh --plan` mostra o que seria feito, sem alterar nada.
3. **Setup:** `bash tools/crew-setup.sh`.
4. **Auditoria (depois do restart):** `python3 tools/crew-audit.py`. Todo update muda algo
   que o diagnóstico não enxerga:

| Seção | O que procura |
|---|---|
| Log do gateway | erros/warnings desde o último start, agrupados e cruzados com o catálogo `KNOWN` |
| Modelos | ids em `config.json` e `~/.kiro/agents/*.json` fora de `kiro-cli chat --list-models` |
| Venv antigo | `crew-venv-<versão>` velho em systemd, ldconfig, `.bashrc`, config e agents; `LD_PRELOAD` legado |
| Crash dumps | dumps com stack trace desde o start |
| Drift de config | diff do `config.json` contra o snapshot anterior (`.data/config-baseline.json`) |

5. **Fechar o ciclo (melhoria contínua):**
   - Linha "sem assinatura conhecida" que se repete vira entrada nova em `KNOWN` no `crew-audit.py`.
   - Chave que o update trocou e precisa ser reaplicada vira `_config_check` no
     `crew-check.sh` e, se for o caso, um ajuste no passo 5/7 do `crew-setup.sh`.
   - Preferência pessoal (que não vale para todo mundo) vai no `.data/prefs.conf`, não no código.
   - Correção nova entra na tabela **Erros Comuns**.
   - Com o ambiente saudável, rodar a auditoria sem `--no-save` para gravar o snapshot.

O agente **não** altera `~/.kiro/crew/config.json` (protegido). Correções de config saem
como `kirocrew config set ...` para o usuário rodar, ou ajuste em Settings no dashboard.

## Personalizar sem mexer no código

| Arquivo (em `.data/`, gitignored) | Para quê |
|---|---|
| `profile.env` | perfil da máquina (gerado pelo setup; pode editar à mão) |
| `extras.txt` | pacotes extras seus para o venv, formato `requirements.txt`; o setup instala e o check confere |
| `prefs.conf` | preferências pessoais conferidas pelo check, uma `chave=valor` por linha (ex.: `agent.reasoning_effort=max`) |

## Caminho estável e a libggml-cuda

O Crew instala cada versão numa pasta nova (`<KIROCREW_HOME>-venv-<versão>`) e troca o alvo
do link `<KIROCREW_HOME>-venv-current` a cada update. O setup grava **o link**, nunca a pasta
com versão, no `/etc/ld.so.conf.d/kirocrew-whisper.conf`. Assim o arquivo não fica velho
no update e não precisa de `sudo` de novo.

A `libggml.so` do pywhispercpp procura a `libggml-cuda` num diretório temporário do build,
que some depois da instalação. Quem encontra a lib é o cache do ldconfig. Medido no
0.11.1: sem `LD_PRELOAD`, só com o ldconfig, o whisper sobe com `using CUDA0 backend`.

O `LD_PRELOAD` no systemd (solução antiga) foi retirado: o gateway repassa o ambiente a
todo processo filho (bash, git, node, MCPs), e cada um carregava a lib CUDA inteira
(medido: ~56 ms e ~50 MB a mais por processo). Se o STT cair para CPU mesmo com o
ldconfig certo, o plano B é `crew-setup.sh --ld-preload`.

Não transformar `<KIROCREW_HOME>-venv` (sem versão) em link: o Crew trata essa pasta como
fallback legado e não a renomeia, move ou converte.

## Wheel do pywhispercpp guardado

O venv novo vem sem extras por design, então o pywhispercpp precisa ser reinstalado a
cada update. No perfil `gpu`, o passo 2/7 compila o wheel com CUDA **uma vez** e o guarda
em `.data/wheels/<cpXY>-cuda<versão>/`. Nos updates seguintes reinstala dele em segundos.
Recompila sozinho quando muda a versão do Python ou do CUDA; para forçar, `--rebuild`.

## Estrutura da skill

```
crew-setup/
├── SKILL.md
├── README.md
└── tools/
    ├── lib.sh                      # caminhos, detecção do ambiente, perfil, skills vinculadas
    ├── crew-check.sh               # diagnóstico conforme o perfil (só lê)
    ├── crew-setup.sh               # setup/restauração em 7 passos
    ├── crew-audit.py               # auditoria pós-update (logs, modelos, paths, drift)
    ├── linked-skills.txt           # skills que o setup restaura
    └── requirements-transcribe.txt # pacotes do perfil transcribe
```

`.data/` (gitignored) guarda o perfil, as personalizações, o snapshot da auditoria e o
wheel do pywhispercpp.

> **Nota sobre o padrão:** a skill `create-skill` recomenda scripts em Python e um `check.py`. Esta skill usa bash porque lida direto com `systemctl`, `ldconfig`, `nvidia-smi` e paths de sistema. O `crew-check.sh` cumpre o papel do `check.py`. É uma exceção justificada para skill de sistema.

## Compatibilidade

| Ambiente | Suporte |
|----------|---------|
| Linux (Ubuntu/Mint/Debian) + GPU NVIDIA | ✅ Completo (perfil `gpu`) |
| Linux sem GPU | ✅ Perfil `cpu` (whisper na CPU, modelo `small`), `transcribe` ou `off` |
| Linux + GPU AMD (ROCm) | ⚠️ Perfil `cpu`; build com ROCm não é automatizado |
| macOS | ⚠️ Não suportado — `systemctl` e `ldconfig` não existem |
| Windows | ⚠️ Não suportado — usar WSL2 |

## Erros Comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| STT sumiu / não transcreve após update | o update recriou o venv e apagou o pywhispercpp | `crew-setup.sh` (passos 1-2) |
| "perfil STT=gpu, mas não há GPU NVIDIA" | perfil não combina com a máquina | `crew-setup.sh --reconfigure` e escolher `cpu`, `transcribe` ou `off` |
| "falta o CUDA toolkit (nvcc)" | `nvidia-cuda-toolkit` não instalado | `sudo apt install nvidia-cuda-toolkit`, ou perfil `cpu` |
| STT roda, mas na CPU ("no GPU found") | build sem CUDA ou `kirocrew-whisper.conf` ausente | `crew-setup.sh` (passos 2-3); se persistir, `--ld-preload` |
| `ldconfig -p \| grep ggml` vazio | libs do whisper não registradas | `crew-setup.sh` (passo 3) |
| `ERROR: ld.so: ... cannot be preloaded` em todo comando | `LD_PRELOAD` legado apontando para venv antigo | `crew-setup.sh` (passo 4 remove); no terminal aberto, `unset LD_PRELOAD` |
| TTS do dashboard com fonética de inglês | provider `piper` removido no 0.11; o fallback `system` sem voz definida | `crew-setup.sh` (passo 5: `system` + `voice_reply.system_voice`) |
| `voice_reply.provider 'piper' was removed` no log | config antiga | idem acima |
| Áudio indesejado no Telegram | `voice_reply.enabled` ou `telegram.voice_replies` = true | o `install.py` da voxlocal desliga os dois (passo 6) |
| Skill vinculada "é cópia sem git" | instalada com `cp -r` | `git clone <url> ~/.kiro/skills/<pasta>` e mover a cópia para backup |
| Sub-agentes falham com `InvalidModelError` | modelo fixo saiu do catálogo | `crew-setup.sh` (passo 5 põe `auto`); `crew-audit.py` lista as chaves |
| Build do pywhispercpp falha | falta `build-essential`, `cmake` ou `git` | instalar e rodar `crew-check.sh` antes |
| `whisper_full_with_state: failed to decode` isolado | áudio curto ou silencioso | nenhuma; só investigar se repetir |
| "Não rode com sudo" | script chamado com `sudo` | rodar como o próprio usuário; o setup pede a senha sozinho |

## Verificação manual

```bash
# STT na GPU no start atual
journalctl -u kirocrew.service --since "$(systemctl show kirocrew.service -p ActiveEnterTimestamp --value)" --no-pager | grep -E 'CUDA0|no GPU'

# Libs do whisper no cache do ldconfig
ldconfig -p | grep ggml

# Perfil salvo
cat ~/.kiro/skills/crew-setup/.data/profile.env

# Venv ativo
readlink -f ~/.kiro/crew-venv-current
```
