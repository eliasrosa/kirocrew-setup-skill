#!/usr/bin/env bash
# crew-check.sh — parte da skill crew-setup
# Diagnóstico do ambiente do Kiro Crew conforme o perfil da máquina
# (.data/profile.env, criado pelo crew-setup.sh). Sem perfil salvo, usa o detectado.
# Só lê: não altera nada.
#
# Uso: bash ~/.kiro/skills/crew-setup/tools/crew-check.sh

# Não rodar via sudo: o diagnóstico só lê, e como root o HOME vira /root.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  echo "❌ Não rode com sudo. O diagnóstico só lê; rode como o seu usuário:"
  echo "   bash $0"
  exit 1
fi

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
KIROCREW="kirocrew"

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

# ── Perfil ────────────────────────────────────────────────────────────────────
profile_load
profile_defaults
section "Perfil"
if [ "$PROFILE_SAVED" -eq 1 ]; then
  info "Salvo em $PROFILE_FILE"
else
  warn "Perfil ainda não salvo: usando o detectado"
  suggest "Rodar crew-setup.sh: ele pergunta o perfil e guarda a resposta"
fi
profile_show

# ── 1. Sistema operacional ────────────────────────────────────────────────────
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

# ── 2. GPU ────────────────────────────────────────────────────────────────────
section "GPU"
GPU="$(detect_gpu)"
CUDA_VER="$(detect_cuda_toolkit)"
case "$GPU" in
  nvidia) ok "NVIDIA: $(detect_gpu_name)" ;;
  amd)    info "GPU AMD/ROCm: o build automático cobre só CUDA (perfil gpu indisponível)" ;;
  *)      info "Sem GPU dedicada: STT local roda na CPU" ;;
esac
if [ -n "$CUDA_VER" ]; then ok "CUDA toolkit: $CUDA_VER"; fi
if [ "$STT" = gpu ]; then
  [ "$GPU" = nvidia ] || fail "Perfil STT=gpu, mas não há GPU NVIDIA ativa"
  if [ -z "$CUDA_VER" ]; then
    fail "Perfil STT=gpu, mas falta o CUDA toolkit (nvcc) para compilar"
    suggest "sudo apt install nvidia-cuda-toolkit  (ou troque o perfil: crew-setup.sh --reconfigure)"
  fi
elif [ "$GPU" = nvidia ] && [ -n "$CUDA_VER" ] && { [ "$STT" = cpu ] || [ "$STT" = off ]; }; then
  info "Há GPU com CUDA, mas o perfil usa STT=$STT (para usar a GPU: crew-setup.sh --reconfigure)"
fi

