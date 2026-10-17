---
name: crew-setup
description: >
  Configurar ou restaurar o ambiente do Kiro Crew após um update. Use quando
  o STT parou, voz não funciona, CUDA sumiu, pywhispercpp quebrou, pacotes
  extras sumiram após um update, ou para configurar o Crew em uma máquina nova.
inclusion: auto
---

# Skill: crew-setup

Diagnóstica e restaura o ambiente completo do Kiro Crew.
Pode ser compartilhada como repositório independente no GitHub.

## Quando usar

- Após `kirocrew update` ou update automático do Crew
- STT parou de funcionar / sumiu do dashboard
- `ModuleNotFoundError: No module named 'edge_tts'` ou `'httpx'`
- CUDA não aparece no log (`whisper_backend_init_gpu`)
- `voice_reply.enabled` voltou para `true` (áudio indesejado no Telegram)
- Configurando o Crew em uma máquina nova (Linux)

## Fluxo recomendado

**1. Diagnóstico primeiro:**
```bash
bash ~/.kiro/skills/crew-setup/tools/crew-check.sh
```
Verifica SO, GPU, dependências, venv, modelos. Avisa o que precisa adaptar.

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
| 4/6 | Aplica configurações de STT (provider, modelo, idioma) e TTS (piper) |
| 5/6 | Adota config defaults atualizados do Crew (sem sobrescrever customizações) |
| 6/6 | Reinicia o Crew e confirma `using CUDA0 backend` no log |

## Estrutura da skill

```
crew-setup/
├── SKILL.md              # este arquivo
└── tools/
    ├── crew-check.sh     # diagnóstico de compatibilidade
    ├── crew-setup.sh     # setup/restauração completo
    └── extras.txt        # lista de pacotes extras do venv
```

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

## Verificação manual

```bash
# Confirmar CUDA no STT após restart
journalctl -u kirocrew.service -n 30 --no-pager | grep -E 'CUDA0|backend_init_gpu'

# Confirmar libs registradas
ldconfig -p | grep whisper

# Confirmar pacotes no venv
~/.kiro/crew-venv/bin/pip list | grep -Ei "boto3|amazon|pywhisper|edge-tts|httpx"
```
