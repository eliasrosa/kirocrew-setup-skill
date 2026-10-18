#!/usr/bin/env bash
# crew-check.sh — parte da skill crew-setup
# Verifica compatibilidade do ambiente e configurações recomendadas do Kiro Crew.
# Detecta SO, GPU, dependências, CLIs, modelos e settings do gateway.
#
# Uso: bash ~/.kiro/skills/crew-setup/tools/crew-check.sh

VENV_PIP="$HOME/.kiro/crew-venv/bin/pip"
VENV_PYTHON="$HOME/.kiro/crew-venv/bin/python3"
KIROCREW="kirocrew"

# Diretório base do Kiro Crew — respeita KIROCREW_HOME quando definida
CREW_HOME="${KIROCREW_HOME:-$HOME/.kiro/crew}"

ok()      { echo "  ✅  $*"; }
warn()    { echo "  ⚠️   $*"; WARNINGS+=("$*"); }
fail()    { echo "  ❌  $*"; ERRORS+=("$*"); }
info()    { echo "  ℹ️   $*"; }
suggest() { echo "  💡  $*"; SUGGESTIONS+=("$*"); }
section() { echo ""; echo "▸ $*"; }

WARNINGS=()
ERRORS=()
SUGGESTIONS=()

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Kiro Crew — diagnóstico de ambiente        ║"
echo "╚══════════════════════════════════════════════╝"

# ── 1. Sistema Operacional ────────────────────────────────────────────────────
section "Sistema operacional"
OS="$(uname -s)"
case "$OS" in
  Linux)
    DISTRO=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "desconhecido")
    VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "")
    ok "Linux ($DISTRO $VERSION)"
    ;;
  Darwin)
    warn "macOS — crew-setup.sh usa systemctl/ldconfig (Linux only). Adaptações necessárias."
    ;;
  MINGW*|MSYS*|CYGWIN*)
    warn "Windows — use WSL2 (Ubuntu/Debian) para compatibilidade total."
    ;;
  *)
    warn "SO desconhecido ($OS) — compatibilidade não garantida."
    ;;
esac

# ── 2. GPU ─────────────────────────────────────────────────────────────────────
section "GPU"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -1)
  GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
  GPU_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -1)
  [ -z "$GPU_NAME" ] && GPU_NAME="NVIDIA (detalhes indisponíveis)"
  [ -z "$GPU_MEM"  ] && GPU_DRIVER=$(nvidia-smi 2>/dev/null | grep -oP 'Driver Version: \K[\d.]+' || echo "N/A")
  ok "NVIDIA: ${GPU_NAME} (${GPU_MEM:-?} MiB)"
  ok "Driver: ${GPU_DRIVER:-N/A}"
  if command -v nvcc &>/dev/null; then
    ok "CUDA toolkit: $(nvcc --version 2>/dev/null | grep -oP 'V[\d.]+')"
  else
    warn "nvidia-cuda-toolkit não encontrado — necessário para compilar pywhispercpp com CUDA."
    suggest "sudo apt install nvidia-cuda-toolkit"
  fi
elif command -v rocm-smi &>/dev/null || command -v rocminfo &>/dev/null; then
  warn "GPU AMD/ROCm detectada — trocar GGML_CUDA=1 por GGML_HIPBLAS=1 no crew-setup.sh"
  suggest "Edite tools/crew-setup.sh: substitua GGML_CUDA=1 por GGML_HIPBLAS=1"
else
  warn "Nenhuma GPU NVIDIA detectada — STT rodará em CPU (muito mais lento para large-v3-turbo)."
  suggest "Para CPU, considere usar o modelo 'small' em vez de 'large-v3-turbo' (kirocrew config set stt.model small)"
fi

# ── 3. Dependências do sistema ─────────────────────────────────────────────────
section "Dependências do sistema"
for cmd in git curl sudo ffmpeg cmake gcc g++ make; do
  if command -v $cmd &>/dev/null; then
    ok "$cmd"
  else
    fail "$cmd não encontrado"
    suggest "sudo apt install $([ "$cmd" = "cmake" ] || [ "$cmd" = "gcc" ] || [ "$cmd" = "g++" ] || [ "$cmd" = "make" ] && echo 'build-essential cmake' || echo "$cmd")"
  fi