# ── 3. Dependências do sistema ────────────────────────────────────────────────
section "Dependências do sistema"
DEPS=(git)
case "$STT" in gpu|cpu) DEPS+=(ffmpeg) ;; esac
# Compilador só faz falta na primeira compilação: com wheel guardado, não precisa.
if [ "$STT" = gpu ] && ! ls "$DATA_DIR"/wheels/*/pywhispercpp-*.whl &>/dev/null; then
  DEPS+=(cmake gcc g++ make)
fi
[ -n "$TTS_VOICE" ] && DEPS+=(espeak-ng)
for cmd in "${DEPS[@]}"; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd"
  else
    fail "$cmd não encontrado"
    case "$cmd" in
      cmake|gcc|g++|make) suggest "sudo apt install build-essential cmake" ;;
      *)                  suggest "sudo apt install $cmd" ;;
    esac
  fi
done
command -v systemctl &>/dev/null || warn "systemctl não disponível — o Crew pode não estar rodando via systemd."
if [ "$STT" = gpu ] && ! command -v ldconfig &>/dev/null; then
  warn "ldconfig não encontrado — as libs CUDA do whisper não serão registradas."
fi

# ── 4. CLIs recomendados ──────────────────────────────────────────────────────
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
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd — ${CLI_DESC[$cmd]}"
  else
    suggest "Instalar $cmd (${CLI_DESC[$cmd]})"
  fi
done

# ── 5. Python e venv do Crew ──────────────────────────────────────────────────
section "Python e venv do Crew"
if [ -L "${CREW_HOME}-venv-current" ]; then
  ok "Venv ativo: $CREW_VENV (via link estável $STABLE_VENV)"
else
  warn "Link ${CREW_HOME}-venv-current não existe — usando o venv legado $CREW_VENV"
fi
if [ -x "$VENV_PY" ]; then
  ok "Python: $("$VENV_PY" --version 2>&1)"
else
  fail "venv do Crew não encontrado — Kiro Crew instalado?"
fi
if command -v "$KIROCREW" &>/dev/null; then
  CREW_VERSION=$(find "$SITE_PKGS" -maxdepth 1 -name 'kirocrew-*.dist-info' -exec grep "^Version:" {}/METADATA \; 2>/dev/null | head -1 | awk '{print $2}')
  ok "kirocrew CLI — versão ${CREW_VERSION:-desconhecida}"
else
  fail "kirocrew CLI não encontrado no PATH"
fi

# ── 6. Pacotes do venv (conforme o perfil) ────────────────────────────────────
section "Pacotes do venv"
_pkg_check() {  # nome descrição
  if "$VENV_PIP" show "$1" &>/dev/null; then
    ok "$1 $("$VENV_PIP" show "$1" 2>/dev/null | awk '/^Version:/{print $2}') — $2"
  else
    fail "$1 não instalado — $2"
    suggest "Rodar crew-setup.sh (passos 1-2)"
  fi
}
case "$STT" in
  gpu|cpu)
    _pkg_check pywhispercpp "motor do STT local (whisper.cpp)"
    if [ "$STT" = gpu ] && "$VENV_PIP" show pywhispercpp &>/dev/null; then
      if [ -f "$SITE_PKGS/libggml-cuda.so.0" ]; then
        ok "pywhispercpp compilado com CUDA (libggml-cuda.so.0 $(du -h "$SITE_PKGS/libggml-cuda.so.0" | cut -f1))"
      else
        fail "pywhispercpp instalado sem CUDA — o STT vai rodar na CPU"
        suggest "Rodar crew-setup.sh (passo 2) para instalar o build CUDA"
      fi
    fi
    ;;
  transcribe)
    _pkg_check boto3 "AWS SDK (Amazon Transcribe)"
    _pkg_check amazon-transcribe "cliente de streaming do Amazon Transcribe"
    ;;
  off) info "STT desligado no perfil: nenhum pacote de STT necessário" ;;
esac
if [ -s "$USER_EXTRAS" ]; then
  while read -r line; do
    name="$(echo "$line" | sed -E 's/[[:space:]]*[<>=!~;\[].*$//')"
    [ -n "$name" ] && _pkg_check "$name" "extra do usuário (.data/extras.txt)"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$USER_EXTRAS")
fi
if [ "$STT" = gpu ]; then
  WHEEL="$(ls -1t "$DATA_DIR"/wheels/*/pywhispercpp-*.whl 2>/dev/null | head -1)"
  if [ -n "$WHEEL" ]; then
    ok "Wheel com CUDA guardado: o próximo update reinstala em segundos"
  else
    info "Sem wheel guardado — o próximo crew-setup.sh compila (~10-15 min) e guarda"
  fi
fi

# ── 7. Bibliotecas do whisper e systemd (GPU) ─────────────────────────────────
section "Bibliotecas do whisper (GPU)"
if [ "$STT" != gpu ]; then
  info "Não se aplica (STT=$STT)"
else
  if [ "$(cat "$LDCONF" 2>/dev/null)" = "$STABLE_SITE" ]; then
    ok "$LDCONF aponta para o caminho estável"
  elif [ -f "$LDCONF" ]; then
    warn "$LDCONF aponta para $(cat "$LDCONF") (esperado: $STABLE_SITE)"
    suggest "Rodar crew-setup.sh (passo 3)"
  else
    fail "$LDCONF não existe — a libggml-cuda não é encontrada e o STT cai para CPU"
    suggest "Rodar crew-setup.sh (passo 3)"
  fi
  if ldconfig -p 2>/dev/null | grep -q libggml-cuda; then
    ok "libggml-cuda registrada no cache do ldconfig"
  else
    fail "libggml-cuda fora do cache do ldconfig"
  fi
