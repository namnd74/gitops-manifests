#!/usr/bin/env bash
# Operate the lab; releases and promotion remain in GitHub Actions / Git.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT=k3d-gitops-demo
K=(kubectl --context "$CONTEXT" --request-timeout=20s)
usage() {
    cat <<'USAGE'
Usage: bash scripts/demo.sh COMMAND [ENV]
  doctor       Check local prerequisites and GitHub authentication (read only)
  setup        Install k3d infrastructure; does not deploy the application
  seal         Generate lab passwords only for invalid/missing sealed secrets
  connect      Point Argo at GitHub after a committed, published Dev release
  status       Show Argo applications and deployments (read only)
  check ENV    Verify Git revision, Argo health, image digest and HTTP version
  --help       Show this guide
Releases: commit/push be-service. Promotion/rollback: GitOps GitHub workflows.
Full instructions: scripts/demo-runbook.md
USAGE
}
command=${1:---help}
case "$command" in doctor|setup|seal|connect|status|check) ;; --help|-h) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
require() { command -v "$1" >/dev/null || { echo "Missing tool: $1" >&2; exit 1; }; }
case "$command" in
 doctor)
    for tool in docker kubectl k3d kubeseal kustomize yq jq git gh cosign python3 openssl; do require "$tool"; done
    docker info >/dev/null
    gh auth status
    echo '[PASS] Local tools, Docker and GitHub authentication available. Remote secrets/rules are checked separately.'
    ;;
 setup) bash "$ROOT/setup.sh" ;;
 seal)
    for tool in kubectl kubeseal python3 openssl; do require "$tool"; done
    temporary=$(mktemp -d)
    trap 'rm -rf "$temporary"' EXIT
    kubeseal --context "$CONTEXT" --fetch-cert > "$temporary/cert.pem"
    for env in dev staging prod; do
        target="$ROOT/apps/be-service/envs/$env/sealed-secret.yaml"
        if kubeseal --context "$CONTEXT" --validate < "$target" >/dev/null 2>&1; then
            echo "[KEEP] $env ciphertext valid for this controller"
        else
            openssl rand -hex 24 | bash "$ROOT/scripts/seal-secret.sh" "$env" "$temporary/cert.pem" > "$temporary/secret.yaml"
            mv "$temporary/secret.yaml" "$target"
            echo "[UPDATED] $env lab ciphertext; commit/push it before Argo sync"
        fi
    done
    ;;
 connect)
    require gh; require git
    gh auth status
    cd "$ROOT"
    [[ -z "$(git status --porcelain)" ]] || { echo 'Commit/merge and pull config changes first; working tree must be clean.' >&2; exit 1; }
    [[ "$(git rev-parse HEAD)" == "$(git ls-remote origin refs/heads/main | awk '{print $1}')" ]] || { echo 'Local HEAD must match origin/main.' >&2; exit 1; }
    bash "$ROOT/scripts/validate-manifests.sh"
    applications=()
    for env in dev staging prod; do
        ref=$(kustomize build "apps/be-service/envs/$env" | yq -er 'select(.kind == "Deployment" and .metadata.name == "be-service") | .spec.template.spec.containers[0].image')
        if [[ "$env" != dev && "$ref" == ghcr.io/namnd74/be-service:sha-9912c6b ]]; then
            echo "[SKIP] $env has no promoted digest yet; run connect again after promotion"
            continue
        fi
        bash "$ROOT/scripts/verify-image.sh" "$ref" namnd74/be-service
        kubeseal --context "$CONTEXT" --validate < "apps/be-service/envs/$env/sealed-secret.yaml"
        applications+=("$ROOT/argocd/applications/be-service-$env.yaml")
    done
    for application in "${applications[@]}"; do "${K[@]}" apply -f "$application"; done
    echo '[OK] Verified environments track GitHub and auto-sync after merge. Run check after reconciliation.'
    ;;
 status)
    "${K[@]}" -n argocd get applications
    for env in dev staging prod; do "${K[@]}" -n "$env" get deployment be-service --ignore-not-found; done
    ;;
 check)
    env=${2:?Usage: demo.sh check dev|staging|prod}
    case "$env" in dev|staging|prod) ;; *) echo 'Invalid environment' >&2; exit 2 ;; esac
    cd "$ROOT"
    [[ -z "$(git status --porcelain)" ]] || { echo 'Pull the merged config into a clean checkout first.' >&2; exit 1; }
    temporary=$(mktemp -d)
    trap 'rm -rf "$temporary"' EXIT
    kustomize build "apps/be-service/envs/$env" > "$temporary/rendered.yaml"
    yq -o=json 'select(.kind == "Deployment" and .metadata.name == "be-service")' "$temporary/rendered.yaml" > "$temporary/desired.json"
    ref=$(jq -er '.spec.template.spec.containers[0].image' "$temporary/desired.json")
    [[ "${ref##*@}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'Publish and merge a real digest release first.' >&2; exit 1; }
    docker buildx imagetools inspect "$ref" --format '{{json .Image}}' > "$temporary/image.json"
    host=$(yq -er 'select(.kind == "Ingress" and .metadata.name == "be-service") | .spec.rules[0].host' "$temporary/rendered.yaml")
    "${K[@]}" -n "$env" rollout status deployment/be-service --timeout=60s
    "${K[@]}" -n argocd get application "be-service-$env" -o json > "$temporary/app.json"
    "${K[@]}" -n "$env" get deployment be-service -o json > "$temporary/deploy.json"
    "${K[@]}" -n "$env" get pods -l app=be-service -o json > "$temporary/pods.json"
    python3 - "$env" "$temporary" "$(git rev-parse HEAD)" "$host" <<'PY_CHECK'
import json,sys,pathlib
from urllib.request import urlopen
env,directory,head,host=sys.argv[1:]; directory=pathlib.Path(directory)
def read(name): return json.loads((directory/(name+'.json')).read_text())
a=read('app'); d=read('deploy'); desired=read('desired'); labels=read('image')['config']['Labels']
assert a['spec']['source']['repoURL']=='https://github.com/namnd74/gitops-manifests.git', 'Argo still uses a local mirror'
assert a['status']['sync']['status']=='Synced' and a['status']['health']['status']=='Healthy', 'Argo not Synced/Healthy'
assert a['status']['sync']['revision']==head, 'Pull the deployed config commit before checking'
ref=desired['spec']['template']['spec']['containers'][0]['image']; digest=ref.split('@')[1]
assert d['spec']['template']['spec']['containers'][0]['image']==ref, 'Deployment differs from rendered Git configuration'
pods=[p for p in read('pods')['items'] if not p['metadata'].get('deletionTimestamp')]
assert len(pods)==desired['spec']['replicas'], 'Replica count differs from desired configuration'
for pod in pods:
 assert pod['spec']['containers'][0]['image']==ref, 'Old artifact still running'
 status=pod['status']['containerStatuses'][0]
 assert status['ready'] and status['imageID'].endswith('@'+digest), 'Runtime digest or readiness differs'
with urlopen('http://'+host+'/healthz',timeout=5) as response: assert response.status==200
with urlopen('http://'+host+'/version',timeout=5) as response: v=json.load(response)
assert v['git_commit']==labels['org.opencontainers.image.revision'], 'Runtime source SHA differs from image'
assert v['version']==labels['org.opencontainers.image.version'] and v['env']==env, 'Runtime version/environment differs'
assert labels['org.opencontainers.image.source']=='https://github.com/namnd74/be-service', 'Unexpected image source'
print(f'[PASS] {env}: Git revision, Argo health, runtime digest and version match')
PY_CHECK
    ;;
esac
