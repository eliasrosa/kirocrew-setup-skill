# kirocrew-setup-skill

Skill para diagnóstico e restauração do ambiente [Kiro Crew](https://kiro.dev) após updates, ou para configurar o Crew em uma máquina nova.

Verifica compatibilidade, reinstala pacotes extras, recompila STT com CUDA e aplica configurações recomendadas — tudo com checklist visual.

## Instalação

```bash
git clone https://github.com/eliasrosa/kirocrew-setup-skill ~/.kiro/skills/crew-setup
```

A skill é carregada automaticamente pelo Kiro Crew na próxima sessão.

## Uso

**1. Diagnosticar o ambiente:**
```bash
bash ~/.kiro/skills/crew-setup/tools/crew-check.sh
```

Verifica e orienta sobre:
- Sistema operacional (Linux ✅ / macOS ⚠️ / Windows ⚠️)
- GPU (NVIDIA CUDA / AMD ROCm / sem GPU)
- Dependências do sistema (ffmpeg, cmake, gcc, build-essential...)
- CLIs recomendados (gh, jq, docker, kubectl, aws, az...)
- Pacotes extras no venv do Crew
- Modelos STT (Whisper) e TTS (Piper)
- Configurações recomendadas do gateway

**2. Restaurar/configurar:**
```bash
bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh
```

O que o setup faz:
| Passo | Ação |
|-------|------|
| 1/6 | Instala pacotes extras (boto3, amazon-transcribe, edge-tts, httpx) |
| 2/6 | Recompila pywhispercpp com CUDA (`GGML_CUDA=1`, ~10-15 min) |
| 3/6 | Configura ldconfig para libs CUDA do whisper |
| 4/6 | Aplica configurações de STT e TTS no gateway |
| 5/6 | Adota config defaults atualizados do Crew |
| 6/6 | Reinicia o Crew e confirma STT na GPU |

## Quando usar

- Após `kirocrew update` — o update recria o venv e apaga pacotes extras
- STT parou de funcionar ou não usa GPU
- `ModuleNotFoundError: edge_tts` ou `httpx`
- Configurando o Crew em uma máquina nova

## Personalizar pacotes extras

Edite `tools/extras.txt` para adicionar ou remover pacotes do venv:

```
boto3>=1.34,<2
amazon-transcribe>=0.6,<1
edge-tts>=7.0
httpx>=0.27
```

O `crew-setup.sh` usa esse arquivo como fonte da verdade (exceto `pywhispercpp`, que é sempre recompilado com CUDA separadamente).

## Compatibilidade

| Ambiente | Suporte |
|----------|---------|
| Linux + GPU NVIDIA | ✅ Completo |
| Linux + GPU AMD (ROCm) | ⚠️ Trocar `GGML_CUDA=1` por `GGML_HIPBLAS=1` no crew-setup.sh |
| Linux sem GPU | ⚠️ STT roda em CPU — considere modelo `small` em vez de `large-v3-turbo` |
| macOS | ⚠️ `systemctl` e `ldconfig` não existem — adaptações necessárias |
| Windows | ⚠️ Usar WSL2 (Ubuntu/Debian) |

## Estrutura

```
crew-setup/
├── SKILL.md              # instruções para o agente Kiro Crew
└── tools/
    ├── crew-check.sh     # diagnóstico de compatibilidade
    ├── crew-setup.sh     # setup/restauração completo
    └── extras.txt        # lista de pacotes extras do venv
```

## Requisitos

- [Kiro Crew](https://kiro.dev) instalado e rodando via systemd
- Linux com systemd
- GPU NVIDIA com driver instalado (para STT em GPU)
- `nvidia-cuda-toolkit` (`sudo apt install nvidia-cuda-toolkit`)
- `build-essential cmake` (`sudo apt install build-essential cmake`)
