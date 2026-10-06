#!/usr/bin/env bash
# Optional dispatcher. Each step also runs directly as its own Bash script.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo 'Usage: bash scripts/local-dev.sh {setup|build|render|deploy|check|up|status|down}'; }
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in
    --help|-h) usage ;;
    up) for step in setup render deploy; do bash "$SCRIPT_DIR/$step.sh"; done ;;
    setup|build|render|deploy|check) bash "$SCRIPT_DIR/$1.sh" ;;
    status|down)
        # shellcheck source=local-common.sh
        source "$SCRIPT_DIR/local-common.sh"
        init_local
        if [[ "$1" == status ]]; then
            require_tools kubectl; k -n argocd get applications
        else
            require_tools k3d; k3d cluster delete "$CLUSTER_NAME"
            echo 'Local state retained; render.sh validates and reseals secrets for the next cluster.'
        fi ;;
    *) echo "Unknown command: $1" >&2; usage >&2; exit 2 ;;
esac
