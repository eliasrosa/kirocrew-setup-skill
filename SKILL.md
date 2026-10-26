---
name: crew-setup
description: >
  Use when the Kiro Crew environment needs setup or repair after an update — STT
  stopped, voice broke, CUDA vanished, pywhispercpp failed to build, extra venv
  packages disappeared, voice_reply turned itself back on, or when setting Crew up
  on a new Linux machine.
inclusion: auto
---

# Skill: crew-setup

## Visão Geral

Diagnostica e restaura o ambiente completo do Kiro Crew num Linux: pacotes extras do
venv, STT (Whisper) compilado com CUDA, **LD_PRELOAD no systemd** (crítico!), configs
de STT/TTS do gateway e restart. Pode ser compartilhada como repositório independente
no GitHub.

## Quando Usar

- Após `kirocrew update` ou update automático do Crew (recria o venv e apaga pacotes extras)
- STT parou de funcionar / sumiu do dashboard
- `ModuleNotFoundError: No module named 'edge_tts'` ou `'httpx'`
- CUDA não aparece no log (`whisper_backend_init_gpu`)
- **"no GPU found" mesmo com libs CUDA presentes** — falta LD_PRELOAD no systemd
- `voice_reply.enabled` voltou para `true` (áudio indesejado no Telegram)
- Configurando o Crew numa máquina nova (Linux)

**Quando NÃO usar:** macOS/Windows nativos (`systemctl`/`ldconfig` não existem — ver
Compatibilidade); ajustes pontuais de config que não envolvem venv/STT.

## Referência Rápida

| Operação | Comando |
|---|---|
| Diagnóstico | `bash ~/.kiro/skills/crew-setup/tools/crew-check.sh` |
| Setup/restauração | `bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh` |
| Confirmar CUDA no STT | `journalctl -u kirocrew.service -n 50 --no-pager \| grep -iE 'CUDA0\|backend_init'` |
| Confirmar libs do whisper | `ldconfig -p \| grep whisper` |
| Conferir LD_PRELOAD | `cat /etc/systemd/system/kirocrew.service.d/override.conf` |
| Conferir pacotes do venv | `~/.kiro/crew-venv-current/bin/pip list \| grep -Ei "boto3\|amazon\|pywhisper\|edge-tts\|httpx"` |
| Editar lista de extras | `tools/extras.txt` (fonte da verdade do setup) |

## Fluxo recomendado

**1. Diagnóstico primeiro:**
```bash
bash ~/.kiro/skills/crew-setup/tools/crew-check.sh
```
Verifica SO, GPU, dependências, venv, modelos, LD_PRELOAD e configs. Avisa o que precisa corrigir.

**2. Setup/restauração:**
```bash
bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh
```

## O que o crew-setup.sh faz

| Passo | O que faz |
|-------|-----------|
| 1/6 | Instala pacotes extras do `extras.txt` (boto3, amazon-transcribe, edge-tts, httpx) |
| 2/6 | Recompila pywhispercpp com `GGML_CUDA=1` (~10-15 min) |
| 3/6 | Configura ldconfig para as libs CUDA do whisper |
| 4/6 | **Configura LD_PRELOAD no systemd** (override.conf) — crítico para CUDA funcionar |
| 5/6 | Aplica configurações de STT (provider, modelo, idioma) e TTS (piper, voice_reply off) |
| 6/6 | Reinicia o Crew e confirma `using CUDA0 backend` no log |

## Detecção dinâmica do venv

Os scripts detectam automaticamente o venv ativo:
- Se `~/.kiro/crew-venv-current` (symlink) existir → usa ele
- Senão → fallback para `~/.kiro/crew-venv` (legado)

Isso permite que a skill funcione em qualquer versão do Kiro Crew (0.9, 0.10, 0.11...).

## Estrutura da skill

```
crew-setup/
├── SKILL.md              # este arquivo
└── tools/
    ├── crew-check.sh     # diagnóstico de compatibilidade
    ├── crew-setup.sh     # setup/restauração completo
    └── extras.txt        # lista de pacotes extras do venv
```

