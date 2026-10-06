#!/usr/bin/env bash
# Validate rendered configuration without a cluster or an application runtime.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${IMAGE:-ghcr.io/example/be-service}
for tool in kustomize yq jq; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }; done
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
for environment in dev staging prod; do
  kustomize build "$ROOT/apps/be-service/envs/$environment" > "$temporary/rendered.yaml"
  if ! yq -o=json '.' "$temporary/rendered.yaml" | jq -se --arg env "$environment" --arg image "$IMAGE" '
    map(select(. != null)) as $objects |
    [$objects[] | select(.kind == "Deployment" and .metadata.name == "be-service")] as $deployments |
    $deployments[0] as $d |
    $d.spec.template.spec.containers as $containers |
    $containers[0] as $c | ($c.env // []) as $envs |
    [$objects[] | select(.kind == "ConfigMap")] as $configs |
    $configs[0] as $config |
    ($envs | map({key: .name, value: .}) | from_entries) as $values |
    ([$objects[] | select(.kind == "Secret" or .kind == "SealedSecret")] | length == 0) and
    ($deployments | length == 1) and
    ($d.metadata.namespace == $env) and
    ($d.spec.strategy.type == "RollingUpdate") and
    ($d.spec.strategy.rollingUpdate.maxUnavailable == 0) and
    ($d.spec.strategy.rollingUpdate.maxSurge == 1) and
    ($c.livenessProbe.httpGet == {path:"/healthz",port:8080}) and
    (($c.readinessProbe.httpGet == {path:"/healthz",port:8080}) or
      ($env == "prod" and $d.metadata.annotations["seminar.gitops.io/scenario"] == "prod-readiness-failure" and
       $c.readinessProbe.httpGet == {path:"/healthz",port:8081})) and
    ($d.spec.replicas == ({dev: 1, staging: 2, prod: 3}[$env])) and
    ($containers | length == 1) and ($c.name == "app") and
    (($c.image == "ghcr.io/example/be-service:bootstrap") or
      (($c.image | startswith($image + "@")) and ($c.image | test("@sha256:[0-9a-f]{64}$")))) and
    ($envs | length == (unique_by(.name) | length)) and
    ($configs | length == 1) and
    ($config.metadata.namespace == $env) and
    ($c.envFrom == [{configMapRef:{name:$config.metadata.name}}]) and
    ($config.data | keys == ["APP_ENV","DEMO_FAULT","DEMO_MODE","PORT"]) and
    ($envs | map(.name) == ["DB_PASSWORD"]) and
    ($config.data.PORT == "8080") and
    ($config.data.APP_ENV == $env) and
    ($config.data.DEMO_MODE == (if $env == "dev" then "true" else "false" end)) and
    ($config.data.DEMO_FAULT == "false" or
      ($env == "dev" and $config.data.DEMO_FAULT == "true")) and
    ($values.DB_PASSWORD.value == null) and
    ($values.DB_PASSWORD.valueFrom.secretKeyRef ==
      {name: "be-service-secret", key: "DB_PASSWORD", optional: false})
  ' >/dev/null; then
    echo "Invalid rendered configuration: $environment" >&2
    exit 1
  fi
  echo "[PASS] $environment rendered configuration"
done
