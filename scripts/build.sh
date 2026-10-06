#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -le 1 ]] || { echo "Usage: bash scripts/build.sh [dev|stg|prod]" >&2; exit 2; }
for option in "$@"; do
    case "$option" in
        --help|-h) echo 'Usage: bash scripts/build.sh [dev|stg|prod]'; exit 0 ;;
        dev|stg|prod) ;;
        *) echo "Unknown option: $option" >&2; exit 2 ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-common.sh
source "$SCRIPT_DIR/local-common.sh"
init_local
branch=${1:-dev}
# Bootstrap/manual CI trigger only. Normal releases start by merging a backend PR.
require_tools gh docker
for repository in "$SOURCE_REPO" "$CONFIG_REPO"; do
    secrets=$(gh secret list --repo "$repository" --json name)
    jq -e 'any(.[]; .name == "CONFIG_REPO_PAT")' <<< "$secrets" >/dev/null || \
        fail "Missing CONFIG_REPO_PAT in $repository; set it through GitHub Secrets"
done
case "$(docker info --format '{{.Architecture}}')" in
    arm64|aarch64) architecture=arm64 ;;
    amd64|x86_64) architecture=amd64 ;;
    *) fail 'Unsupported Docker architecture' ;;
esac
image="ghcr.io/$(printf '%s' "$SOURCE_REPO" | tr '[:upper:]' '[:lower:]')"
gh variable set CONFIG_REPO --repo "$SOURCE_REPO" --body "$CONFIG_REPO"
gh variable set IMAGE_ARCH --repo "$SOURCE_REPO" --body "$architecture"
gh variable set ENABLE_GITOPS_RELEASE --repo "$SOURCE_REPO" --body true
gh variable set SOURCE_REPO --repo "$CONFIG_REPO" --body "$SOURCE_REPO"
gh variable set IMAGE --repo "$CONFIG_REPO" --body "$image"
gh workflow run ci.yaml --repo "$SOURCE_REPO" --ref "$branch"
echo "[OK] CI requested on backend $branch. Review/merge its manifest PR when checks pass."
