#!/usr/bin/env bash
# crew-setup.sh — parte da skill crew-setup
# Configura/restaura o Kiro Crew após um update ou instalação nova.
# Reinstala pacotes extras, recompila pywhispercpp com CUDA, configura
# LD_PRELOAD no systemd, aplica configurações de STT/TTS e reinicia.
#
# Uso: bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detectar venv ativo via symlink (padrão pós-0.10.0)
if [ -L "$HOME/.kiro/crew-venv-current" ]; then
  CREW_VENV=$(readlink -f "$HOME/.kiro/crew-venv-current")
else
  # Fallback para venv legado (pré-0.10.0)
  CREW_VENV="$HOME/.kiro/crew-venv"
fi

VENV_PIP="$CREW_VENV/bin/pip"
VENV_PYTHON="$CREW_VENV/bin/python3"
REQS="$SCRIPT_DIR/extras.txt"
LDCONF="/etc/ld.so.conf.d/kirocrew-whisper.conf"
OVERRIDE_FILE="/etc/systemd/system/kirocrew.service.d/override.conf"
KIROCREW="kirocrew"

# Diretório base do Kiro Crew — respeita KIROCREW_HOME quando definida
CREW_HOME="${KIROCREW_HOME:-$HOME/.kiro/crew}"

# Descobrir site-packages dinamicamente
if [ -x "$VENV_PYTHON" ]; then
  SITE_PKGS=$("$VENV_PYTHON" -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null)
else
  echo "❌ Python do venv não encontrado: $VENV_PYTHON"
  exit 1
fi

# ── helpers ──────────────────────────────────────────────────────────────────
ok()   { echo "  ✅  $*"; }
fail() { echo "  ❌  $*"; FAILED+=("$*"); }
info() { echo "  ℹ️   $*"; }
warn() { echo "  ⚠️   $*"; }

FAILED=()

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║     Kiro Crew — restore pós-update           ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
info "Venv ativo: $CREW_VENV"
info "Site-packages: $SITE_PKGS"
echo ""

# ── 1. Pacotes extras (sem pywhispercpp) ─────────────────────────────────────
echo "▸ [1/6] Pacotes extras (boto3, amazon-transcribe, edge-tts, httpx)..."
if grep -v pywhispercpp "$REQS" | grep -v '^#' | grep -v '^$' \
     | xargs "$VENV_PIP" install --quiet 2>&1; then
  ok "Pacotes extras instalados"
else
  fail "Erro ao instalar pacotes extras"
fi

# ── 2. pywhispercpp com CUDA ──────────────────────────────────────────────────
echo "▸ [2/6] Compilando pywhispercpp com CUDA (~10-15 min)..."
if GGML_CUDA=1 "$VENV_PIP" install --force-reinstall \
     git+https://github.com/absadiki/pywhispercpp 2>&1 | tail -3; then
  ok "pywhispercpp compilado com CUDA"
else
  fail "Erro na compilação do pywhispercpp com CUDA"
fi

# Verificar se libggml-cuda foi gerada
if ls "$SITE_PKGS"/libggml-cuda.so.0 &>/dev/null 2>&1; then
  CUDA_SIZE=$(du -h "$SITE_PKGS/libggml-cuda.so.0" | cut -f1)
  ok "libggml-cuda.so.0 gerada ($CUDA_SIZE)"
else
  fail "libggml-cuda.so.0 não encontrada — build pode ter falhado"
fi

# ── 3. ldconfig para libs CUDA do whisper ────────────────────────────────────
echo "▸ [3/6] Configurando ldconfig..."
if [ ! -f "$LDCONF" ] || ! grep -q "$SITE_PKGS" "$LDCONF" 2>/dev/null; then
  echo "$SITE_PKGS" | sudo tee "$LDCONF" > /dev/null
  info "Criado/atualizado $LDCONF"
else
  info "$LDCONF já aponta para $SITE_PKGS"
fi

if sudo ldconfig 2>&1 | grep -v "não é um link simbólico" | grep -q "error"; then
  fail "ldconfig retornou erro"
else
  ok "ldconfig executado"
fi

sleep 1  # aguarda ldconfig propagar antes de verificar

if ldconfig -p | grep -q "libwhisper"; then
  ok "libwhisper registrada: $(ldconfig -p | grep libwhisper | head -1 | awk '{print $NF}')"
else
  warn "libwhisper não encontrada após ldconfig — pode ser warning inofensivo"
fi

# ── 4. LD_PRELOAD no systemd (crítico para CUDA) ─────────────────────────────
echo "▸ [4/6] Configurando LD_PRELOAD no systemd..."
CUDA_LIB="$SITE_PKGS/libggml-cuda.so.0"

