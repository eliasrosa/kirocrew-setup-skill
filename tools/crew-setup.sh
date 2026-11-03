#!/usr/bin/env bash
# crew-setup.sh — parte da skill crew-setup
# Configura/restaura o Kiro Crew após um update ou numa máquina nova, conforme o
# perfil da máquina (.data/profile.env): STT na GPU, na CPU, na nuvem ou desligado,
# voz do TTS nativo e skills vinculadas. Na primeira execução detecta o ambiente,
# pergunta o perfil e guarda a resposta; nos updates seguintes reusa sem perguntar.
#
# Uso: bash ~/.kiro/skills/crew-setup/tools/crew-setup.sh [opções]
#   --reconfigure  pergunta o perfil de novo
#   --yes          não pergunta nada: usa o perfil salvo ou o detectado
#   --plan         mostra ambiente, perfil e passos, sem alterar nada
#   --rebuild      recompila o pywhispercpp com CUDA (ignora o wheel guardado)
#   --ld-preload   plano B: força o LD_PRELOAD da libggml-cuda no systemd

set -euo pipefail

# Não rodar via sudo: o script pede a senha só nos passos que mexem no sistema.
# Como root, o pip e o `kirocrew config set` gravariam com dono root e no HOME errado.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  echo "❌ Não rode com sudo. O script pede a senha sozinho quando precisa:"
  echo "   bash $0"
  exit 1
fi

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

RECONFIGURE=0; ASSUME_YES=0; PLAN=0; REBUILD=0; FORCE_PRELOAD=0
for arg in "$@"; do
  case "$arg" in
    --reconfigure) RECONFIGURE=1 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --plan)        PLAN=1 ;;
    --rebuild)     REBUILD=1 ;;
    --ld-preload)  FORCE_PRELOAD=1 ;;
    -h|--help)     sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opção desconhecida: $arg (veja --help)"; exit 1 ;;
  esac
done

KIROCREW="kirocrew"
WHEELS_ROOT="$DATA_DIR/wheels"
PYWHISPER_SRC="git+https://github.com/absadiki/pywhispercpp"
PYWHISPER_PYPI="pywhispercpp>=1.5,<2"
TRANSCRIBE_REQS="$TOOLS_DIR/requirements-transcribe.txt"

ok()   { echo "  ✅  $*"; }
fail() { echo "  ❌  $*"; FAILED+=("$*"); }
info() { echo "  ℹ️   $*"; }
warn() { echo "  ⚠️   $*"; PENDING+=("$*"); }
plan() { echo "  📝  faria: $*"; }
FAILED=()
PENDING=()

if [ ! -x "$VENV_PY" ]; then
  echo "❌ Python do venv do Kiro Crew não encontrado: $VENV_PY"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║     Kiro Crew — setup / restore pós-update   ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
info "Venv ativo: $CREW_VENV"
info "Ambiente: $(describe_env)"

