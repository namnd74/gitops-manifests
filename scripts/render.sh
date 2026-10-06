#!/usr/bin/env bash
set -Eeuo pipefail
for option in "$@"; do
    case "$option" in
        --help|-h) echo 'Usage: bash scripts/render.sh'; exit 0 ;;
        *) echo "Unknown option: $option" >&2; exit 2 ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-common.sh
source "$SCRIPT_DIR/local-common.sh"
init_local
# Bootstrap only: create cluster secrets and Argo Applications tracking GitHub main.
require_tools kubeseal yq od
bootstrap="$STATE_DIR/bootstrap"
mkdir -p "$bootstrap/applications" "$bootstrap/secrets"
kubeseal --context "$CONTEXT" --fetch-cert > "$STATE_DIR/controller-cert.pem"
for environment in dev staging prod; do
    cached="$STATE_DIR/$environment-sealed.yaml"
    if [[ ! -f "$cached" ]] || ! kubeseal --context "$CONTEXT" --validate < "$cached" >/dev/null 2>&1; then
        od -An -N24 -tx1 /dev/urandom | tr -d ' \n' | \
            jq -Rs --arg env "$environment" '{apiVersion:"v1",kind:"Secret",
                metadata:{name:"be-service-secret",namespace:$env},type:"Opaque",stringData:{DB_PASSWORD:.}}' | \
            kubeseal --cert "$STATE_DIR/controller-cert.pem" --scope strict --format yaml > "$cached"
    fi
    cp "$cached" "$bootstrap/secrets/$environment-sealed.yaml"
    ENVIRONMENT="$environment" yq '
        .metadata.name = "be-service-" + strenv(ENVIRONMENT) |
        .spec.source.repoURL = strenv(CONFIG_REPO_URL) |
        .spec.source.path = "apps/be-service/envs/" + strenv(ENVIRONMENT) |
        .spec.destination.namespace = strenv(ENVIRONMENT)
        ' "$SCRIPT_DIR/templates/application.yaml" > "$bootstrap/applications/be-service-$environment.yaml"
done
jq -n --arg repo "$CONFIG_REPO_URL" '{repoURL:$repo,targetRevision:"main"}' | write_state bootstrap.json
echo "[PASS] render: bootstrap secrets and Applications for $CONFIG_REPO_URL (main)"
