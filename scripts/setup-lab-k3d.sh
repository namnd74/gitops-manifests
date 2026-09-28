#!/usr/bin/env bash
# ==============================================================================
# setup-lab-k3d.sh
# Khoi tao cum Lab K8s GitOps (k3d + Argo CD + Sealed Secrets + Ingress)
# Thu muc lam viec: /mnt/f/gitops-seminar
# ==============================================================================

set -Eeuo pipefail

C_G="\033[32m"; C_B="\033[34m"; C_Y="\033[33m"; C_R="\033[31m"; C_0="\033[0m"
ok()   { echo -e "${C_G}[OK]${C_0}   $*"; }
info() { echo -e "${C_B}[INFO]${C_0} $*"; }
warn() { echo -e "${C_Y}[WARN]${C_0} $*"; }
err()  { echo -e "${C_R}[ERR]${C_0}  $*" >&2; }

CLUSTER_NAME="gitops-demo"

echo -e "${C_B}====================================================${C_0}"
echo -e "${C_B}   KHOI TAO CUM LAB K8S GITOPS (K3D + ARGOCD)      ${C_0}"
echo -e "${C_B}====================================================${C_0}"

# 1. Kiem tra Docker
info "Kiem tra Docker daemon..."
if ! docker info >/dev/null 2>&1; then
    err "Docker daemon chua chay! Hay khoi dong: sudo service docker start"
    exit 1
fi
ok "Docker daemon dang hoat dong binh thuong."

# 2. Tao cum k3d cluster
if k3d cluster list | grep -q "$CLUSTER_NAME"; then
    info "Cum cluster k3d '$CLUSTER_NAME' da ton tai."
else
    info "Tao moi cum k3d cluster '$CLUSTER_NAME' (1 Server, 2 Agents)..."
    k3d cluster create "$CLUSTER_NAME" \
        --servers 1 \
        --agents 2 \
        --port "80:80@loadbalancer" \
        --port "443:443@loadbalancer" \
        --k3s-arg "--disable=traefik@server:0" \
        --wait
    ok "Tao k3d cluster '$CLUSTER_NAME' hoan tat."
fi

kubectl config use-context "k3d-$CLUSTER_NAME"

# 3. Tao cac Namespace
info "Tao cac Namespace: dev, staging, prod, argocd..."
for ns in dev staging prod argocd ingress-nginx; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
ok "Khoi tao Namespaces hoan tat."

# 4. Cai dat Ingress Controller
info "Cai dat Ingress Nginx Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/cloud/deploy.yaml
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=120s || true
ok "Ingress Controller da san sang."

# 5. Cai dat Bitnami Sealed Secrets Controller
info "Cai dat Bitnami Sealed Secrets Controller..."
curl -sL https://github.com/bitnami/sealed-secrets/releases/download/v0.24.5/controller.yaml | kubectl apply -f -
kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=120s || true
ok "Sealed Secrets Controller da san sang."

# 6. Cai dat Argo CD
info "Cai dat Argo CD..."
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Cau hinh Ingress cho Argo CD
cat <<EOF | kubectl apply -n argocd -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
    - host: localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
EOF

info "Cho Argo CD Server khoi dong..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s || true
ok "Argo CD da san sang."

# 7. Lay mat khau ban dau cua Argo CD
ARGO_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "admin")

# 8. Build image khoi tao & nap vao cum k3d cluster
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/../be-service" ]; then
    BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [ -d "$SCRIPT_DIR/../../be-service" ]; then
    BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
    BASE_DIR="/mnt/f/gitops-seminar"
fi

if [ -d "$BASE_DIR/gitops-manifests" ]; then
    MANIFESTS_DIR="$BASE_DIR/gitops-manifests"
else
    MANIFESTS_DIR="$BASE_DIR"
fi

BE_IMAGE="ghcr.io/namnd74/be-service:v1.0.0"

if [ -d "$BASE_DIR/be-service" ]; then
    info "Build docker image khoi tao '$BE_IMAGE' tu ma nguon local..."
    docker build -t "$BE_IMAGE" "$BASE_DIR/be-service"
    info "Nap image vao k3d cluster '$CLUSTER_NAME'..."
    k3d image import "$BE_IMAGE" -c "$CLUSTER_NAME"
    ok "Nap image '$BE_IMAGE' vao cluster hoan tat."
fi

# 9. Nap cac ung dung Argo CD
if [ -d "$MANIFESTS_DIR/argocd/applications" ]; then
    info "Nap cac ung dung vao Argo CD (Dev, Staging, Prod)..."
    kubectl apply -f "$MANIFESTS_DIR/argocd/applications/"
    ok "Nap Argo CD Applications hoan tat."
fi

echo
echo -e "${C_G}================================================================${C_0}"
echo -e "${C_G}         MOI TRUONG LAB GITOPS SAN SANG CHO SEMINAR             ${C_0}"
echo -e "${C_G}================================================================${C_0}"
echo -e "🔹 Argo CD UI      : ${C_B}http://localhost${C_0} hoac ${C_B}https://localhost${C_0}"
echo -e "🔹 Web App Demo    : ${C_B}http://localhost/app${C_0}"
echo -e "🔹 Username        : ${C_Y}admin${C_0}"
echo -e "🔹 Password        : ${C_Y}${ARGO_PWD}${C_0}"
echo -e "${C_G}================================================================${C_0}"