# ── Perfil ────────────────────────────────────────────────────────────────────
profile_load
if [ "$PROFILE_SAVED" -eq 0 ] || [ "$RECONFIGURE" -eq 1 ]; then
  profile_defaults
  if [ -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    profile_ask
  else
    info "Sem terminal interativo (ou --yes): usando o perfil detectado"
  fi
  if [ "$PLAN" -eq 0 ]; then
    profile_save
    info "Perfil salvo em $PROFILE_FILE"
  fi
else
  profile_defaults
  info "Perfil salvo em $PROFILE_FILE (mude com --reconfigure)"
fi
echo ""
echo "▸ Perfil"
profile_show
echo ""

# ── Validação do perfil contra o ambiente ─────────────────────────────────────
PY_TAG="$("$VENV_PY" -c 'import sys; print(f"cp{sys.version_info[0]}{sys.version_info[1]}")')"
CUDA_TAG="$(detect_cuda_toolkit)"
WHEEL_DIR="$WHEELS_ROOT/$PY_TAG-cuda${CUDA_TAG:-none}"
CACHED_WHEEL="$(ls -1t "$WHEEL_DIR"/pywhispercpp-*.whl 2>/dev/null | head -1 || true)"
if [ "$REBUILD" -eq 1 ]; then CACHED_WHEEL=""; fi

if [ "$STT" = gpu ]; then
  BLOCK=()
  if [ "$(detect_gpu)" != nvidia ]; then
    BLOCK+=("perfil STT=gpu, mas não há GPU NVIDIA ativa (nvidia-smi)")
  fi
  if [ -z "$CUDA_TAG" ]; then
    BLOCK+=("falta o CUDA toolkit (nvcc): sudo apt install nvidia-cuda-toolkit")
  fi
  if [ -z "$CACHED_WHEEL" ]; then
    for c in cmake gcc g++ make git; do
      if ! command -v "$c" >/dev/null 2>&1; then
        BLOCK+=("falta $c para compilar: sudo apt install build-essential cmake git")
        break
      fi
    done
  fi
  if [ ${#BLOCK[@]} -gt 0 ]; then
    for b in "${BLOCK[@]}"; do echo "  ❌  $b"; done
    echo ""
    echo "  Corrija e rode de novo, ou troque o perfil (STT=cpu, transcribe ou off):"
    echo "  bash $0 --reconfigure"
    exit 1
  fi
fi
if [ "$STT" = gpu ] || [ "$STT" = cpu ]; then
  if ! command -v ffmpeg >/dev/null 2>&1; then
    warn "ffmpeg ausente: o Crew precisa dele para decodificar o áudio (sudo apt install ffmpeg)"
  fi
fi
if [ -n "$TTS_VOICE" ] && ! command -v espeak-ng >/dev/null 2>&1; then
  warn "espeak-ng ausente: o TTS nativo (provider system) não fala sem ele (sudo apt install espeak-ng)"
fi

# ── 1. Pacotes extras do venv ─────────────────────────────────────────────────
step_extras() {
  echo "▸ [1/7] Pacotes extras do venv..."
  local files=() f pkgs
  if [ "$STT" = transcribe ]; then files+=("$TRANSCRIBE_REQS"); fi
  if [ -s "$USER_EXTRAS" ]; then files+=("$USER_EXTRAS"); fi
  if [ ${#files[@]} -eq 0 ]; then
    info "Nada a instalar neste perfil"
    return 0
  fi
  for f in "${files[@]}"; do
    pkgs="$(grep -vE '^[[:space:]]*(#|$)' "$f" | tr '\n' ' ')"
    if [ "$PLAN" -eq 1 ]; then plan "pip install $pkgs"; continue; fi
    if "$VENV_PIP" install --quiet -r "$f" 2>&1 | tail -3; then
      ok "Instalado ($(basename "$f")): $pkgs"
    else
      fail "Erro ao instalar $(basename "$f")"
    fi
  done
}

# ── 2. STT local (pywhispercpp) ───────────────────────────────────────────────
step_stt_gpu() {
  # O wheel compilado fica em .data/wheels/<python>-cuda<versão>/. Nos updates
  # seguintes reinstala dele em segundos; recompila se mudar Python/CUDA ou com --rebuild.
  if [ -n "$CACHED_WHEEL" ]; then
    echo "▸ [2/7] pywhispercpp com CUDA a partir do wheel guardado..."
    info "Wheel: $CACHED_WHEEL"
  else
    echo "▸ [2/7] Compilando pywhispercpp com CUDA (~10-15 min)..."
    if [ "$PLAN" -eq 1 ]; then plan "compilar $PYWHISPER_SRC com GGML_CUDA=1 e guardar em $WHEEL_DIR"; return 0; fi
    mkdir -p "$WHEEL_DIR"
    if GGML_CUDA=1 "$VENV_PIP" wheel --no-deps -w "$WHEEL_DIR" "$PYWHISPER_SRC" 2>&1 | tail -3; then
      CACHED_WHEEL="$(ls -1t "$WHEEL_DIR"/pywhispercpp-*.whl 2>/dev/null | head -1 || true)"
    fi
    if [ -n "$CACHED_WHEEL" ]; then ok "Wheel compilado e guardado: $CACHED_WHEEL"; fi
  fi
  if [ "$PLAN" -eq 1 ]; then plan "pip install --force-reinstall $CACHED_WHEEL"; return 0; fi
  if [ -n "$CACHED_WHEEL" ] && "$VENV_PIP" install --quiet --force-reinstall "$CACHED_WHEEL" 2>&1 | tail -3; then
    ok "pywhispercpp com CUDA instalado"
  else
    fail "Erro ao compilar/instalar o pywhispercpp com CUDA (rode de novo com --rebuild)"
    return 0
  fi
  if [ -f "$SITE_PKGS/libggml-cuda.so.0" ]; then
    ok "libggml-cuda.so.0 presente ($(du -h "$SITE_PKGS/libggml-cuda.so.0" | cut -f1))"
  else
    fail "libggml-cuda.so.0 não encontrada — o build saiu sem CUDA"
  fi
}

step_stt_cpu() {
  echo "▸ [2/7] pywhispercpp para CPU (PyPI)..."
  local force=()
  # Se o venv tem o build CUDA, troca pelo de CPU.
  if [ -f "$SITE_PKGS/libggml-cuda.so.0" ]; then force=(--force-reinstall); fi
  if [ "$PLAN" -eq 1 ]; then plan "pip install ${force[*]} $PYWHISPER_PYPI"; return 0; fi
  if "$VENV_PIP" install --quiet "${force[@]}" "$PYWHISPER_PYPI" 2>&1 | tail -3; then
    ok "pywhispercpp (CPU) instalado"
  else
    fail "Erro ao instalar o pywhispercpp (CPU)"
  fi
}

step_stt() {
  case "$STT" in
    gpu) step_stt_gpu ;;
    cpu) step_stt_cpu ;;
    *)   echo "▸ [2/7] STT local: não se aplica (STT=$STT)" ;;
  esac
}

# ── 3. ldconfig para as libs do whisper (só GPU) ─────────────────────────────
step_ldconfig() {
  echo "▸ [3/7] ldconfig para as libs do whisper..."
  if [ "$STT" != gpu ]; then info "Não se aplica (STT=$STT)"; return 0; fi
  # A libggml.so procura a libggml-cuda num diretório temporário do build, que some.
  # O cache do ldconfig é quem acha a lib, pelo caminho estável (não fica velho no update).
  if [ "$(cat "$LDCONF" 2>/dev/null)" = "$STABLE_SITE" ]; then
    ok "$LDCONF já aponta para $STABLE_SITE"
  elif [ "$PLAN" -eq 1 ]; then
    plan "gravar $STABLE_SITE em $LDCONF (sudo) e rodar ldconfig"
    return 0
  else
    echo "$STABLE_SITE" | sudo tee "$LDCONF" > /dev/null
    ok "Criado/atualizado $LDCONF → $STABLE_SITE"
  fi
  if [ "$PLAN" -eq 1 ]; then return 0; fi
  if sudo ldconfig 2>&1 | grep -v "não é um link simbólico\|is not a symbolic link" | grep -qi "error"; then
    fail "ldconfig retornou erro"
  else
    ok "ldconfig executado"
  fi
  sleep 1  # aguarda o cache propagar antes de verificar
  if ldconfig -p | grep -q "libggml-cuda"; then
    ok "libggml-cuda registrada no cache do ldconfig"
  else
    fail "libggml-cuda não apareceu no cache do ldconfig"
  fi
}

# ── 4. LD_PRELOAD no systemd ──────────────────────────────────────────────────
step_ld_preload() {
  echo "▸ [4/7] LD_PRELOAD no systemd..."
  local has=0
  if [ -f "$OVERRIDE_FILE" ] && grep -q 'LD_PRELOAD=.*libggml-cuda' "$OVERRIDE_FILE"; then has=1; fi

  if [ "$FORCE_PRELOAD" -eq 1 ]; then
    # Plano B (--ld-preload): só se o STT cair para CPU mesmo com o ldconfig certo.
    local lib="$STABLE_SITE/libggml-cuda.so.0"
    if [ "$PLAN" -eq 1 ]; then plan "gravar LD_PRELOAD=$lib em $OVERRIDE_FILE (sudo)"; return 0; fi
    sudo mkdir -p "$(dirname "$OVERRIDE_FILE")"
    printf '[Service]\nEnvironment="LD_PRELOAD=%s"\n' "$lib" | sudo tee "$OVERRIDE_FILE" > /dev/null
    sudo systemctl daemon-reload
    warn "LD_PRELOAD gravado (plano B): todo processo filho do gateway passa a carregar a lib CUDA"
    return 0
  fi

  if [ "$has" -eq 0 ]; then ok "Sem LD_PRELOAD (não é necessário)"; return 0; fi
  info "LD_PRELOAD legado encontrado: o ldconfig já resolve a lib, e o preload pesava"
  info "em todo processo filho do gateway (bash, git, node: ~56 ms e ~50 MB cada)."
  if [ "$PLAN" -eq 1 ]; then plan "remover a linha LD_PRELOAD de $OVERRIDE_FILE (sudo)"; return 0; fi
  sudo sed -i '/LD_PRELOAD=.*libggml-cuda/d' "$OVERRIDE_FILE"
  if ! grep -qvE '^[[:space:]]*(\[Service\])?[[:space:]]*$' "$OVERRIDE_FILE"; then
    sudo rm -f "$OVERRIDE_FILE"
    info "override.conf ficou vazio e foi removido"
  fi
  sudo systemctl daemon-reload
  ok "LD_PRELOAD removido"
}

# ── 5. Configurações do gateway ───────────────────────────────────────────────
step_config() {
  echo "▸ [5/7] Configurações do gateway..."
  local sets=() kv key val prov
  case "$STT" in
    gpu|cpu)    sets+=("stt.enabled true" "stt.provider local" "stt.model $STT_MODEL" "stt.language_code $STT_LANGUAGE") ;;
    transcribe) sets+=("stt.enabled true" "stt.provider transcribe" "stt.language_code $STT_LANGUAGE") ;;
    off)        sets+=("stt.enabled false") ;;
  esac
  # TTS nativo: o Crew 0.11 removeu o provider piper. "system" usa o motor do SO
  # (espeak-ng no Linux). Quem escolheu polly (pago) continua com polly.
  prov="$($KIROCREW config get voice_reply.provider 2>/dev/null | tr -d '"' | xargs || true)"
  case "$prov" in piper|"") sets+=("voice_reply.provider system") ;; esac
  if [ -n "$TTS_VOICE" ]; then sets+=("voice_reply.system_voice $TTS_VOICE"); fi
  # Modelos em 'auto': id fixo quebra quando o update tira o modelo do catálogo.
  sets+=("agent.model auto" "agent.fallback_model auto" "agent.role_models.subagent auto" "agent.role_models.background auto")

  for kv in "${sets[@]}"; do
    key="${kv%% *}"; val="${kv#* }"
    if [ "$PLAN" -eq 1 ]; then plan "$key = $val"; continue; fi
    if $KIROCREW config set "$key" "$val" > /dev/null 2>&1; then
      ok "$key = $val"
    else
      fail "kirocrew config set $key $val"
    fi
  done
  if [ "$STT" = transcribe ]; then
    info "Transcribe usa o perfil/região AWS de stt.transcribe_profile e stt.transcribe_region (Settings)"
  fi
}

