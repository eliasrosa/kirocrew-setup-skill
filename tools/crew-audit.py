#!/usr/bin/env python3
"""crew-audit.py — parte da skill crew-setup.

Auditoria pós-update do Kiro Crew. Complementa o crew-check.sh (que valida o
ambiente) olhando o que o update quebrou ou mudou:

  1. Erros e warnings no log do gateway desde o último start, agrupados por
     assinatura e cruzados com um catálogo de causas conhecidas.
  2. Modelos configurados (config.json + ~/.kiro/agents/*.json) que não existem
     mais na lista do kiro-cli.
  3. Referências a venvs antigos (crew-venv-<versão>) em arquivos de sistema e
     de config.
  4. Crash dumps com stack trace gerados desde o último start.
  5. Drift de config: compara o config.json atual com o snapshot da última
     auditoria (.data/config-baseline.json) e mostra o que mudou.

Uso:
  python3 tools/crew-audit.py              # audita e atualiza o snapshot
  python3 tools/crew-audit.py --no-save    # audita sem atualizar o snapshot
  python3 tools/crew-audit.py --since "2 hours ago"

Saída: exit 0 sem problemas, exit 1 com pelo menos um problema bloqueante.
Só usa a stdlib. Não altera nenhuma config do Crew (o agente não pode); só
reporta e sugere o comando.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

CREW_HOME = Path(os.environ.get("KIROCREW_HOME") or Path.home() / ".kiro/crew")
CONFIG_FILE = CREW_HOME / "config.json"
AGENTS_DIR = Path.home() / ".kiro/agents"
VENV_LINK = Path.home() / ".kiro/crew-venv-current"
SKILL_DIR = Path(__file__).resolve().parent.parent
BASELINE = SKILL_DIR / ".data" / "config-baseline.json"
SERVICE = "kirocrew.service"

# Arquivos onde um path de venv antigo costuma sobrar após o update.
STALE_PATH_FILES = [
    "/etc/systemd/system/kirocrew.service.d/override.conf",
    "/etc/ld.so.conf.d/kirocrew-whisper.conf",
    str(Path.home() / ".bashrc"),
    str(Path.home() / ".profile"),
    str(CONFIG_FILE),
]

# Chaves cujo valor nunca é mostrado nem gravado no snapshot.
SECRET_RE = re.compile(r"token|secret|password|passwd|api_key|apikey|\bpat\b|credential|sig", re.I)

# Catálogo de assinaturas conhecidas: (regex, nível, causa, correção).
# nível: "fail" bloqueia; "warn" exige olhar; "info" é ruído esperado.
MODEL_RX = r"model '([^']+)' is not available|InvalidModelError"
SUBAGENT_RX = r"kiro_crew\.subagent: Subagent \w+ failed"

KNOWN = [
    (MODEL_RX, "fail",
     "modelo configurado foi removido do catálogo do Kiro",
     "trocar para 'auto' ou um id da lista (ver seção Modelos)"),
    (r"LD_PRELOAD cannot be preloaded", "warn",
     "LD_PRELOAD aponta para venv que não existe mais",
     "rodar crew-setup.sh (passo 4/6); se só aparece em PID antigo, já foi corrigido"),
    (r"no GPU found", "fail",
     "STT caiu para CPU", "conferir LD_PRELOAD e libggml-cuda (crew-setup.sh passos 2-4)"),
    (r"ModuleNotFoundError: No module named '([^']+)'", "fail",
     "pacote extra sumiu do venv", "rodar crew-setup.sh (passo 1/6) ou incluir em extras.txt"),
    (r"AcpAuthRequired|session has expired", "fail",
     "login/sessão do kiro-cli expirou", "kiro-cli logout && kiro-cli login"),
    (SUBAGENT_RX, "warn",
     "sub-agentes falharam", "normalmente consequência de outro erro acima (ex.: modelo inválido em role_models.subagent)"),
    (r"whisper_full_with_state: failed to (?:en|de)code", "info",
     "áudio curto/silencioso que o whisper não decodificou",
     "só investigar se repetir em vários áudios"),
    (r"Event loop is closed|BaseSubprocessTransport.__del__", "info",
     "ruído de shutdown do asyncio no restart", "nenhuma"),
    (r"pam_unix\(sudo:auth\)", "info", "sudo cancelado no terminal", "nenhuma"),
]

ERR_RE = re.compile(r"\b(ERROR|CRITICAL|WARNING|WARN)\b|Traceback|Error:|failed", re.I)
NOISE_RE = re.compile(r'^\s*(File "|Traceback|raise |\^|_raise_acp_error|await |return )')

problems: list[str] = []
warnings: list[str] = []


def ok(msg: str) -> None:
    print(f"  ✅  {msg}")


def warn(msg: str) -> None:
    print(f"  ⚠️   {msg}")
    warnings.append(msg)


def fail(msg: str) -> None:
    print(f"  ❌  {msg}")
    problems.append(msg)


def info(msg: str) -> None:
    print(f"  ℹ️   {msg}")


def section(title: str) -> None:
    print(f"\n▸ {title}")


def run(cmd: list[str], timeout: int = 60) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def flatten(obj, prefix: str = "") -> dict[str, object]:
    out: dict[str, object] = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.update(flatten(v, f"{prefix}.{k}" if prefix else str(k)))
    else:
        out[prefix] = obj
    return out


def load_config() -> dict:
    try:
        return json.loads(CONFIG_FILE.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"não consegui ler {CONFIG_FILE}: {exc}")
        return {}


def service_start() -> str:
    out = run(["systemctl", "show", SERVICE, "-p", "ActiveEnterTimestamp", "--value"]).strip()
    return out


# ── 1. Log do gateway ─────────────────────────────────────────────────────────
def audit_logs(since: str | None, current_models: set[str]) -> None:
    resolved_model_error = False
    section("Log do gateway (erros e warnings)")
    if not shutil.which("journalctl"):
        warn("journalctl indisponível — pulei a análise de log")
        return
    start = since or service_start()
    if not start:
        warn(f"{SERVICE} sem horário de start — o serviço está rodando?")
        return
    info(f"Desde: {start}")
    raw = run(["journalctl", "-u", SERVICE, "--since", start, "--no-pager", "-o", "cat"], timeout=120)
    lines = [ln for ln in raw.splitlines() if ERR_RE.search(ln) and not NOISE_RE.match(ln)]
    if not lines:
        ok("nenhum erro/warning no log")
        return

    matched: Counter = Counter()
    details: dict[str, set[str]] = {}
    unknown: Counter = Counter()
    for ln in lines:
        for rx, *_ in KNOWN:
            m = re.search(rx, ln)
            if m:
                matched[rx] += 1
                if m.groups() and m.group(1):
                    details.setdefault(rx, set()).add(m.group(1))
                break
        else:
            sig = re.sub(r"\b[0-9a-f]{8,}\b|\d+", "#", ln.strip())
            sig = re.sub(r"Request ID: [^)]+", "Request ID: #", sig)[:160]
            unknown[sig] += 1

    for rx, level, cause, fix in KNOWN:
        n = matched.get(rx)
        if not n:
            continue
        extra = f" [{', '.join(sorted(details[rx]))}]" if rx in details else ""
        msg = f"{n}x {cause}{extra} → {fix}"
        # Erro de modelo cujo id já saiu da config: é histórico, já corrigido.
        if rx == MODEL_RX and rx in details and not (details[rx] & current_models):
            level, msg = "info", f"{n}x {cause}{extra} → histórico: o modelo não está mais configurado (já corrigido)"
            resolved_model_error = True
        elif rx == SUBAGENT_RX and resolved_model_error:
            level, msg = "info", f"{n}x {cause} → histórico: consequência do erro de modelo já corrigido"
        {"fail": fail, "warn": warn, "info": info}[level](msg)

    if unknown:
        warn(f"{sum(unknown.values())} linha(s) sem assinatura conhecida — revisar e, se recorrente, incluir no catálogo KNOWN:")
        for sig, n in unknown.most_common(10):
            print(f"       {n:>4}x  {sig}")


# ── 2. Modelos ────────────────────────────────────────────────────────────────
def available_models() -> list[str]:
    if not shutil.which("kiro-cli"):
        return []
    raw = run(["kiro-cli", "chat", "--list-models", "--format", "json"], timeout=60)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    items = data.get("models", data) if isinstance(data, dict) else data
    ids = []
    for m in items or []:
        ids.append(m.get("id") or m.get("model_id") if isinstance(m, dict) else m)
    return [i for i in ids if i]


def collect_model_refs(cfg: dict) -> tuple[list[tuple[str, str]], set[str]]:
    """Retorna (referências (onde, modelo), conjunto de 'onde' que são specs derivados)."""
    refs: list[tuple[str, str]] = []
    # Chaves de modelo de LLM; stt/voice_reply/memory usam modelos locais, fora do catálogo.
    skip = ("stt.", "voice_reply.", "memory.")
    for key, val in flatten(cfg).items():
        if not isinstance(val, str) or not val or key.startswith(skip):
            continue
        if re.search(r"(^|\.)(\w*_)?model$|role_models\.", key):
            refs.append((f"config.json → {key}", val))
    derived: set[str] = set()
    for f in sorted(glob.glob(str(AGENTS_DIR / "*.json"))):
        try:
            spec = json.loads(Path(f).read_text())
        except (OSError, json.JSONDecodeError):
            continue
        model = spec.get("model")
        if model:
            where = f"agents/{Path(f).name} → model"
            refs.append((where, model))
            if "do not edit" in str(spec.get("description", "")):
                derived.add(where)
    return refs, derived


def active_models(cfg: dict) -> set[str]:
    """Modelos configurados hoje, sem os specs derivados (que regeneram sozinhos)."""
    refs, derived = collect_model_refs(cfg)
    return {m for where, m in refs if where not in derived}


def audit_models(cfg: dict) -> None:
    section("Modelos configurados x catálogo do kiro-cli")
    avail = available_models()
    if not avail:
        warn("não consegui listar modelos (kiro-cli ausente, offline ou sem login) — pulei")
        return
    info(f"Disponíveis: {', '.join(avail)}")
    refs, derived = collect_model_refs(cfg)

    bad = [(where, m) for where, m in refs if m not in avail]
    for where, m in bad:
        if where in derived:
            warn(f"{where} = {m} (spec derivado, regenera sozinho no próximo uso; não editar)")
        else:
            fail(f"{where} = {m} (não existe mais)")
    if any(w not in derived for w, _ in bad):
        print("       Correção: trocar para 'auto' ou um id disponível. config.json é protegido para o agente:")
        print("       o usuário roda `kirocrew config set <chave> auto` ou ajusta em Settings no dashboard.")
    else:
        ok(f"{len(refs)} referência(s) de modelo válidas")


# ── 3. Paths de venv antigos ──────────────────────────────────────────────────
def audit_stale_paths() -> None:
    section("Referências a venv antigo")
    current = VENV_LINK.resolve().name if VENV_LINK.exists() else ""
    info(f"Venv atual: {current or 'desconhecido'}")
    rx = re.compile(r"crew-venv-(\d+\.\d+\.\d+)")
    found = False
    files = STALE_PATH_FILES + sorted(glob.glob(str(AGENTS_DIR / "*.json")))
    for f in files:
        try:
            text = Path(f).read_text()
        except OSError:
            continue
        olds = {f"crew-venv-{v}" for v in rx.findall(text)} - {current}
        if olds:
            found = True
            fail(f"{f} cita {', '.join(sorted(olds))} → apontar para {current} (crew-setup.sh passos 3-4)")
    env_preload = os.environ.get("LD_PRELOAD", "")
    if env_preload and not Path(env_preload).exists():
        found = True
        warn(f"LD_PRELOAD do shell atual aponta para arquivo inexistente: {env_preload} → `unset LD_PRELOAD` ou abrir terminal novo")
    if not found:
        ok("nenhuma referência a venv antigo")


# ── 4. Crash dumps ────────────────────────────────────────────────────────────
def audit_crash_dumps() -> None:
    section("Crash dumps")
    start = service_start()
    try:
        start_ts = datetime.strptime(start.rsplit(" ", 1)[0], "%a %Y-%m-%d %H:%M:%S").timestamp() if start else 0
    except ValueError:
        start_ts = 0
    dumps = [p for p in (CREW_HOME / "logs" / "crash-dumps").glob("*") if p.stat().st_mtime >= start_ts]
    with_stack = [p for p in dumps if "Thread" in p.read_text(errors="ignore")]
    if with_stack:
        for p in with_stack:
            warn(f"{p} tem stack trace — event loop travou; ler o arquivo")
    elif dumps:
        ok(f"{len(dumps)} dump(s) só com cabeçalho (sem travamento)")
    else:
        ok("nenhum crash dump desde o start")


# ── 5. Drift de config ────────────────────────────────────────────────────────
def mask(key: str, val: object) -> object:
    return "***" if SECRET_RE.search(key) and val not in ("", None) else val


def audit_drift(cfg: dict, save: bool) -> None:
    section("Drift de config desde a última auditoria")
    # meta.* é carimbo de gravação (lastTouchedAt etc.), muda a cada save: não é drift.
    flat = {k: mask(k, v) for k, v in flatten(cfg).items() if not k.startswith("meta.")}
    if BASELINE.exists():
        try:
            base = json.loads(BASELINE.read_text())
        except json.JSONDecodeError:
            base = {}
        prev, when = base.get("config", {}), base.get("saved_at", "?")
        info(f"Snapshot anterior: {when} (Crew {base.get('crew_version', '?')})")
        changed = [k for k in flat if k in prev and prev[k] != flat[k]]
        added = [k for k in flat if k not in prev]
        removed = [k for k in prev if k not in flat]
        for k in changed:
            warn(f"mudou: {k}: {prev[k]!r} → {flat[k]!r}")
        if added:
            info(f"{len(added)} chave(s) nova(s): {', '.join(added[:15])}{' …' if len(added) > 15 else ''}")
        if removed:
            warn(f"{len(removed)} chave(s) removida(s): {', '.join(removed[:15])}{' …' if len(removed) > 15 else ''}")
        if not (changed or added or removed):
            ok("nenhuma mudança")
    else:
        info("primeira auditoria — sem snapshot para comparar")
    if save:
        BASELINE.parent.mkdir(parents=True, exist_ok=True)
        BASELINE.write_text(json.dumps({
            "saved_at": datetime.now().strftime("%d/%m/%Y %H:%M"),
            "crew_version": VENV_LINK.resolve().name if VENV_LINK.exists() else "",
            "config": flat,
        }, indent=1, ensure_ascii=False, default=str))
        info(f"snapshot atualizado em {BASELINE}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Auditoria pós-update do Kiro Crew")
    ap.add_argument("--since", help="janela do journalctl (padrão: último start do serviço)")
    ap.add_argument("--no-save", action="store_true", help="não atualizar o snapshot de config")
    args = ap.parse_args()

    print("\n╔══════════════════════════════════════════════╗")
    print("║   Kiro Crew — auditoria pós-update           ║")
    print("╚══════════════════════════════════════════════╝")

    cfg = load_config()
    audit_logs(args.since, active_models(cfg))
    audit_models(cfg)
    audit_stale_paths()
    audit_crash_dumps()
    if cfg:
        audit_drift(cfg, save=not args.no_save)

    print("\n════════════════════════════════════════════════")
    if problems:
        print(f"  ❌  {len(problems)} problema(s):")
        for p in problems:
            print(f"    • {p}")
    if warnings:
        print(f"  ⚠️   {len(warnings)} aviso(s):")
        for w in warnings:
            print(f"    • {w}")
    if not problems and not warnings:
        print("  ✅  Nada a ajustar")
    print("════════════════════════════════════════════════\n")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
