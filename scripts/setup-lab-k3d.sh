#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for option in "$@"; do
    case "$option" in
        --help|-h) echo 'Usage: bash scripts/setup-lab-k3d.sh (internal; use scripts/local-dev.sh up)'; exit 0 ;;
        *) echo "Unknown option: $option" >&2; exit 2 ;;
    esac
done
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tool-versions.env"
: "${CLUSTER_NAME:?Use scripts/local-dev.sh up}"
: "${HTTP_PORT:?Use scripts/local-dev.sh up}"
: "${HTTPS_PORT:?Use scripts/local-dev.sh up}"
: "${LOCAL_GIT_VOLUME:?Use scripts/local-dev.sh up}"
CONTEXT="k3d-$CLUSTER_NAME"
trap 'echo "[ERROR] Setup stopped at line $LINENO; no success is assumed." >&2' ERR
info() { echo "[INFO] $*"; }
for tool in docker kubectl k3d python3; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
docker info >/dev/null
if ! k3d cluster list -o json | python3 -c 'import json,sys;sys.exit(0 if any(x["name"]==sys.argv[1] for x in json.load(sys.stdin)) else 1)' "$CLUSTER_NAME"; then
    volumes=()
    if [[ -n "${LOCAL_GIT_VOLUME:-}" ]]; then volumes+=(--volume "$LOCAL_GIT_VOLUME:/gitops-source@server:0"); fi
    k3d cluster create "$CLUSTER_NAME" --image "$K3S_IMAGE" --servers 1 --agents 2 \
        --port "127.0.0.1:$HTTP_PORT:80@loadbalancer" --port "127.0.0.1:$HTTPS_PORT:443@loadbalancer" "${volumes[@]}" \
        --k3s-arg '--disable=traefik@server:0' --wait
fi
K=(kubectl --context "$CONTEXT" --request-timeout=30s)
"${K[@]}" wait --for=condition=Ready node --all --timeout=180s
for ns in dev staging prod argocd ingress-nginx; do
    "${K[@]}" create namespace "$ns" --dry-run=client -o yaml | "${K[@]}" apply -f -
done
info 'Installing pinned controllers and checking rollout (no ignored timeout)'
for job in ingress-nginx-admission-create ingress-nginx-admission-patch; do
    if "${K[@]}" get job "$job" -n ingress-nginx -o json --ignore-not-found | \
        python3 -c 'import json,sys; raw=sys.stdin.read(); d=json.loads(raw) if raw else {}; old=d.get("metadata",{}).get("labels",{}).get("app.kubernetes.io/version"); done=any(c.get("type")=="Complete" and c.get("status")=="True" for c in d.get("status",{}).get("conditions",[])); sys.exit(0 if done and old!=sys.argv[1] else 1)' "${INGRESS_VERSION#controller-v}"; then
        "${K[@]}" delete job "$job" -n ingress-nginx
    fi
done
"${K[@]}" apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_VERSION/deploy/static/provider/cloud/deploy.yaml"
"${K[@]}" rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=300s
"${K[@]}" apply -f "https://github.com/bitnami/sealed-secrets/releases/download/$SEALED_SECRETS_VERSION/controller.yaml"
"${K[@]}" rollout status deployment/sealed-secrets-controller -n kube-system --timeout=300s
"${K[@]}" apply --server-side -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
for deployment in argocd-redis argocd-repo-server argocd-server argocd-applicationset-controller argocd-dex-server argocd-notifications-controller; do
    "${K[@]}" rollout status "deployment/$deployment" -n argocd --timeout=300s
done
"${K[@]}" rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
"${K[@]}" apply -f "$SCRIPT_DIR/argocd-ingress.yaml"
echo '[OK] Infrastructure ready. No application release or config file was changed.'
echo 'Next: use scripts/local-dev.sh up for the complete local flow, see README.md.'
echo "Argo CD: http://localhost:$HTTP_PORT (admin password: see README.md)."
