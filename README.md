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
| 4/6 | Configura `LD_PRELOAD` no systemd (override.conf), crítico para o CUDA |
| 5/6 | Aplica configurações de STT e TTS e põe os modelos de LLM em `auto` |
| 6/6 | Reinicia o Crew e confirma STT na GPU |

**3. Auditar o que o update quebrou ou mudou (depois do restart):**
```bash
python3 ~/.kiro/skills/crew-setup/tools/crew-audit.py
```

Olha o que o diagnóstico de ambiente não vê:
- Erros e warnings no log do gateway desde o último start, agrupados e cruzados com um catálogo de causas conhecidas
- Modelos configurados (`config.json` e `~/.kiro/agents/*.json`) que saíram do catálogo do `kiro-cli`
- Paths de venv antigo (`crew-venv-<versão>`) que sobraram em systemd, ldconfig, shell e config
- Crash dumps com stack trace
- Drift de config: compara o `config.json` com o snapshot da auditoria anterior (`.data/config-baseline.json`, fora do git, segredos mascarados)

Rode uma vez com o ambiente saudável para gravar o snapshot. No próximo update, a auditoria mostra exatamente quais chaves mudaram. `--no-save` audita sem atualizar o snapshot; `--since "2 hours ago"` muda a janela do log. Exit 1 quando há problema bloqueante.

O script só reporta. O `config.json` do Crew é protegido contra escrita do agente, então as correções de config ficam como comando para o usuário rodar.

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
    ├── crew-audit.py     # auditoria pós-update (logs, modelos, paths, drift)
    └── extras.txt        # lista de pacotes extras do venv
```

`.data/` (gitignored) guarda o snapshot local da auditoria.

## Requisitos

- [Kiro Crew](https://kiro.dev) instalado e rodando via systemd
- Linux com systemd
- GPU NVIDIA com driver instalado (para STT em GPU)
- `nvidia-cuda-toolkit` (`sudo apt install nvidia-cuda-toolkit`)
- `build-essential cmake` (`sudo apt install build-essential cmake`)
