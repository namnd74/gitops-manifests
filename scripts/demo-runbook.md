# Runbook seminar: hai repo, một flow GitHub → GHCR → Argo CD

`git-ops/` là workspace chứa hai Git repo độc lập: `be-service` có code Go,
Dockerfile và CI; `gitops-manifests` có base/overlay Kustomize, Applications,
workflow và Sealed Secret. Image được build, scan, ký và publish một lần ở BE.
CI mở Dev PR trong config repo; Argo triển khai sau khi PR merge. Promotion và
rollback tiếp tục đi qua PR, không rebuild image.

Argo dùng GitHub thật và GHCR thật. k3d chỉ cung cấp Kubernetes local cho lab.
Dev, Staging và Prod đều autosync/self-heal sau merge. `Synced/Healthy` là tín
hiệu cần thiết nhưng chưa đủ: rolling update lỗi có thể vẫn phục vụ pod cũ
healthy, nên `check` phải đối chiếu image, labels, `/version`, Git head và pod.

## Sáu lệnh demo

Chạy trong `gitops-manifests`:

| Lệnh | Mục đích | Thay đổi |
|---|---|---|
| `doctor` | Kiểm tra Docker, kubectl, k3d, kubeseal, gh, jq, yq v4, kustomize, cosign và đăng nhập GitHub | Chỉ đọc |
| `setup` | Dựng k3d, ingress, Sealed Secrets và Argo CD | Hạ tầng lab |
| `seal` | Kiểm tra ciphertext theo controller và seal credential lab | Secret manifest |
| `connect` | Kiểm tra config, digest Dev thật, helper verify chung, rồi validate Secret và Applications | Kết nối Argo |
| `status` | Xem Applications, Git revision và workload | Chỉ đọc |
| `check ENV` | Render manifest, đối chiếu image runtime/digest, labels OCI với `/version`, Git head, Argo health và pod digest | Chỉ đọc |

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
bash scripts/demo.sh doctor
bash scripts/demo.sh setup
bash scripts/demo.sh seal
```

Không có `sync-prod`, `cleanup-local` hay công cụ release local trong flow này.

## 1. Điều kiện và cấu hình một lần

Cần Docker Desktop, Go, Python 3, kubectl, k3d, kubeseal, git, gh, cosign,
openssl, jq, yq v4 và kustomize. Các tool đã được cài local theo đúng phiên bản dự án;
CI dùng `install-ci-tools.sh` với phiên bản pin và checksum. Đăng nhập GitHub
bằng tài khoản có quyền với hai repo:

```bash
gh auth login
bash scripts/demo.sh doctor
bash scripts/demo.sh setup
bash scripts/demo.sh seal
```

`seal` có thể tạo credential ngẫu nhiên chỉ cho lab. Dự án thật đưa credential
qua stdin vào `scripts/seal-secret.sh`, không commit plaintext. Ciphertext phụ
thuộc tên/namespace và key controller; đổi key hoặc cluster thì seal lại.

Thiết lập owner/repository trong Applications, image allowlist, provenance và
Cosign identity nếu đổi owner khỏi `namnd74`. Bật Actions. Cấu hình credential
đọc repo cho Argo nếu repo private và imagePullSecret nếu GHCR private. Bật
branch protection, CODEOWNERS và required validation cho mọi PR. Đặt
`CONFIG_REPO_PAT` trong Secrets của cả hai repo, với contents/pull_requests
trên config repo và quyền đọc packages/provenance BE; workflow không fallback
sang `GITHUB_TOKEN`.

BE dùng `IMAGE_ARCH=arm64` cho Apple Silicon, `amd64` cho cluster x86. Mọi
môi trường seminar phải dùng cùng kiến trúc và cùng digest.

Bootstrap hiện có tag `sha-9912c6b`; đây là tag trong manifest có sẵn, chưa phải
artifact đã xác minh. Remote/live acceptance chưa được thực hiện.

## 2. Đưa cấu hình lên main rồi phát hành Dev

Đưa các script dùng chung, tool pin và cấu hình lên config qua branch/PR trước.
Review và merge PR vào config `main`, không commit `.demo/`, cache hoặc credential:

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
bash scripts/validate-manifests.sh
git diff --check
git switch -c prepare-gitops-demo
git add .
git commit -m "chore: prepare GitOps demo flow"
git push -u origin prepare-gitops-demo
gh pr create --base main --head prepare-gitops-demo
```

Sau đó tạo branch/PR cho thay đổi BE. Sau khi PR BE được review và merge vào
`main`, pipeline phát hành mới chạy:

```bash
cd /Volumes/MacOs/workspaces/git-ops/be-service
bash scripts/check-quality.sh
python3 -m unittest discover -s scripts/tests -v
git diff --check
git switch -c demo-release
git add .
git commit -m "ci: publish scanned image for GitOps demo"
git push -u origin demo-release
gh pr create --base main --head demo-release
# review/merge PR rồi theo dõi pipeline main
gh run list --workflow ci.yaml --limit 3
```

