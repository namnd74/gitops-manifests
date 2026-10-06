#!/usr/bin/env bash
# CI only: pinned binaries; local lab users install the same CLI tools normally.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tool-versions.env
# shellcheck source=tool-versions.env
source "$SCRIPT_DIR/tool-versions.env"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'CI tools require Linux amd64' >&2; exit 1; }
: "${RUNNER_TEMP:?GitHub Actions runner required}" "${GITHUB_PATH:?GitHub Actions path required}"
tools=$(mktemp -d "$RUNNER_TEMP/gitops-tools.XXXXXX")
curl -fsSL --retry 3 "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$KUSTOMIZE_VERSION/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" -o "$tools/kustomize.tar.gz"
curl -fsSL --retry 3 "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_amd64" -o "$tools/yq"
printf '%s  %s\n' "$KUSTOMIZE_LINUX_AMD64_SHA256" "$tools/kustomize.tar.gz" "$YQ_LINUX_AMD64_SHA256" "$tools/yq" | sha256sum --check
tar -xzf "$tools/kustomize.tar.gz" -C "$tools" kustomize
chmod +x "$tools/kustomize" "$tools/yq"
echo "$tools" >> "$GITHUB_PATH"
