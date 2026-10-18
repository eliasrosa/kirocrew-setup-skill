#!/usr/bin/env bash
# crew-setup.sh — parte da skill crew-setup
# Configura/restaura o Kiro Crew após um update ou instalação nova.
# Reinstala pacotes extras, recompila pywhispercpp com CUDA, aplica
# configurações de STT/TTS e adota defaults atualizados do Crew.
#
# Uso: bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PIP="$HOME/.kiro/crew-venv/bin/pip"
REQS="$SCRIPT_DIR/extras.txt"
LDCONF="/etc/ld.so.conf.d/kirocrew-whisper.conf"
SITE_PKGS="$HOME/.kiro/crew-venv/lib/python3.12/site-packages"
KIROCREW="kirocrew"

# Diretório base do Kiro Crew — respeita KIROCREW_HOME quando definida
CREW_HOME="${KIROCREW_HOME:-$HOME/.kiro/crew}"

# ── helpers ──────────────────────────────────────────────────────────────────
ok()   { echo "  ✅  $*"; }
fail() { echo "  ❌  $*"; FAILED+=("$*"); }
info() { echo "  ℹ️   $*"; }

FAILED=()

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║     Kiro Crew — restore pós-update           ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── 1. Pacotes extras (sem pywhispercpp) ─────────────────────────────────────
echo "▸ [1/5] Pacotes extras (boto3, amazon-transcribe, edge-tts, httpx)..."
if grep -v pywhispercpp "$REQS" | grep -v '^#' | grep -v '^$' \
     | xargs "$VENV_PIP" install --quiet 2>&1; then
  ok "Pacotes extras instalados"
else
  fail "Erro ao instalar pacotes extras"
fi

# ── 2. pywhispercpp com CUDA ──────────────────────────────────────────────────
echo "▸ [2/5] Compilando pywhispercpp com CUDA (~10-15 min)..."
if GGML_CUDA=1 "$VENV_PIP" install --force-reinstall \
     git+https://github.com/absadiki/pywhispercpp 2>&1 | tail -3; then
  ok "pywhispercpp compilado com CUDA"
else
  fail "Erro na compilação do pywhispercpp com CUDA"
fi

# ── 3. ldconfig para libs CUDA do whisper ────────────────────────────────────
echo "▸ [3/5] Configurando ldconfig..."
if [ ! -f "$LDCONF" ]; then
  echo "$SITE_PKGS" | sudo tee "$LDCONF" > /dev/null
  info "Criado $LDCONF"
else
  info "$LDCONF já existe"
fi

if sudo ldconfig 2>&1 | grep -v "não é um link simbólico" | grep -q "error"; then
  fail "ldconfig retornou erro"
else
  ok "ldconfig executado"
fi

sleep 1  # aguarda ldconfig propagar antes de verificar

if ldconfig -p | grep -q "libwhisper"; then
  ok "libwhisper registrada: $(ldconfig -p | grep libwhisper | awk '{print $NF}')"
else
  fail "libwhisper não encontrada após ldconfig"
fi

# ── 4. Configurações do gateway (STT + TTS) ───────────────────────────────────
echo "▸ [4/5] Configurações do gateway..."

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

# ── 5. Config defaults (adota novos defaults sem sobrescrever customizações) ──
echo "▸ [5/6] Adotando config defaults do Kiro Crew..."
# --adopt só muda valores que ainda estão no default antigo.
# Configurações que você alterou manualmente NÃO são tocadas.
if $KIROCREW config defaults --adopt 2>&1 | grep -v "WARNING\|deprecated" | grep -v "^$" | head -5; then
  ok "Config defaults adotados"
else
  fail "Erro ao adotar config defaults"
fi

# ── 6. Restart + verificação ──────────────────────────────────────────────────
echo "▸ [6/6] Reiniciando Kiro Crew e verificando STT na GPU..."
sudo systemctl restart kirocrew.service
sleep 5

GPU_LINE=$(journalctl -u kirocrew.service -n 50 --no-pager 2>/dev/null \
  | grep -E 'CUDA0|backend_init_gpu' | tail -4)

if echo "$GPU_LINE" | grep -q "using CUDA0 backend"; then
  ok "STT rodando na GPU CUDA0"
  echo "$GPU_LINE" | sed 's/^/     /'
else
  fail "STT na GPU não confirmado — verifique manualmente"
  info "journalctl -u kirocrew.service -n 50 --no-pager | grep -E 'CUDA0|backend_init_gpu'"
fi

# ── Resultado final ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "  ✅ ✅  Tudo OK — Kiro Crew restaurado com sucesso!"
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