CI build một image, scan đúng image đó, publish digest rồi tạo SBOM/provenance
và chữ ký cho cùng digest, rồi mở Dev PR. Sau khi review và merge PR:

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
git pull --ff-only origin main
bash scripts/demo.sh connect
bash scripts/demo.sh status
bash scripts/demo.sh check dev
```

`connect` xác thực working tree và Git head, kiểm tra image và ciphertext
cho từng môi trường có digest trước khi apply bất kỳ Application nào.
Staging/Prod còn tag bootstrap được bỏ qua; chạy lại `connect` sau khi merge
promotion đầu tiên để tạo Application tương ứng. Chờ
Argo reconcile; `check` phải xác minh deployment đang dùng đúng digest,
OCI version/revision khớp `/version`, Argo Git head và pod digest.

## 3. Demo release và security gate

Cho người xem đối chiếu CI run, image digest, Trivy report, SBOM, attestation và
Cosign signature. Dùng helper trong config repo:

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
scripts/verify-image.sh ghcr.io/OWNER/be-service@sha256:DIGEST OWNER/be-service
```

Gate phải kiểm tra source SHA của `main`, workflow identity và provenance đúng
repo; image chưa đạt thì không có Dev PR hợp lệ. `release.json` chỉ nằm trong
artifact CI cùng report, không được copy vào overlay.

## 4. Promotion cùng artifact

Chỉ dùng hai cặp `dev -> staging` và `staging -> prod`. Workflow đọc digest từ
môi trường nguồn, kiểm tra provenance/signature và mở PR với cùng digest; nó
chặn môi trường không hỗ trợ, digest thay đổi hoặc config fault. Workflow không
tự đọc health cluster local, nên reviewer chạy `check` và smoke test trước khi
merge.

```bash
gh workflow run promote.yaml --repo namnd74/gitops-manifests -f from=dev -f to=staging
# review/merge PR, rồi pull main
bash scripts/demo.sh check staging
gh workflow run promote.yaml --repo namnd74/gitops-manifests -f from=staging -f to=prod
```

Sau khi merge PR Prod, Argo tự sync và self-heal; không chạy lệnh sync riêng.

## 5. Demo Secret và drift

Secret được seal bằng key của controller, giữ ciphertext trong Git và không
được sửa bởi promotion/rollback. Trình bày `seal`, `connect`, Application
status và workload đã nhận Secret mà không in giá trị secret.

Để demo drift trong lab, scale Deployment thủ công rồi xem Argo self-heal đưa
resource về rendered Git state:

```bash
kubectl --context k3d-gitops-demo -n dev scale deployment/be-service --replicas=2
```

Chạy `status` và `check` sau khi reconcile; đừng coi
`Synced/Healthy` riêng lẻ là bằng chứng image runtime đã đúng.

## 6. Demo fault và rollback qua Git

Lưu một revision config tốt sau refactor, trước khi tạo fault (revision bootstrap
cũ không phải artifact rollback hợp lệ):

```bash
GOOD_CONFIG_SHA=$(git rev-parse HEAD)
```

Tạo fault bền vững trên branch/PR Dev bằng yq:

```bash
yq -i '(.spec.template.spec.containers[0].env[] | select(.name == "DEMO_FAULT").value) = "true"' apps/be-service/envs/dev/deployment-env-patch.yaml
```

Review và merge PR để Argo rollout. Fault này giữ nguyên image đã ký;
pod cũ có thể vẫn trả HTTP 200 trong lúc rolling update lỗi, vì vậy quan sát
pod mới, Events, Argo và `check`, không dùng URL 200 đơn độc.

Rollback mở PR phục hồi image và env patch từ revision tốt, để nguyên Sealed
Secret:

```bash
gh workflow run rollback.yaml --repo namnd74/gitops-manifests \
  -f env=dev -f revision="$GOOD_CONFIG_SHA"
```

Review/merge PR, pull `main`, chờ Argo rồi chạy `bash scripts/demo.sh check dev`.
Rollback Prod dùng `env=prod` và vẫn tự reconcile sau merge. Đây là rollback
config/image reference. Muốn demo rollback một image lỗi, phát hành một BE
commit có lỗi runtime qua cùng CI gates, rồi rollback config về digest trước.

## Appendix: migration và production

Giữ các container `.demo/` hiện có trong migration; không tự động xóa Git
server, registry local, cluster hay backup. Chỉ dọn thủ công sau khi đã lưu
evidence và xác nhận lab cũ không còn cần chúng.

Production cần branch protection, CODEOWNERS, bot token tối thiểu, Argo SSO/RBAC,
AppProject giới hạn nguồn/đích, TLS và network isolation, HA, monitoring với SLO
và smoke test, secret rotation, key backup kèm diễn tập restore, registry
retention/recovery và quy trình DB migration. Đây là yêu cầu vận hành cần bổ
sung theo môi trường; không thêm stack mới vào seminar.
