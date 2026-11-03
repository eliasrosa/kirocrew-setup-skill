#!/usr/bin/env bash
# crew-check.sh — parte da skill crew-setup
# Verifica compatibilidade do ambiente e configurações recomendadas do Kiro Crew.
# Detecta SO, GPU, dependências, CLIs, modelos e settings do gateway.
#
# Uso: bash ~/.kiro/skills/crew-setup/tools/crew-check.sh

# Não rodar via sudo: o diagnóstico só lê, e como root o HOME vira /root.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  echo "❌ Não rode com sudo. O diagnóstico só lê; rode como o seu usuário:"
  echo "   bash $0"
  exit 1
fi

# Detectar venv ativo via symlink (padrão pós-0.10.0)
if [ -L "$HOME/.kiro/crew-venv-current" ]; then
  CREW_VENV=$(readlink -f "$HOME/.kiro/crew-venv-current")
else
  # Fallback para venv legado (pré-0.10.0)
  CREW_VENV="$HOME/.kiro/crew-venv"
fi

VENV_PIP="$CREW_VENV/bin/pip"
VENV_PYTHON="$CREW_VENV/bin/python3"
KIROCREW="kirocrew"

# Diretório base do Kiro Crew — respeita KIROCREW_HOME quando definida
CREW_HOME="${KIROCREW_HOME:-$HOME/.kiro/crew}"

# Descobrir site-packages dinamicamente
if [ -x "$VENV_PYTHON" ]; then
  SITE_PKGS=$("$VENV_PYTHON" -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null || echo "$CREW_VENV/lib/python3.12/site-packages")
else
  SITE_PKGS="$CREW_VENV/lib/python3.12/site-packages"
fi

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

# Mostrar qual venv está sendo usado
if [ -L "$HOME/.kiro/crew-venv-current" ]; then
  ok "Venv ativo: $CREW_VENV (via symlink crew-venv-current)"
else
  warn "Symlink crew-venv-current não existe — usando venv legado"
  info "Venv: $CREW_VENV"
fi

if [ -f "$VENV_PYTHON" ]; then
  PY_VERSION=$("$VENV_PYTHON" --version 2>&1)
  ok "Python: $PY_VERSION"
else
  fail "venv do Crew não encontrado — Kiro Crew instalado?"
fi

if command -v $KIROCREW &>/dev/null; then
  # Detectar versão do METADATA no venv ativo (não no legado)
  CREW_VERSION=$(find "$SITE_PKGS" -maxdepth 1 -name 'kirocrew-*.dist-info' -exec grep "^Version:" {}/METADATA \; 2>/dev/null | head -1 | awk '{print $2}')
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
    warn "$pkg não instalado — ${PKG_DESC[$pkg]}"
    suggest "Rodar crew-setup.sh para instalar todos os pacotes extras"
  fi
done

# Verificar se pywhispercpp foi compilado com CUDA
if "$VENV_PIP" show pywhispercpp &>/dev/null 2>&1; then
  if ls "$SITE_PKGS"/libggml-cuda* &>/dev/null 2>&1; then
    CUDA_LIB=$(ls -1 "$SITE_PKGS"/libggml-cuda.so.0 2>/dev/null | head -1)
    CUDA_SIZE=$(du -h "$CUDA_LIB" 2>/dev/null | cut -f1)
    ok "pywhispercpp compilado com CUDA (libggml-cuda.so.0 ${CUDA_SIZE})"
  else
    warn "pywhispercpp instalado mas sem CUDA — STT rodará em CPU"
    suggest "Rodar crew-setup.sh para recompilar com GGML_CUDA=1"
  fi
fi

# ── 6. LD_PRELOAD no systemd (crítico para CUDA) ───────────────────────────────
section "LD_PRELOAD no systemd (crítico para CUDA)"
OVERRIDE_FILE="/etc/systemd/system/kirocrew.service.d/override.conf"
if [ -f "$OVERRIDE_FILE" ]; then
  PRELOAD_LINE=$(grep "LD_PRELOAD" "$OVERRIDE_FILE" 2>/dev/null || true)
  if [ -n "$PRELOAD_LINE" ]; then
    # Extrair o path do LD_PRELOAD
    PRELOAD_PATH=$(echo "$PRELOAD_LINE" | grep -oP 'LD_PRELOAD=\K[^"]+' | tr -d '"')
    if [ -f "$PRELOAD_PATH" ]; then
      ok "LD_PRELOAD configurado: $PRELOAD_PATH"
    else
      warn "LD_PRELOAD configurado mas arquivo não existe: $PRELOAD_PATH"
      suggest "Rodar crew-setup.sh (passo 4/6) para reconfigurar o LD_PRELOAD"
    fi
    if echo "$PRELOAD_PATH" | grep -qE 'crew-venv-[0-9]'; then
      warn "LD_PRELOAD usa caminho com versão — fica velho no próximo update"
      suggest "Rodar crew-setup.sh: grava pelo caminho estável ~/.kiro/crew-venv-current"
    fi
  else
    warn "override.conf existe mas sem LD_PRELOAD"
    suggest "Adicionar LD_PRELOAD=$SITE_PKGS/libggml-cuda.so.0"
  fi
