# kirocrew-setup-skill

Skill para configurar o [Kiro Crew](https://kiro.dev) numa máquina Linux e restaurar o ambiente depois de cada update.

O update do Kiro Crew cria um venv novo e apaga o que foi instalado à parte: o STT local
(whisper), os pacotes de voz e as dependências de outras skills. Esta skill detecta o
ambiente, pergunta o perfil da máquina uma vez e, a cada update, restaura tudo em poucos
minutos. Depois do restart, uma auditoria revisa o log do gateway, os modelos e o que
mudou na config.

## Instalação

```bash
git clone https://github.com/eliasrosa/kirocrew-setup-skill ~/.kiro/skills/crew-setup
```

O Kiro Crew carrega as skills de `~/.kiro/skills/` sozinho, na próxima sessão.

## Requisitos

| Item | Quando | Como instalar |
|---|---|---|
| Kiro Crew rodando via systemd (`kirocrew.service`) | sempre | instalador oficial |
| Linux com `systemctl` | sempre | — |
| `git` | sempre | `sudo apt install git` |
| `ffmpeg` | STT local (`gpu`/`cpu`) | `sudo apt install ffmpeg` |
| GPU NVIDIA + driver + `nvidia-cuda-toolkit` | perfil `gpu` | `sudo apt install nvidia-cuda-toolkit` |
| `build-essential`, `cmake` | perfil `gpu`, na primeira compilação | `sudo apt install build-essential cmake` |
| `espeak-ng` | TTS nativo do dashboard | `sudo apt install espeak-ng` |

O diagnóstico confere só o que o seu perfil precisa:

```bash
bash ~/.kiro/skills/crew-setup/tools/crew-check.sh
```

## Uso

Nenhum script roda com `sudo`. O `crew-setup.sh` pede a senha sozinho nos passos que mexem no sistema.

**1. Ver o plano (não altera nada):**

```bash
bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh --plan
```

**2. Configurar / restaurar:**

```bash
bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh
```

Na primeira vez ele mostra o que detectou (GPU, CUDA, espeak-ng) e pergunta o perfil:

| Pergunta | Opções |
|---|---|
| Transcrição (STT) | `gpu` (whisper na GPU NVIDIA), `cpu` (whisper na CPU), `transcribe` (Amazon Transcribe), `off` |
| Modelo do whisper | `large-v3-turbo` (padrão na GPU), `medium`, `small` (padrão na CPU), `base` |
| Idioma do STT | padrão: o do locale do sistema |
| Voz do TTS nativo | voz do espeak-ng, ex.: `pt-br` |
| Skills vinculadas | S/n para cada skill da lista |

A resposta fica em `.data/profile.env`. Nos próximos updates o setup reusa o perfil sem
perguntar. Para mudar: `--reconfigure`. Para automação sem perguntas: `--yes`.

| Passo | Ação |
|---|---|
| 1/7 | Pacotes extras (Amazon Transcribe, se for o perfil, e os seus em `.data/extras.txt`) |
| 2/7 | pywhispercpp: na GPU, do wheel com CUDA guardado (compila na 1ª vez, ~10-15 min); na CPU, do PyPI |
| 3/7 | ldconfig para as libs do whisper, pelo caminho estável `~/.kiro/crew-venv-current` |
| 4/7 | Garante o `LD_PRELOAD` da libggml-cuda no systemd (GPU); remove quando o STT não é GPU |
| 5/7 | Config do gateway: STT do perfil, TTS nativo (`system` + voz), modelos de LLM em `auto` |
| 6/7 | Skills vinculadas: clona se faltar, roda o `install.py` e o `check.py` de cada uma |
| 7/7 | Reinicia o Kiro Crew e confirma o STT na GPU |

Antes de mexer em qualquer coisa, o setup valida o perfil contra a máquina: perfil `gpu`
sem GPU NVIDIA ou sem CUDA toolkit para com a correção, em vez de compilar e falhar.

**3. Auditar o que o update quebrou ou mudou (depois do restart):**

```bash
python3 ~/.kiro/skills/crew-setup/tools/crew-audit.py
```

Olha o que o diagnóstico de ambiente não vê:
- Erros e warnings no log do gateway desde o último start, agrupados e cruzados com um catálogo de causas conhecidas
- Modelos configurados (`config.json` e `~/.kiro/agents/*.json`) que saíram do catálogo do `kiro-cli`
- Paths de venv antigo (`crew-venv-<versão>`) que sobraram em systemd, ldconfig, shell e config, e `LD_PRELOAD` legado
- Crash dumps com stack trace
- Drift de config: compara o `config.json` com o snapshot da auditoria anterior (`.data/config-baseline.json`, fora do git, segredos mascarados)

Rode uma vez com o ambiente saudável para gravar o snapshot. No próximo update, a auditoria mostra exatamente quais chaves mudaram. `--no-save` audita sem atualizar o snapshot; `--since "2 hours ago"` muda a janela do log. Exit 1 quando há problema bloqueante.

Os scripts só alteram a config do Crew com `kirocrew config set`. O agente do Crew não consegue alterar o `config.json` (é protegido), então as correções de config que ele propõe ficam como comando para você rodar.

## Skills vinculadas

`tools/linked-skills.txt` lista as skills que o setup instala e restaura:

| Skill | Para quê |
|---|---|
| [voxlocal](https://github.com/eliasrosa/voxlocal-skill) | áudio (TTS pt-BR) como voice message no Telegram |
| [browser-automation](https://github.com/eliasrosa/browser-automation-skill) | dirigir o Chrome logado do usuário via CDP (playwright-cli) |

Cada skill mantém as próprias dependências (`tools/install.py`) e o próprio pré-check
(`tools/check.py`); o setup só os chama. Para vincular outra skill, ela precisa seguir a
mesma convenção (descrita na [create-skill](https://github.com/eliasrosa/create-skill)) e
ganhar uma linha `<pasta> <url-do-repo>` no `linked-skills.txt`.

## Personalizar sem mexer no código

| Arquivo (em `.data/`, fora do git) | Para quê |
|---|---|
| `profile.env` | perfil da máquina (gerado pelo setup; pode editar à mão) |
| `extras.txt` | pacotes extras seus para o venv, no formato `requirements.txt` |
| `prefs.conf` | preferências pessoais que o check confere, uma `chave=valor` por linha (ex.: `agent.reasoning_effort=max`) |

## Quando usar

- Após `kirocrew update`: o update recria o venv e apaga os pacotes extras
- STT parou de funcionar ou não usa a GPU
- TTS do dashboard com sotaque errado depois do update
- `ModuleNotFoundError` de pacote de voz ou de skill vinculada
- Configurando o Crew numa máquina nova, com ou sem GPU

## Compatibilidade

| Ambiente | Suporte |
|----------|---------|
| Linux + GPU NVIDIA | ✅ Completo (perfil `gpu`) |
| Linux sem GPU | ✅ Perfis `cpu`, `transcribe` ou `off` |
| Linux + GPU AMD (ROCm) | ⚠️ Perfil `cpu`; build com ROCm não é automatizado |
| macOS | ⚠️ `systemctl` e `ldconfig` não existem — adaptações necessárias |
| Windows | ⚠️ Usar WSL2 (Ubuntu/Debian) |

## Estrutura

```
crew-setup/
├── SKILL.md                        # instruções para o agente do Kiro Crew
├── README.md
└── tools/
    ├── lib.sh                      # caminhos, detecção do ambiente, perfil, skills vinculadas
    ├── crew-check.sh               # diagnóstico conforme o perfil (só lê)
    ├── crew-setup.sh               # setup/restauração em 7 passos
    ├── crew-audit.py               # auditoria pós-update (logs, modelos, paths, drift)
    ├── linked-skills.txt           # skills que o setup restaura
    └── requirements-transcribe.txt # pacotes do perfil transcribe
```

`.data/` (fora do git) guarda o perfil, as personalizações, o snapshot da auditoria e o wheel compilado do pywhispercpp.
