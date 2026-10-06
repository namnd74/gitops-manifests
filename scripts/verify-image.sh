#!/usr/bin/env bash
# Verify immutable artifact identity before accepting a hosted release PR on main.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 IMAGE@sha256:DIGEST OWNER/REPO" >&2; exit 2; }
REF=$1
SOURCE_REPO=$2
[[ "$SOURCE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 2
IMAGE_REPO=$(printf '%s' "$SOURCE_REPO" | tr '[:upper:]' '[:lower:]')
[[ "$REF" == "ghcr.io/$IMAGE_REPO@sha256:"* && "${REF##*@}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo 'Expected an immutable GHCR digest belonging to the source repository' >&2; exit 1;
}
for tool in docker jq gh cosign; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }; done
config=$(docker buildx imagetools inspect "$REF" --format '{{json .Image}}')
source_sha=$(jq -er '.config.Labels["org.opencontainers.image.revision"]' <<< "$config")
version=$(jq -er '.config.Labels["org.opencontainers.image.version"]' <<< "$config")
source=$(jq -er '.config.Labels["org.opencontainers.image.source"]' <<< "$config")
[[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.-]+)?$ && "$source" == "https://github.com/$SOURCE_REPO" ]] || {
  echo 'Missing or invalid OCI source/version/revision labels' >&2; exit 1;
}
gh attestation verify "oci://$REF" --repo "$SOURCE_REPO" \
  --signer-workflow "$SOURCE_REPO/.github/workflows/ci.yaml" \
  --source-digest "$source_sha" --source-ref refs/heads/main \
  --cert-oidc-issuer https://token.actions.githubusercontent.com
cosign verify --certificate-identity "https://github.com/$SOURCE_REPO/.github/workflows/ci.yaml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com "$REF"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'image_ref=%s\nsource_sha=%s\nversion=%s\n' "$REF" "$source_sha" "$version" >> "$GITHUB_OUTPUT"
fi