else
  warn "LD_PRELOAD não configurado no systemd — STT pode cair em CPU"
  suggest "Rodar crew-setup.sh (passo 4/6) para configurar o LD_PRELOAD"
fi

LDCONF="/etc/ld.so.conf.d/kirocrew-whisper.conf"
if [ -f "$LDCONF" ] && grep -qE 'crew-venv-[0-9]' "$LDCONF"; then
  warn "$LDCONF usa caminho com versão — fica velho no próximo update"
  suggest "Rodar crew-setup.sh: grava pelo caminho estável ~/.kiro/crew-venv-current"
fi

# Wheel do pywhispercpp guardado (reinstala em segundos após update)
SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ls "$SKILL_ROOT"/.data/wheels/*/pywhispercpp-*.whl &>/dev/null; then
  ok "Wheel do pywhispercpp com CUDA guardado em .data/wheels/"
else
  info "Sem wheel guardado — a próxima execução do crew-setup.sh compila (~10-15 min) e guarda"
fi

# ── 7. Modelos ─────────────────────────────────────────────────────────────────
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

# ── 8. Configurações do gateway ───────────────────────────────────────────────
section "Configurações recomendadas do gateway"

_config_check() {
  local key="$1" expected="$2" desc="$3"
  local actual
  actual=$(kirocrew config get "$key" 2>/dev/null | tr -d '"' | xargs)
  # `config get` não resolve chaves de mapas livres (ex.: agent.role_models.subagent
  # dá "Unknown key"), mas o `set` grava. Fallback: ler direto do config.json.
  if [ -z "$actual" ] && [ -x "$VENV_PYTHON" ]; then
    actual=$("$VENV_PYTHON" -c '
import json, sys
v = json.load(open(sys.argv[1]))
for p in sys.argv[2].split("."):
    v = v.get(p) if isinstance(v, dict) else None
print("" if v is None else v)' "$CREW_HOME/config.json" "$key" 2>/dev/null)
  fi
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
_config_check "agent.model"            "auto"       "Modelo principal automático (id fixo quebra quando sai do catálogo)"
_config_check "agent.fallback_model"   "auto"       "Modelo de fallback automático"
_config_check "agent.role_models.subagent"   "auto" "Modelo dos sub-agentes automático"
_config_check "agent.role_models.background" "auto" "Modelo de tarefas em background automático"
_config_check "agent.reasoning_effort" "max"        "Máxima qualidade de raciocínio"
_config_check "agent.approval_mode"    "auto"       "Auto-aprovação de ferramentas"
_config_check "agent.tool_search"      "True"       "Busca de ferramentas sob demanda"
_config_check "skills.auto_create_from_sessions" "True" "Criação automática de skills"
_config_check "knowledge.auto_add_documents"     "True" "Ingestão automática de documentos"
_config_check "dashboard.theme_color"  "amoled-midnight" "Tema recomendado"
_config_check "dashboard.widget_density" "more"    "Densidade de widgets"

# ── 9. Verificar se STT está em GPU no log ────────────────────────────────────
section "STT no log do gateway"
if systemctl is-active kirocrew.service &>/dev/null; then
  GPU_LINE=$(journalctl -u kirocrew.service -n 100 --no-pager 2>/dev/null | grep -E 'CUDA0.*backend|backend_init_gpu.*CUDA0' | tail -1)
  if [ -n "$GPU_LINE" ]; then
    ok "STT na GPU confirmado no log"
    echo "     $GPU_LINE"
  else
    CPU_LINE=$(journalctl -u kirocrew.service -n 100 --no-pager 2>/dev/null | grep -i "no GPU found" | tail -1)
    if [ -n "$CPU_LINE" ]; then
      warn "STT rodando em CPU — LD_PRELOAD pode estar faltando"
      echo "     $CPU_LINE"
    else
      info "Sem linha de backend_init_gpu no log — pode ser PID antigo ou ainda não transcreveu"
    fi
  fi
else
  warn "kirocrew.service não está rodando"
fi

# ── 10. Resultado final ────────────────────────────────────────────────────────
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
echo "  Depois do restart, auditar logs/modelos/drift:"
echo "  python3 ~/.kiro/skills/crew-setup/tools/crew-audit.py"
echo "════════════════════════════════════════════════"
echo ""