if [ ! -f "$CUDA_LIB" ]; then
  fail "libggml-cuda.so.0 não encontrada — não é possível configurar LD_PRELOAD"
else
  sudo mkdir -p /etc/systemd/system/kirocrew.service.d

  # Verificar se já está configurado corretamente
  CURRENT_PRELOAD=""
  if [ -f "$OVERRIDE_FILE" ]; then
    CURRENT_PRELOAD=$(grep -oP 'LD_PRELOAD=\K[^"]+' "$OVERRIDE_FILE" 2>/dev/null | tr -d '"' || true)
  fi

  if [ "$CURRENT_PRELOAD" = "$CUDA_LIB" ]; then
    ok "LD_PRELOAD já configurado corretamente"
  else
    sudo tee "$OVERRIDE_FILE" > /dev/null << EOF
[Service]
Environment="LD_PRELOAD=$CUDA_LIB"
EOF
    ok "LD_PRELOAD configurado: $CUDA_LIB"
    sudo systemctl daemon-reload
    ok "systemctl daemon-reload executado"
  fi
fi

# ── 5. Configurações do gateway (STT + TTS) ───────────────────────────────────
echo "▸ [5/6] Configurações do gateway..."

# STT
if $KIROCREW config set stt.provider local 2>/dev/null && \
   $KIROCREW config set stt.model large-v3-turbo 2>/dev/null && \
   $KIROCREW config set stt.language_code pt-BR 2>/dev/null && \
   $KIROCREW config set stt.streaming true 2>/dev/null; then
  ok "STT: provider=local, model=large-v3-turbo, language=pt-BR"
else
  fail "Erro ao configurar STT"
fi

# TTS: desligar envio automático no Telegram, manter piper apontando pro modelo
if $KIROCREW config set voice_reply.enabled false 2>/dev/null && \
   $KIROCREW config set voice_reply.provider piper 2>/dev/null && \
   $KIROCREW config set voice_reply.piper_model \
     "$CREW_HOME/models/piper/pt_BR-faber-medium.onnx" 2>/dev/null; then
  ok "TTS: voice_reply desativado no Telegram, piper_model configurado"
else
  fail "Erro ao configurar TTS"
fi

# ── 6. Restart + verificação ──────────────────────────────────────────────────
echo "▸ [6/6] Reiniciando Kiro Crew e verificando STT na GPU..."
sudo systemctl restart kirocrew.service
info "Aguardando gateway subir..."
sleep 8

# Pegar o PID atual
CURRENT_PID=$(systemctl show kirocrew.service --property=MainPID --value 2>/dev/null || echo "")
info "PID do gateway: $CURRENT_PID"

# Verificar no log (só linhas do PID atual)
GPU_LINE=$(journalctl -u kirocrew.service -n 100 --no-pager 2>/dev/null \
  | grep -E 'CUDA0.*backend|backend_init_gpu.*CUDA0|using CUDA0' | tail -3)

if echo "$GPU_LINE" | grep -q "using CUDA0 backend"; then
  ok "STT rodando na GPU CUDA0"
  echo "$GPU_LINE" | sed 's/^/     /'
else
  # Pode ser que ainda não tenha transcrito nada — verificar se não há "no GPU found"
  NO_GPU=$(journalctl -u kirocrew.service -n 100 --no-pager 2>/dev/null | grep -i "no GPU found" | tail -1)
  if [ -n "$NO_GPU" ]; then
    fail "STT na CPU — 'no GPU found' no log"
    echo "     $NO_GPU"
    info "Pode ser log de PID antigo. Mande um áudio de teste e rode:"
    info "journalctl -u kirocrew.service -n 50 | grep -i backend_init_gpu"
  else
    warn "STT na GPU não confirmado ainda — pode ser PID antigo ou não transcreveu"
    info "Mande um áudio de teste no Telegram e rode:"
    info "journalctl -u kirocrew.service -n 50 | grep -i backend_init_gpu"
  fi
fi

# ── Resultado final ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "  ✅ ✅  Tudo OK — Kiro Crew restaurado com sucesso!"
  echo ""
  echo "  Verificação manual:"
  echo "  journalctl -u kirocrew.service -n 50 | grep -iE 'cuda|backend_init'"
else
  echo "  ⚠️   Concluído com ${#FAILED[@]} erro(s):"
  for f in "${FAILED[@]}"; do
    echo "    • $f"
  done
  echo ""
  echo "  Consulte a skill crew-setup para mais detalhes:"
  echo "  ~/.kiro/skills/crew-setup/SKILL.md"
fi
echo "════════════════════════════════════════════════"
echo ""
