# Runbook: GitHub → GHCR → ba nhánh GitOps → Argo CD

Workspace chứa `be-service` và `gitops-manifests`, hai repo độc lập. BE build
một image từ main, scan HIGH/CRITICAL (fixed và unfixed), publish digest, tạo
SBOM/provenance và ký Cosign. Artifact CI được giữ trong Actions, không copy
release.json vào manifest. Config repo quản lý ba branch môi trường.

| Môi trường | Nhánh Argo theo dõi | Overlay | Replica |
|---|---|---|---|
| Dev | dev | apps/be-service/envs/dev | 1 |
| Staging | staging | apps/be-service/envs/staging | 2 |
| Prod | prod | apps/be-service/envs/prod | 3 |

Digest chung nằm ở `apps/be-service/base/kustomization.yaml` trên mỗi nhánh.
Mỗi nhánh có thể đang giữ digest khác nhau trong lúc promotion. Env patch,
Ingress, Application và ciphertext được khởi tạo giống nhau giữa các nhánh;
Argo chọn đúng overlay để namespace/replicas/host/secret của môi trường.

## Bootstrap và credential

Đọc [hướng dẫn từng bước](rebuild-step-by-step.md). Merge cấu hình mới vào
config main trước, sau đó tạo ba remote branch từ cùng commit đó. BE CI chỉ
chạy phát hành trên BE main; config main không được Argo dùng cho workload.

Cần CONFIG_REPO_PAT trong cả hai repo, có quyền mở PR/cập nhật config và đọc
packages/provenance. Workflow không fallback sang GITHUB_TOKEN. Token classic
`public_repo` + `read:packages` phục vụ lab public. Push file workflow từ CLI
cần quyền `workflow` riêng. IMAGE_ARCH=arm64 cho lab Apple Silicon; mọi môi
trường dùng cùng kiến trúc. Repo/image private cần Argo credential và
imagePullSecret. Bật branch protection và required validate cho cả ba nhánh.

## Release Dev

Review/merge PR BE vào main. CI tự mở `release-be-service-dev → dev`, chỉ sửa
image chung ở base. Review digest, scan, provenance/chữ ký và merge PR. Sau đó:

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
bash scripts/demo.sh connect
bash scripts/demo.sh status
bash scripts/demo.sh check dev
```

connect fetch và archive từng remote branch, kiểm tra manifest, image và
ciphertext trước khi apply bất kỳ Application nào. Dev chưa có digest sẽ
bị chặn; Staging/Prod còn tag bootstrap được bỏ qua. check so sánh deployment,
pod digest/replica, OCI metadata với /version, Argo health và HEAD remote của
đúng nhánh. HTTP 200 riêng lẻ không chứng minh rollout đạt.

## Demo merge release

Khi Dev đã check PASS:

```bash
gh workflow run promote.yaml --repo namnd74/gitops-manifests --ref main -f from=dev -f to=staging
gh pr list --repo namnd74/gitops-manifests --base staging --head dev
```

Workflow xác minh digest và chặn nguồn fault, thay đổi env/ciphertext giữa
nhánh. Nó mở PR trực tiếp `dev → staging`, không tạo bản copy image. Review
và dùng **Create a merge commit** (không squash/rebase) để giữ quan hệ nhánh.
Repo đã tắt squash/rebase merge và chỉ cho phép merge commit. Required
validation kiểm tra cặp nhánh, env/ciphertext và chữ ký/provenance.
Nếu có conflict, hòa giải trên branch nguồn và kiểm tra lại trước khi merge.

Sau merge:

```bash
bash scripts/demo.sh connect
bash scripts/demo.sh check staging
gh workflow run promote.yaml --repo namnd74/gitops-manifests --ref main -f from=staging -f to=prod
# Review/merge PR staging → prod bằng merge commit:
bash scripts/demo.sh connect
bash scripts/demo.sh check prod
```

Không rebuild image khi promotion. Cùng digest chạy lần lượt Dev/Staging/Prod,
nhưng Argo Git revision khác nhau do merge commit của mỗi nhánh. Autosync và
self-heal bật ở cả ba môi trường. Không cần lệnh sync Prod riêng.

## Fault, drift và rollback

Lưu revision tốt của nhánh tương ứng, ví dụ Dev:

```bash
git fetch origin dev
GOOD_CONFIG_SHA=$(git rev-parse origin/dev)
```

Tạo branch `fault-dev` từ config dev; sửa DEMO_FAULT=true chỉ trong env patch Dev,
mở PR vào dev. Required validation vẫn xác minh image đã ký. Sau merge pod
mới thất bại readiness; pod cũ có thể tiếp tục HTTP 200. check không chấp nhận
pod cũ hoặc digest/replica sai. Không promotion nguồn fault.

Rollback:

```bash
gh workflow run rollback.yaml --repo namnd74/gitops-manifests --ref main -f env=dev -f revision="$GOOD_CONFIG_SHA"
```

Workflow checkout dev và mở `rollback-dev → dev`, phục hồi image chung và
patch Dev từ revision tốt, giữ ciphertext và các cấu hình base khác. Staging
và Prod rollback vào nhánh tương ứng. Sau review/merge, chạy check môi trường.
Nếu rollback làm nhánh đích diverge với upstream, hòa giải image trên nguồn
trước release tiếp theo; không dùng force push.

Drift trong lab:

```bash
kubectl --context k3d-gitops-demo -n dev scale deployment/be-service --replicas=2
bash scripts/demo.sh status
bash scripts/demo.sh check dev
```

Chờ Argo self-heal đưa replica về Git. Rotation key/credential cần seal lại
và đồng bộ env/ciphertext có chủ đích giữa ba nhánh trước promotion; gate chặn
thay đổi môi trường đi kèm PR release. Không commit plaintext hoặc token.

## Vận hành

Giữ dữ liệu .demo/ cũ trong migration. Production cần branch protection,
review bắt buộc, quyền token tối thiểu, SSO/RBAC, AppProject, TLS/network
isolation, HA/monitoring/smoke tests, secret/key backup và diễn tập restore,
registry retention/recovery và DB migration theo môi trường.
