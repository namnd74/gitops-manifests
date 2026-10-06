#!/usr/bin/env bash
set -Eeuo pipefail
for option in "$@"; do
    case "$option" in
        --help|-h) echo 'Usage: bash scripts/setup.sh'; exit 0 ;;
        *) echo "Unknown option: $option" >&2; exit 2 ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-common.sh
source "$SCRIPT_DIR/local-common.sh"
init_local
# Step 1: create the cluster and install its controllers. No app image is built here.
require_tools docker git k3d kubectl
docker info >/dev/null
settings=$(settings_json)
clusters=$(k3d cluster list -o json)
if jq -e --arg name "$CLUSTER_NAME" 'any(.[]; .name == $name)' <<< "$clusters" >/dev/null; then
    if [[ ! -f "$STATE_DIR/cluster-settings.json" ]] ||
        ! jq -e --argjson settings "$settings" '. == $settings' "$STATE_DIR/cluster-settings.json" >/dev/null; then
        fail 'Existing cluster has different/unmanaged settings; choose another CLUSTER_NAME or delete it explicitly'
    fi
fi
mkdir -p "$STATE_DIR"
printf '%s\n' "$settings" > "$STATE_DIR/cluster-settings.json"
# shellcheck source=tool-versions.env
source "$SCRIPT_DIR/tool-versions.env"
if ! jq -e --arg name "$CLUSTER_NAME" 'any(.[]; .name == $name)' <<< "$clusters" >/dev/null; then
    k3d cluster create "$CLUSTER_NAME" --image "$K3S_IMAGE" --servers 1 --agents 2 \
        --port "127.0.0.1:$HTTP_PORT:80@loadbalancer" --port "127.0.0.1:$HTTPS_PORT:443@loadbalancer" \
        --k3s-arg '--disable=traefik@server:0' --wait
fi
k wait --for=condition=Ready node --all --timeout=180s
for namespace in dev staging prod argocd ingress-nginx; do
    k create namespace "$namespace" --dry-run=client -o yaml | k apply -f -
done
# Recreate completed admission jobs when upgrading the pinned ingress version.
for job in ingress-nginx-admission-create ingress-nginx-admission-patch; do
    old_job=$(k get job "$job" -n ingress-nginx -o json --ignore-not-found)
    if [[ -n "$old_job" ]] && jq -e --arg version "${INGRESS_VERSION#controller-v}" '
        (.metadata.labels["app.kubernetes.io/version"] != $version) and
        any(.status.conditions[]?; .type == "Complete" and .status == "True")
        ' <<< "$old_job" >/dev/null; then
        k delete job "$job" -n ingress-nginx
    fi
done
k apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_VERSION/deploy/static/provider/cloud/deploy.yaml"
k rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=300s
k apply -f "https://github.com/bitnami/sealed-secrets/releases/download/$SEALED_SECRETS_VERSION/controller.yaml"
k rollout status deployment/sealed-secrets-controller -n kube-system --timeout=300s
k apply --server-side -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
for deployment in argocd-redis argocd-repo-server argocd-server argocd-applicationset-controller argocd-dex-server argocd-notifications-controller; do
    k rollout status "deployment/$deployment" -n argocd --timeout=300s
done
k rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
k apply -f "$SCRIPT_DIR/argocd-ingress.yaml"
echo "[PASS] setup: infrastructure ready; Argo CD http://localhost:$HTTP_PORT/"