fi
if [ -f "$OVERRIDE_FILE" ] && grep -q 'LD_PRELOAD=.*libggml-cuda' "$OVERRIDE_FILE"; then
  warn "LD_PRELOAD da libggml-cuda no systemd: não é necessário com o ldconfig e pesa em todo processo filho do gateway"
  suggest "Rodar crew-setup.sh (passo 4 remove o LD_PRELOAD)"
fi

# ── 8. Modelos do whisper ─────────────────────────────────────────────────────
section "Modelo do whisper"
case "$STT" in
  gpu|cpu)
    MODEL_FILE="$CREW_HOME/models/whisper/ggml-$STT_MODEL.bin"
    if [ -f "$MODEL_FILE" ]; then
      ok "ggml-$STT_MODEL.bin ($(du -h "$MODEL_FILE" | cut -f1))"
    else
      info "ggml-$STT_MODEL.bin ainda não baixado — o Crew baixa no primeiro uso"
    fi
    ;;
  *) info "Não se aplica (STT=$STT)" ;;
esac

# ── 9. Configurações do gateway ───────────────────────────────────────────────
_config_get() {
  local actual
  actual=$("$KIROCREW" config get "$1" 2>/dev/null | tr -d '"' | xargs)
  # `config get` não resolve chaves de mapas livres (ex.: agent.role_models.subagent
  # dá "Unknown key"), mas o `set` grava. Fallback: ler direto do config.json.
  if [ -z "$actual" ] && [ -x "$VENV_PY" ]; then
    actual=$("$VENV_PY" -c '
import json, sys
v = json.load(open(sys.argv[1]))
for p in sys.argv[2].split("."):
    v = v.get(p) if isinstance(v, dict) else None
print("" if v is None else v)' "$CREW_HOME/config.json" "$1" 2>/dev/null)
  fi
  echo "$actual"
}

_config_check() {  # chave esperado descrição
  local actual
  actual="$(_config_get "$1")"
  if [ "${actual,,}" = "${2,,}" ]; then
    ok "$1 = $2 — $3"
  else
    warn "$1 = ${actual:-não definido} (esperado: $2) — $3"
    suggest "kirocrew config set $1 $2"
  fi
}

section "Configurações do gateway (perfil)"
case "$STT" in
  gpu|cpu)
    _config_check stt.enabled True "STT ligado"
    _config_check stt.provider local "STT local (whisper.cpp)"
    _config_check stt.model "$STT_MODEL" "modelo do whisper do perfil"
    _config_check stt.language_code "$STT_LANGUAGE" "idioma do STT"
    ;;
  transcribe)
    _config_check stt.enabled True "STT ligado"
    _config_check stt.provider transcribe "STT na nuvem (Amazon Transcribe)"
    _config_check stt.language_code "$STT_LANGUAGE" "idioma do STT"
    ;;
  off) _config_check stt.enabled False "STT desligado no perfil" ;;
esac
TTS_PROVIDER="$(_config_get voice_reply.provider)"
if [ "$TTS_PROVIDER" = polly ]; then
  info "voice_reply.provider = polly (Amazon Polly, pago): mantido"
else
  _config_check voice_reply.provider system "TTS nativo pelo motor do SO (o provider piper saiu no 0.11)"
fi
if [ -n "$TTS_VOICE" ]; then
  _config_check voice_reply.system_voice "$TTS_VOICE" "voz do TTS nativo (espeak-ng)"
fi
_config_check agent.model auto "modelo principal automático (id fixo quebra quando sai do catálogo)"
_config_check agent.fallback_model auto "modelo de fallback automático"
_config_check agent.role_models.subagent auto "modelo dos sub-agentes automático"
_config_check agent.role_models.background auto "modelo das tarefas em background automático"

section "Preferências pessoais (.data/prefs.conf)"
if [ -s "$PREFS_FILE" ]; then
  while IFS='=' read -r key value; do
    key="$(echo "$key" | xargs)"; value="$(echo "$value" | xargs)"
    [ -n "$key" ] && _config_check "$key" "$value" "preferência pessoal"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$PREFS_FILE")
else
  info "Sem .data/prefs.conf (opcional: uma linha chave=valor por configuração a conferir)"
fi