done

if command -v systemctl &>/dev/null; then
  ok "systemctl (systemd)"
else
  warn "systemctl não disponível — o Crew pode não estar rodando via systemd."
fi

if command -v ldconfig &>/dev/null; then
  ok "ldconfig"
else
  warn "ldconfig não encontrado — configuração de libs CUDA pode falhar."
fi

# ── 4. CLIs recomendados ───────────────────────────────────────────────────────
section "CLIs recomendados"
declare -A CLI_DESC=(
  [gh]="GitHub CLI — abrir PRs, gerenciar issues, interagir com repos"
  [jq]="JSON processor — manipular outputs de APIs e configs"
  [fzf]="Fuzzy finder — busca interativa no terminal"
  [docker]="Containers — ambientes isolados de desenvolvimento"
  [kubectl]="Kubernetes — gerenciar clusters K8s"
  [aws]="AWS CLI — infraestrutura na nuvem"
  [az]="Azure CLI — integração com Azure DevOps e recursos Azure"
)
for cmd in gh jq fzf docker kubectl aws az; do
  if command -v $cmd &>/dev/null; then
    ok "$cmd — ${CLI_DESC[$cmd]}"
  else
    suggest "Instalar $cmd (${CLI_DESC[$cmd]})"
  fi
done

# ── 5. Python e venv do Crew ───────────────────────────────────────────────────
section "Python e venv do Crew"
if [ -f "$VENV_PYTHON" ]; then
  PY_VERSION=$("$VENV_PYTHON" --version 2>&1)
  ok "venv do Crew: $PY_VERSION"
else
  fail "venv do Crew não encontrado em ~/.kiro/crew-venv — Kiro Crew instalado?"
fi

if command -v $KIROCREW &>/dev/null; then
  CREW_VERSION=$(grep "^Version:" ~/.kiro/crew-venv/lib/python3.12/site-packages/kirocrew-*.dist-info/METADATA 2>/dev/null | head -1 | awk '{print $2}')
  ok "kirocrew CLI — versão ${CREW_VERSION:-desconhecida}"
else
  fail "kirocrew CLI não encontrado no PATH"
fi

section "Pacotes extras no venv"
declare -A PKG_DESC=(
  [boto3]="AWS SDK — necessário para Amazon Transcribe"
  [amazon-transcribe]="STT alternativo na nuvem (AWS)"
  [pywhispercpp]="Motor principal do STT local (whisper.cpp)"
  [edge-tts]="TTS online via Microsoft Edge (voxlocal)"
  [httpx]="HTTP client assíncrono (usado pelo voxlocal)"
)
for pkg in boto3 amazon-transcribe pywhispercpp edge-tts httpx; do
  if "$VENV_PIP" show "$pkg" &>/dev/null 2>&1; then
    VERSION=$("$VENV_PIP" show "$pkg" 2>/dev/null | grep "^Version:" | awk '{print $2}')
    ok "$pkg $VERSION — ${PKG_DESC[$pkg]}"
  else
    warn "$pkg não instalado — ${PKG_DESC[$cmd]}"
    suggest "Rodar crew-setup.sh para instalar todos os pacotes extras"
  fi
done

# Verificar se pywhispercpp foi compilado com CUDA
if "$VENV_PIP" show pywhispercpp &>/dev/null 2>&1; then
  if ls ~/.kiro/crew-venv/lib/python3.12/site-packages/libggml-cuda* &>/dev/null 2>&1; then
    ok "pywhispercpp compilado com CUDA (libggml-cuda encontrada)"
  else
    warn "pywhispercpp instalado mas sem CUDA — STT rodará em CPU"
    suggest "Rodar crew-setup.sh para recompilar com GGML_CUDA=1"
  fi
fi