> **Nota sobre o padrão:** o padrão `create-skill` recomenda scripts em Python e um `check.py` com exit 0/1. Esta skill usa bash intencionalmente — os scripts interagem com `systemctl`, `ldconfig`, `nvidia-smi` e paths de sistema, que são ferramentas de sistema nativas do Linux e mais diretas em shell. O `crew-check.sh` cumpre o papel do `check.py` (diagnóstico com saída visual de ✓/✗), porém em bash. Skills de sistema com forte acoplamento ao SO são uma exceção justificada ao padrão Python.

## Personalizar pacotes extras

Edite `tools/extras.txt` para adicionar ou remover pacotes.
O `crew-setup.sh` usa esse arquivo como fonte da verdade.

## Compatibilidade

| Ambiente | Suporte |
|----------|---------|
| Linux (Ubuntu/Mint/Debian) + GPU NVIDIA | ✅ Completo |
| Linux + GPU AMD (ROCm) | ⚠️ Parcial — trocar `GGML_CUDA=1` por `GGML_HIPBLAS=1` |
| Linux sem GPU | ⚠️ Parcial — STT roda em CPU (mais lento) |
| macOS | ⚠️ Não suportado — `systemctl` e `ldconfig` não existem |
| Windows | ⚠️ Não suportado — usar WSL2 |

## Erros Comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| STT sumiu / não transcreve após update | o update recriou o venv e apagou os extras | rodar `crew-setup.sh` (passos 1-6) |
| `ModuleNotFoundError: edge_tts` / `httpx` | pacote extra ausente no venv | `crew-setup.sh` passo 1/6, ou adicionar em `extras.txt` |
| STT roda, mas na CPU (lento) | pywhispercpp sem CUDA | `crew-setup.sh` passo 2/6 (recompila com `GGML_CUDA=1`) |
| `ldconfig -p \| grep whisper` vazio | libs CUDA do whisper não registradas | `crew-setup.sh` passo 3/6 |
| **"no GPU found" com libs presentes** | **LD_PRELOAD faltando no systemd** | `crew-setup.sh` passo 4/6 |
| Log não mostra `CUDA0 backend` após restart | build sem CUDA ou LD_PRELOAD ausente | refazer passos 2-4, depois conferir o `journalctl` |
| Áudio indesejado no Telegram volta | `voice_reply.enabled` voltou a `true` no update | `crew-setup.sh` passo 5/6 (reaplica a config de TTS) |
| Build do pywhispercpp falha | falta `build-essential`, `cmake` ou `nvidia-cuda-toolkit` | instalar os pacotes de sistema e rodar `crew-check.sh` antes |

## O gotcha do LD_PRELOAD

O `_pywhispercpp.so` **não força `RTLD_GLOBAL`** na `libggml-cuda` ao ser importado pelo Python.
Resultado: o ggml tenta descobrir o backend CUDA em runtime e falha ("no GPU found"), mesmo
com as libs compiladas corretamente e o ldconfig configurado.

**Solução:** forçar o preload da lib CUDA via variável de ambiente no systemd:

```bash
# override.conf em /etc/systemd/system/kirocrew.service.d/
[Service]
Environment="LD_PRELOAD=/caminho/do/venv/lib/python3.12/site-packages/libggml-cuda.so.0"
```

O `crew-setup.sh` configura isso automaticamente no passo 4/6.

## Verificação manual

```bash
# Confirmar CUDA no STT após restart
journalctl -u kirocrew.service -n 50 --no-pager | grep -iE 'CUDA0|backend_init'

# Confirmar LD_PRELOAD no systemd
cat /etc/systemd/system/kirocrew.service.d/override.conf

# Confirmar libs registradas
ldconfig -p | grep whisper

# Confirmar pacotes no venv
~/.kiro/crew-venv-current/bin/pip list | grep -Ei "boto3|amazon|pywhisper|edge-tts|httpx"

# Ver qual venv está ativo
readlink -f ~/.kiro/crew-venv-current
```

## Relacionados

- Runbook `cuda-stt-gpu.md` — detalhes técnicos do gotcha CUDA/LD_PRELOAD
- Runbook `voz-config.md` — configuração geral de voz (TTS/STT)
- Steering `me-voice.md` — regras de comportamento do agente com voz
