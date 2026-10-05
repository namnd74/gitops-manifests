#!/usr/bin/env bash
# Validate rendered configuration without a cluster or an application runtime.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${IMAGE:-ghcr.io/namnd74/be-service}
for tool in kustomize yq jq; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }; done
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
for environment in dev staging prod; do
  kustomize build "$ROOT/apps/be-service/envs/$environment" > "$temporary/rendered.yaml"
  if ! yq -o=json '.' "$temporary/rendered.yaml" | jq -se --arg env "$environment" --arg image "$IMAGE" '
    map(select(. != null)) as $objects |
    [$objects[] | select(.kind == "Deployment" and .metadata.name == "be-service")] as $deployments |
    [$objects[] | select(.kind == "SealedSecret" and .metadata.name == "be-service-secret")] as $secrets |
    $deployments[0] as $d | $secrets[0] as $s |
    $d.spec.template.spec.containers as $containers |
    $containers[0] as $c | ($c.env // []) as $envs |
    ($envs | map({key: .name, value: .}) | from_entries) as $values |
    ($s.spec.encryptedData.DB_PASSWORD // "") as $ciphertext |
    ([$objects[] | select(.kind == "Secret")] | length == 0) and
    ($deployments | length == 1) and ($secrets | length == 1) and
    ($d.metadata.namespace == $env) and ($s.metadata.namespace == $env) and
    ($s.spec.template.metadata.name == "be-service-secret") and
    ($s.spec.template.metadata.namespace == $env) and
    ($d.spec.replicas == ({dev: 1, staging: 2, prod: 3}[$env])) and
    ($containers | length == 1) and ($c.name == "app") and
    (($c.image == ($image + ":sha-9912c6b")) or
      (($c.image | startswith($image + "@")) and ($c.image | test("@sha256:[0-9a-f]{64}$")))) and
    ($envs | length == (unique_by(.name) | length)) and
    ($values.APP_ENV.value == $env) and
    ($values.DEMO_MODE.value == (if $env == "dev" then "true" else "false" end)) and
    ($values.DEMO_FAULT.value == "false" or
      ($env == "dev" and $values.DEMO_FAULT.value == "true")) and
    ($values.DB_PASSWORD.value == null) and
    ($values.DB_PASSWORD.valueFrom.secretKeyRef ==
      {name: "be-service-secret", key: "DB_PASSWORD", optional: false}) and
    ($ciphertext | length > 64) and ($ciphertext | test("^[A-Za-z0-9+/]+={0,2}$"))
  ' >/dev/null; then
    echo "Invalid rendered configuration: $environment" >&2
    exit 1
  fi
  echo "[PASS] $environment rendered configuration"
done
