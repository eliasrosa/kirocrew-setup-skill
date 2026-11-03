#!/usr/bin/env bash
# lib.sh — parte da skill crew-setup.
# Biblioteca usada pelo crew-setup.sh e pelo crew-check.sh (via `source`):
# caminhos do Kiro Crew, detecção do ambiente, perfil da máquina e skills
# vinculadas. Não executa nada sozinha.

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$SKILL_ROOT/tools"
DATA_DIR="$SKILL_ROOT/.data"
PROFILE_FILE="$DATA_DIR/profile.env"     # perfil escolhido (gitignored)
PREFS_FILE="$DATA_DIR/prefs.conf"        # preferências pessoais conferidas pelo check
USER_EXTRAS="$DATA_DIR/extras.txt"       # pacotes extras do usuário (formato pip)
LINKED_SKILLS_FILE="$TOOLS_DIR/linked-skills.txt"

# Diretório base do Kiro Crew: respeita KIROCREW_HOME, como o próprio Crew.
CREW_HOME="${KIROCREW_HOME:-$HOME/.kiro/crew}"
CREW_HOME="${CREW_HOME%/}"

# Venv: o Crew instala cada versão em <CREW_HOME>-venv-<versão> e troca o alvo do
# link estável <CREW_HOME>-venv-current a cada update. O link vai nos arquivos de
# sistema (não fica velho); o alvo resolvido serve para instalar pacotes agora.
if [ -L "${CREW_HOME}-venv-current" ]; then
  STABLE_VENV="${CREW_HOME}-venv-current"
  CREW_VENV="$(readlink -f "$STABLE_VENV")"
else
  STABLE_VENV="${CREW_HOME}-venv"   # instalação legada (pré-0.10)
  CREW_VENV="$STABLE_VENV"
fi
VENV_PY="$CREW_VENV/bin/python3"
VENV_PIP="$CREW_VENV/bin/pip"
SITE_PKGS=""
STABLE_SITE=""
if [ -x "$VENV_PY" ]; then
  SITE_PKGS="$("$VENV_PY" -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null || true)"
  [ -n "$SITE_PKGS" ] && STABLE_SITE="$STABLE_VENV/${SITE_PKGS#"$CREW_VENV"/}"
fi

LDCONF="/etc/ld.so.conf.d/kirocrew-whisper.conf"
OVERRIDE_FILE="/etc/systemd/system/kirocrew.service.d/override.conf"
SERVICE="kirocrew.service"

# ── Detecção do ambiente ──────────────────────────────────────────────────────
detect_gpu() {  # nvidia | amd | none
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    echo nvidia
  elif command -v rocminfo >/dev/null 2>&1 || command -v rocm-smi >/dev/null 2>&1; then
    echo amd
  else
    echo none
  fi
}

detect_gpu_name() {
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || true
}

detect_cuda_toolkit() {  # versão do nvcc, vazio se ausente
  nvcc --version 2>/dev/null | grep -oP 'release \K[\d.]+' || true
}

detect_language() {  # pt_BR.UTF-8 -> pt-BR; sem locale útil -> pt-BR
  local l="${LC_ALL:-${LANG:-}}"
  if [[ "$l" =~ ^([a-z]{2})_([A-Z]{2}) ]]; then
    echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  else
    echo "pt-BR"
  fi
}

describe_env() {
  local gpu cuda
  gpu="$(detect_gpu)"
  cuda="$(detect_cuda_toolkit)"
  case "$gpu" in
    nvidia) printf 'GPU NVIDIA (%s)' "$(detect_gpu_name)" ;;
    amd)    printf 'GPU AMD/ROCm (sem build automático)' ;;
    *)      printf 'sem GPU dedicada' ;;
  esac
  if [ -n "$cuda" ]; then printf ' • CUDA toolkit %s' "$cuda"; else printf ' • sem CUDA toolkit (nvcc)'; fi
  if command -v espeak-ng >/dev/null 2>&1; then printf ' • espeak-ng ok'; else printf ' • sem espeak-ng'; fi
  echo
}

# ── Skills vinculadas ─────────────────────────────────────────────────────────
linked_skill_names() {
  grep -vE '^[[:space:]]*(#|$)' "$LINKED_SKILLS_FILE" 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | sed 's/ *$//' || true
}

linked_skill_url() {
  awk -v n="$1" '$1 == n {print $2}' "$LINKED_SKILLS_FILE" 2>/dev/null || true
}

skill_dir() {  # pasta da skill: ~/.kiro/skills/<nome>, senão <CREW_HOME>/skills/<nome>
  local d
  for d in "$HOME/.kiro/skills/$1" "$CREW_HOME/skills/$1"; do
    if [ -f "$d/SKILL.md" ]; then echo "$d"; return 0; fi
  done
  return 1
}

filter_linked() {  # mantém só nomes que estão no linked-skills.txt
  local s out="" all
  all=" $(linked_skill_names) "
  for s in $1; do
    case "$all" in *" $s "*) out="$out $s" ;; esac
  done
  echo "${out# }"
}

# ── Perfil da máquina ─────────────────────────────────────────────────────────
# Lido como texto (chave=valor), nunca com `source`: o arquivo não é executado.
profile_get() {
  [ -f "$PROFILE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$PROFILE_FILE" | tail -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

profile_load() {
  PROFILE_SAVED=0
  STT="$(profile_get STT)"
  STT_MODEL="$(profile_get STT_MODEL)"
  STT_LANGUAGE="$(profile_get STT_LANGUAGE)"
  TTS_VOICE="$(profile_get TTS_VOICE)"
  SKILLS="$(profile_get SKILLS)"
  case "$STT" in gpu|cpu|transcribe|off) PROFILE_SAVED=1 ;; *) STT="" ;; esac
  [[ "$STT_MODEL" =~ ^[A-Za-z0-9._-]+$ ]] || STT_MODEL=""
  [[ "$STT_LANGUAGE" =~ ^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?$ ]] || STT_LANGUAGE=""
  [[ "$TTS_VOICE" =~ ^[A-Za-z0-9._+-]*$ ]] || TTS_VOICE=""
  SKILLS="$(filter_linked "$SKILLS")"
}

