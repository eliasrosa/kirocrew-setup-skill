#!/usr/bin/env bash
# crew.sh — atalho para crew-check, crew-setup e crew-audit
# Uso: crew [check|setup|audit] [args...]
#      crew           → crew-check (default)
#      crew setup     → crew-setup.sh
#      crew audit     → crew-audit.py

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-check}" in
    check)
        shift 2>/dev/null || true
        bash "$SCRIPT_DIR/crew-check.sh" "$@"
        ;;
    setup)
        shift
        bash "$SCRIPT_DIR/crew-setup.sh" "$@"
        ;;
    audit)
        shift
        python3 "$SCRIPT_DIR/crew-audit.py" "$@"
        ;;
    *)
        echo "Uso: crew [check|setup|audit] [args...]"
        exit 1
        ;;
esac
