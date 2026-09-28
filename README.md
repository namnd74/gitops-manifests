# GitOps Manifests Repository (`gitops-manifests`)

Kho cấu hình hạ tầng và ứng dụng Kubernetes chuẩn GitOps dành cho đội ngũ DevOps / SRE.

## 1. Cấu trúc thư mục
- `apps/be-service/base/`: Khung mẫu chung (Deployment, Service, Ingress, Kustomize)
- `apps/be-service/envs/dev/`: Môi trường Dev (Auto-sync từ CI)
- `apps/be-service/envs/staging/`: Môi trường Staging (Thăng hạng qua Pull Request)
- `apps/be-service/envs/prod/`: Môi trường Prod (Manual sync approval)
- `argocd/applications/`: Cấu hình Application cho Argo CD

## 2. Quản lý Secret
Mật khẩu được mã hóa bất đối xứng bằng **Bitnami Sealed Secrets** (`sealed-secret.yaml`), an toàn tuyệt đối khi commit công khai lên Git.