# ── 6. Skills vinculadas ──────────────────────────────────────────────────────
step_skills() {
  echo "▸ [6/7] Skills vinculadas..."
  if [ -z "$SKILLS" ]; then info "Nenhuma no perfil"; return 0; fi
  local s d url out
  out="$(mktemp)"
  for s in $SKILLS; do
    d="$(skill_dir "$s" || true)"
    if [ -z "$d" ]; then
      url="$(linked_skill_url "$s")"
      if [ "$PLAN" -eq 1 ]; then plan "$s: git clone $url ~/.kiro/skills/$s"; continue; fi
      if git clone --quiet "$url" "$HOME/.kiro/skills/$s"; then
        d="$HOME/.kiro/skills/$s"
        ok "$s: clonada em $d"
      else
        fail "$s: git clone $url falhou"
        continue
      fi
    elif [ ! -d "$d/.git" ]; then
      warn "$s em $d é cópia sem git (não atualiza): reinstale com git clone $(linked_skill_url "$s") ~/.kiro/skills/$s"
    fi
    if [ -f "$d/tools/install.py" ]; then
      if [ "$PLAN" -eq 1 ]; then
        python3 "$d/tools/install.py" --dry-run 2>&1 | sed "s/^/     [$s] /" || true
      elif python3 "$d/tools/install.py" 2>&1 | sed "s/^/     [$s] /"; then
        ok "$s: install.py concluído"
      else
        fail "$s: install.py falhou (rode: python3 $d/tools/install.py)"
      fi
    fi
    if [ -f "$d/tools/check.py" ] && [ "$PLAN" -eq 0 ]; then
      if python3 "$d/tools/check.py" > "$out" 2>&1; then
        ok "$s: check.py ok"
      else
        warn "$s: check.py tem pendências (rode: python3 $d/tools/check.py)"
        grep -E '✗|→' "$out" | sed 's/^/       /' || true
      fi
    fi
  done
  rm -f "$out"
}

