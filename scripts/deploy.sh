#!/usr/bin/env bash
set -Eeuo pipefail
for option in "$@"; do
    case "$option" in
        --help|-h) echo 'Usage: bash scripts/deploy.sh'; exit 0 ;;
        *) echo "Unknown option: $option" >&2; exit 2 ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-common.sh
source "$SCRIPT_DIR/local-common.sh"
init_local
# Bootstrap only: apply secrets, then let Argo own the backend resources from GitHub.
require_tools kubectl
read_state bootstrap.json render >/dev/null
for environment in dev staging prod; do
    k apply -f "$STATE_DIR/bootstrap/secrets/$environment-sealed.yaml"
    k apply -f "$STATE_DIR/bootstrap/applications/be-service-$environment.yaml"
    k -n argocd annotate application "be-service-$environment" argocd.argoproj.io/refresh=hard --overwrite
done
echo '[OK] Argo tracks GitHub main for dev/staging/prod. Future releases deploy after merging the manifest PR.'