# ── 6. Modelos ─────────────────────────────────────────────────────────────────
section "Modelos STT (Whisper)"
WHISPER_DIR="$CREW_HOME/models/whisper"
if [ -d "$WHISPER_DIR" ] && ls "$WHISPER_DIR"/*.bin &>/dev/null 2>&1; then
  ok "Modelos encontrados:"
  ls -lh "$WHISPER_DIR"/*.bin 2>/dev/null | awk '{print "       " $5 "  " $9}'
  if ls "$WHISPER_DIR"/ggml-large-v3-turbo.bin &>/dev/null 2>&1; then
    ok "Modelo recomendado (large-v3-turbo) presente"
  else
    suggest "Baixar large-v3-turbo (~1.6 GB) — melhor qualidade de STT"
    suggest "kirocrew config set stt.model large-v3-turbo  (Crew baixa automaticamente)"
  fi
else
  warn "Nenhum modelo Whisper encontrado — o Crew baixa automaticamente no primeiro uso."
fi

section "Modelo TTS (Piper)"
PIPER_MODEL="$CREW_HOME/models/piper/pt_BR-faber-medium.onnx"
if [ -f "$PIPER_MODEL" ]; then
  ok "pt_BR-faber-medium.onnx ($(du -h "$PIPER_MODEL" | cut -f1))"
else
  suggest "Baixar modelo Piper pt-BR para TTS offline:"
  suggest "https://huggingface.co/rhasspy/piper-voices/tree/main/pt/pt_BR/faber/medium"
fi

# ── 7. Configurações do gateway ───────────────────────────────────────────────
section "Configurações recomendadas do gateway"

_config_check() {
  local key="$1" expected="$2" desc="$3"
  local actual
  actual=$(kirocrew config get "$key" 2>/dev/null | tr -d '"' | xargs)
  if [ "$actual" = "$expected" ]; then
    ok "$key = $expected — $desc"
  else
    warn "$key = ${actual:-não definido} (recomendado: $expected) — $desc"
    suggest "kirocrew config set $key $expected"
  fi
}

_config_check "stt.enabled"       "True"            "STT ativo"
_config_check "stt.provider"      "local"           "STT local (whisper.cpp, sem custo de API)"
_config_check "stt.model"         "large-v3-turbo"  "Melhor modelo de STT"
_config_check "stt.language_code" "pt-BR"           "Idioma do STT"
_config_check "stt.polish"        "True"            "Pós-processamento da transcrição"
_config_check "voice_reply.enabled" "False"         "Desativa envio automático de áudio no Telegram"
_config_check "agent.reasoning_effort" "max"        "Máxima qualidade de raciocínio"
_config_check "agent.approval_mode"    "auto"       "Auto-aprovação de ferramentas"
_config_check "agent.tool_search"      "True"       "Busca de ferramentas sob demanda"
_config_check "skills.auto_create_from_sessions" "True" "Criação automática de skills"
_config_check "knowledge.auto_add_documents"     "True" "Ingestão automática de documentos"
_config_check "dashboard.theme_color"  "amoled-midnight" "Tema recomendado"
_config_check "dashboard.widget_density" "more"    "Densidade de widgets"

# ── 8. Resultado final ─────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
if [ ${#ERRORS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ] && [ ${#SUGGESTIONS[@]} -eq 0 ]; then
  echo "  ✅ ✅  Ambiente 100% compatível e configurado!"
else
  [ ${#ERRORS[@]} -gt 0 ] && echo "  ❌  ${#ERRORS[@]} problema(s) bloqueante(s):" && for e in "${ERRORS[@]}"; do echo "    • $e"; done
  [ ${#WARNINGS[@]} -gt 0 ] && echo "  ⚠️   ${#WARNINGS[@]} aviso(s):" && for w in "${WARNINGS[@]}"; do echo "    • $w"; done
  [ ${#SUGGESTIONS[@]} -gt 0 ] && echo "  💡  ${#SUGGESTIONS[@]} sugestão(ões):" && for s in "${SUGGESTIONS[@]}"; do echo "    • $s"; done
fi
echo ""
echo "  Próximo passo:"
echo "  bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh"
echo "════════════════════════════════════════════════"
echo ""