# ── 7. Restart + verificação ──────────────────────────────────────────────────
step_restart() {
  echo "▸ [7/7] Reiniciando o Kiro Crew..."
  if [ "$PLAN" -eq 1 ]; then plan "sudo systemctl restart $SERVICE e conferir o STT no log"; return 0; fi
  sudo systemctl restart "$SERVICE"
  info "Aguardando o gateway subir..."
  sleep 5
  info "PID do gateway: $(systemctl show "$SERVICE" --property=MainPID --value 2>/dev/null || echo '?')"
  if [ "$STT" != gpu ]; then
    info "Mande um áudio de teste no Telegram para validar a transcrição"
    return 0
  fi
  # Só linhas deste start (linhas antigas de CUDA0 dariam falso positivo).
  # O whisper costuma carregar ~15 s após o start; espera até 45 s.
  local since gpu_line="" i
  since="$(systemctl show "$SERVICE" --property=ActiveEnterTimestamp --value 2>/dev/null || true)"
  for i in $(seq 1 15); do
    gpu_line="$(journalctl -u "$SERVICE" --since "${since:-5 min ago}" --no-pager 2>/dev/null \
      | grep -E 'using CUDA0 backend|no GPU found' | tail -1 || true)"
    [ -n "$gpu_line" ] && break
    sleep 3
  done
  if echo "$gpu_line" | grep -q "using CUDA0 backend"; then
    ok "STT rodando na GPU (CUDA0)"
  elif echo "$gpu_line" | grep -q "no GPU found"; then
    fail "STT caiu para CPU ('no GPU found'). Plano B: bash $0 --ld-preload"
  else
    warn "GPU ainda não confirmada: o whisper carrega no 1º áudio. Mande um áudio e rode:"
    info "journalctl -u $SERVICE -n 50 | grep -iE 'CUDA0|no GPU'"
  fi
}

step_extras
step_stt
step_ldconfig
step_ld_preload
step_config
step_skills
step_restart

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
if [ "$PLAN" -eq 1 ]; then
  echo "  📝  Plano mostrado acima. Nada foi alterado."
elif [ ${#FAILED[@]} -eq 0 ] && [ ${#PENDING[@]} -eq 0 ]; then
  echo "  ✅ ✅  Tudo OK — Kiro Crew configurado para este perfil."
else
  if [ ${#FAILED[@]} -gt 0 ]; then
    echo "  ❌  ${#FAILED[@]} erro(s):"
    for f in "${FAILED[@]}"; do echo "    • $f"; done
  fi
  if [ ${#PENDING[@]} -gt 0 ]; then
    echo "  ⚠️   ${#PENDING[@]} pendência(s):"
    for p in "${PENDING[@]}"; do echo "    • $p"; done
  fi
fi
echo ""
echo "  Auditoria pós-update: python3 $TOOLS_DIR/crew-audit.py"
echo "════════════════════════════════════════════════"
echo ""
if [ ${#FAILED[@]} -gt 0 ]; then exit 1; fi
