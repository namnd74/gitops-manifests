#!/usr/bin/env bash
set -Eeuo pipefail
environment="${1:?Usage: seal-secret.sh ENV CERT_PATH (password on stdin)}"
certificate="${2:?Certificate path required}"
case "$environment" in dev|staging|prod) ;; *) echo 'Invalid environment' >&2; exit 2 ;; esac
[[ -s "$certificate" ]] || { echo 'Missing controller certificate' >&2; exit 1; }
python3 -c 'import base64,json,sys; password=sys.stdin.read().strip(); assert password, "Empty password"; print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"be-service-secret","namespace":sys.argv[1]},"type":"Opaque","data":{"DB_PASSWORD":base64.b64encode(password.encode()).decode()}}))' "$environment" \
    | kubeseal --cert "$certificate" --scope strict --format yaml
