#!/usr/bin/env bash
set -Eeuo pipefail
for option in "$@"; do
    case "$option" in
        --help|-h) echo 'Usage: bash scripts/build.sh'; exit 0 ;;
        *) echo "Unknown option: $option" >&2; exit 2 ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-common.sh
source "$SCRIPT_DIR/local-common.sh"
init_local
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
gh workflow run ci.yaml --repo "$SOURCE_REPO" --ref main
echo '[OK] CI requested on backend main. Wait for CI, review/merge the generated manifest PR, then run check.sh.'
