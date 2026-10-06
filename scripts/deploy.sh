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
    k apply -f "$STATE_DIR/bootstrap/applications/be-service-$environment.yaml"
    k apply -f "$STATE_DIR/bootstrap/secrets/$environment-sealed.yaml"
    # Take bootstrap secrets out of former Argo tracking before changing its source.
    k -n "$environment" annotate sealedsecret be-service-secret argocd.argoproj.io/tracking-id- --overwrite
    k -n "$environment" label sealedsecret be-service-secret app.kubernetes.io/instance- --overwrite
    k -n "$environment" wait --for=condition=Synced sealedsecret/be-service-secret --timeout=60s
    k -n "$environment" get secret be-service-secret -o name
    k -n argocd annotate application "be-service-$environment" argocd.argoproj.io/refresh=hard --overwrite
done
echo '[OK] Argo tracks GitHub dev/stg/prod branches. Future releases deploy after merging the manifest PR.'