# ── 10. Skills vinculadas ─────────────────────────────────────────────────────
section "Skills vinculadas ($(basename "$LINKED_SKILLS_FILE"))"
CHECK_OUT="$(mktemp)"
for s in $(linked_skill_names); do
  case " $SKILLS " in
    *" $s "*) ;;
    *) info "$s: fora do perfil"; continue ;;
  esac
  d="$(skill_dir "$s" || true)"
  if [ -z "$d" ]; then
    fail "$s não instalada"
    suggest "git clone $(linked_skill_url "$s") ~/.kiro/skills/$s  (ou rode crew-setup.sh)"
    continue
  fi
  if [ -f "$HOME/.kiro/skills/$s/SKILL.md" ] && [ -f "$CREW_HOME/skills/$s/SKILL.md" ]; then
    warn "$s instalada em dois lugares (~/.kiro/skills e $CREW_HOME/skills): a busca de skills vê as duas"
  fi
  if [ ! -d "$d/.git" ]; then
    warn "$s em $d é cópia sem git (não atualiza com git pull)"
    suggest "git clone $(linked_skill_url "$s") ~/.kiro/skills/$s e mover a cópia para backup"
  fi
  if [ ! -f "$d/tools/check.py" ]; then
    info "$s: sem tools/check.py"
  elif python3 "$d/tools/check.py" > "$CHECK_OUT" 2>&1; then
    ok "$s: check.py ok ($d)"
  else
    warn "$s: check.py tem pendências"
    grep -E '✗|→' "$CHECK_OUT" | sed 's/^/       /'
    suggest "python3 $d/tools/check.py"
  fi
done
rm -f "$CHECK_OUT"

# ── 11. STT no log do gateway ─────────────────────────────────────────────────
section "STT no log do gateway"
if [ "$STT" != gpu ]; then
  info "Não se aplica (STT=$STT)"
elif systemctl is-active "$SERVICE" &>/dev/null; then
  # Só linhas do start atual: linhas antigas de CUDA0 dariam falso positivo.
  SINCE="$(systemctl show "$SERVICE" --property=ActiveEnterTimestamp --value 2>/dev/null)"
  LINE=$(journalctl -u "$SERVICE" --since "${SINCE:-1 hour ago}" --no-pager 2>/dev/null | grep -E 'using CUDA0 backend|no GPU found' | tail -1)
  if echo "$LINE" | grep -q "using CUDA0 backend"; then
    ok "STT na GPU confirmado neste start"
  elif echo "$LINE" | grep -q "no GPU found"; then
    fail "STT caiu para CPU neste start ('no GPU found')"
    suggest "Rodar crew-setup.sh; se persistir, plano B: crew-setup.sh --ld-preload"
  else
    info "O whisper ainda não carregou neste start (carrega no 1º áudio ou alguns segundos após o start)"
  fi
else
  warn "$SERVICE não está rodando"
fi

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
if [ ${#ERRORS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ] && [ ${#SUGGESTIONS[@]} -eq 0 ]; then
  echo "  ✅ ✅  Ambiente compatível e configurado para o perfil!"
else
  [ ${#ERRORS[@]} -gt 0 ] && echo "  ❌  ${#ERRORS[@]} problema(s) bloqueante(s):" && for e in "${ERRORS[@]}"; do echo "    • $e"; done
  [ ${#WARNINGS[@]} -gt 0 ] && echo "  ⚠️   ${#WARNINGS[@]} aviso(s):" && for w in "${WARNINGS[@]}"; do echo "    • $w"; done
  [ ${#SUGGESTIONS[@]} -gt 0 ] && echo "  💡  ${#SUGGESTIONS[@]} sugestão(ões):" && for s in "${SUGGESTIONS[@]}"; do echo "    • $s"; done
fi
echo ""
echo "  Próximo passo:"
echo "  bash $TOOLS_DIR/crew-setup.sh   (--plan mostra o que vai fazer, sem alterar)"
echo "  Depois do restart, auditar logs/modelos/drift:"
echo "  python3 $TOOLS_DIR/crew-audit.py"
echo "════════════════════════════════════════════════"
echo ""
[ ${#ERRORS[@]} -eq 0 ]