default_stt() {
  if [ "$(detect_gpu)" = nvidia ] && [ -n "$(detect_cuda_toolkit)" ]; then echo gpu; else echo cpu; fi
}

default_stt_model() {  # GPU aguenta o modelo grande; na CPU o small é o equilíbrio
  if [ "$1" = gpu ]; then echo large-v3-turbo; else echo small; fi
}

profile_defaults() {  # completa o que faltar com o detectado
  [ -n "$STT" ] || STT="$(default_stt)"
  [ -n "$STT_MODEL" ] || STT_MODEL="$(default_stt_model "$STT")"
  [ -n "$STT_LANGUAGE" ] || STT_LANGUAGE="$(detect_language)"
  if [ "$PROFILE_SAVED" -eq 0 ]; then
    TTS_VOICE="$(echo "$STT_LANGUAGE" | tr '[:upper:]' '[:lower:]')"  # pt-BR -> pt-br (espeak-ng)
    SKILLS="$(linked_skill_names)"
  fi
}

_ask() {  # _ask "pergunta" padrão -> resposta (Enter = padrão)
  local reply=""
  read -r -p "  $1 [$2]: " reply || true
  echo "${reply:-$2}"
}

profile_ask() {
  local v s d url
  echo ""
  echo "▸ Perfil desta máquina (fica em .data/profile.env; mude com --reconfigure)"
  echo "  Detectado: $(describe_env)"
  echo ""
  echo "  Transcrição de áudio (STT):"
  echo "    gpu         whisper local na GPU NVIDIA (compila com CUDA; ~10-15 min na 1ª vez)"
  echo "    cpu         whisper local na CPU (sem compilar; mais lento)"
  echo "    transcribe  Amazon Transcribe (nuvem; precisa de conta AWS)"
  echo "    off         sem transcrição"
  local def="$STT"   # padrão da pergunta; nunca fica em gpu sem GPU (evita loop no EOF)
  while :; do
    v="$(_ask "Escolha" "$def")"
    case "$v" in
      gpu)
        if [ "$(detect_gpu)" != nvidia ]; then
          echo "    ⚠️  Não há GPU NVIDIA nesta máquina: a compilação com CUDA vai falhar. Escolha outra opção."
          def=cpu
          continue
        fi
        [ -n "$(detect_cuda_toolkit)" ] || echo "    ⚠️  Falta o CUDA toolkit: instale antes (sudo apt install nvidia-cuda-toolkit)."
        break ;;
      cpu|transcribe|off) break ;;
      *) echo "    Opção inválida: $v" ;;
    esac
  done
  [ "$v" = "$STT" ] || STT_MODEL="$(default_stt_model "$v")"
  STT="$v"
  if [ "$STT" = gpu ] || [ "$STT" = cpu ]; then
    STT_MODEL="$(_ask "Modelo do whisper (large-v3-turbo, medium, small, base)" "$STT_MODEL")"
  fi
  if [ "$STT" != off ]; then
    STT_LANGUAGE="$(_ask "Idioma da transcrição" "$STT_LANGUAGE")"
  fi
  v="$(_ask "Voz do TTS nativo do dashboard (espeak-ng; - = não mexer)" "${TTS_VOICE:--}")"
  [ "$v" = "-" ] && TTS_VOICE="" || TTS_VOICE="$v"
  echo ""
  echo "  Skills vinculadas (o setup instala/restaura e o check valida):"
  local chosen=""
  for s in $(linked_skill_names); do
    d="$(skill_dir "$s" || true)"
    url="$(linked_skill_url "$s")"
    if [ -n "$d" ]; then d="instalada"; else d="não instalada; o setup clona de $url"; fi
    case " $SKILLS " in *" $s "*) v="S" ;; *) v="n" ;; esac
    v="$(_ask "$s ($d). Configurar? S/n" "$v")"
    case "$v" in [SsYy]*) chosen="$chosen $s" ;; esac
  done
  SKILLS="${chosen# }"
}

profile_save() {
  mkdir -p "$DATA_DIR"
  {
    echo "# Perfil do crew-setup, gerado em $(date '+%d/%m/%Y %H:%M')."
    echo "# Edite à mão ou rode: bash tools/crew-setup.sh --reconfigure"
    echo "STT=$STT"
    echo "STT_MODEL=$STT_MODEL"
    echo "STT_LANGUAGE=$STT_LANGUAGE"
    echo "TTS_VOICE=$TTS_VOICE"
    echo "SKILLS=\"$SKILLS\""
  } > "$PROFILE_FILE"
}

profile_show() {
  local stt_desc
  case "$STT" in
    gpu) stt_desc="whisper local na GPU ($STT_MODEL, $STT_LANGUAGE)" ;;
    cpu) stt_desc="whisper local na CPU ($STT_MODEL, $STT_LANGUAGE)" ;;
    transcribe) stt_desc="Amazon Transcribe ($STT_LANGUAGE)" ;;
    off) stt_desc="desligado" ;;
  esac
  echo "  STT ............. $stt_desc"
  echo "  TTS do dashboard  ${TTS_VOICE:-não mexer} (provider system)"
  echo "  Skills .......... ${SKILLS:-nenhuma}"
}
