#!/usr/bin/env bash
set -Eeuo pipefail
for option in "$@"; do
    case "$option" in
        --help|-h) echo 'Usage: bash scripts/check.sh'; exit 0 ;;
        *) echo "Unknown option: $option" >&2; exit 2 ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-common.sh
source "$SCRIPT_DIR/local-common.sh"
init_local
# Read the release from GitHub main and verify all three environments match it.
require_tools kubectl curl kustomize yq docker gh
snapshot=$(mktemp -d)
trap 'rm -rf "$snapshot"' EXIT
GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    clone --quiet --depth 1 --branch main "$CONFIG_REPO_URL" "$snapshot/source"
revision=$(git -C "$snapshot/source" rev-parse HEAD)
manifest=$(kustomize build "$snapshot/source/apps/be-service/envs/dev")
image=$(yq -er 'select(.kind == "Deployment" and .metadata.name == "be-service") | .spec.template.spec.containers[0].image' <<< "$manifest")
[[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || fail 'GitHub main has no immutable release image yet; wait for CI and merge the manifest PR'
digest=${image##*@}
labels=$(docker buildx imagetools inspect "$image" --format '{{json .Image}}')
version=$(jq -er '.config.Labels["org.opencontainers.image.version"]' <<< "$labels")
source_sha=$(jq -er '.config.Labels["org.opencontainers.image.revision"]' <<< "$labels")
replicas=0
for environment in dev staging prod; do
    replicas=$((replicas+1)); deadline=$((SECONDS+300))
    k -n argocd annotate application "be-service-$environment" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    while :; do
        app=$(k -n argocd get application "be-service-$environment" -o json)
        if jq -e --arg revision "$revision" '
            .status.sync.status == "Synced" and .status.sync.revision == $revision and
            .status.health.status == "Healthy"' <<< "$app" >/dev/null; then break; fi
        ((SECONDS < deadline)) || fail "$environment: Argo reconciliation timeout; inspect Application conditions"
        sleep 3
    done
    jq -e --arg env "$environment" --arg repo "$CONFIG_REPO_URL" '
        .spec.source == {repoURL:$repo,targetRevision:"main",path:("apps/be-service/envs/"+$env)} and
        .spec.destination.namespace == $env' <<< "$app" >/dev/null || fail "$environment: wrong Argo source/namespace"
    deployment=$(k -n "$environment" get deployment be-service -o json)
    jq -e --argjson replicas "$replicas" --arg image "$image" '
        .spec.replicas == $replicas and .spec.template.spec.containers[0].image == $image
        ' <<< "$deployment" >/dev/null || fail "$environment: wrong desired image/replicas"
    pods=$(k -n "$environment" get pods -l app=be-service -o json)
    ready=$(jq -ce '[.items[] | select(.metadata.deletionTimestamp == null)]' <<< "$pods")
    jq -e --argjson replicas "$replicas" --arg image "$image" '
        length == $replicas and all(.[]; .status.containerStatuses[0].ready == true and
            .spec.containers[0].image == $image)' <<< "$ready" >/dev/null || fail "$environment: wrong pod readiness/replica count"
    while IFS= read -r pod; do
        node=$(jq -r '.spec.nodeName' <<< "$pod")
        identity=$(jq -er '.status.containerStatuses[0].imageID | capture("(?<id>sha256:[0-9a-f]{64})$").id' <<< "$pod")
        runtime=$(docker exec "$node" crictl inspecti -o json "$image")
        jq -e --arg id "$identity" --arg digest "$digest" '
            [.status.id, .status.repoDigests[]?] | map(capture("(?<id>sha256:[0-9a-f]{64})$").id) |
            index($id) != null and index($digest) != null' <<< "$runtime" >/dev/null || fail "$environment: runtime image content mismatch"
    done < <(jq -c '.[]' <<< "$ready")
    host="$environment.127.0.0.1.nip.io"
    curl -fsS --max-time 10 -H "Host: $host" "http://127.0.0.1:$HTTP_PORT/healthz" >/dev/null
    response=$(curl -fsS --max-time 10 -H "Host: $host" "http://127.0.0.1:$HTTP_PORT/version")
    jq -e --arg env "$environment" --arg version "$version" --arg sha "$source_sha" '
        .env == $env and .version == $version and .git_commit == $sha
        ' <<< "$response" >/dev/null || fail "$environment: wrong HTTP version/commit"
    echo "[PASS] $environment: GitHub main, Argo health, runtime image, $replicas replicas, version $version"
done
jq -n --arg image "$image" --arg revision "$revision" --arg source_sha "$source_sha" --arg version "$version" \
    '$ARGS.named' | write_state release.json
echo "Argo CD: http://localhost:$HTTP_PORT/ (admin)"
