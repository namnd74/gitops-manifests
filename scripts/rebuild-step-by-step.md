# Dựng lại và demo merge release qua ba nhánh

Cập nhật 06/10/2026, giờ Việt Nam. Workspace `/Volumes/MacOs/workspaces/git-ops`.

Luồng: BE main → CI scan/publish/ký digest → PR config dev → merge dev vào
staging → merge staging vào prod. Ba nhánh thuộc repo gitops-manifests;
backend giữ main để build một lần. Argo theo dõi nhánh cùng tên môi trường.

## 1. Docker và công cụ

```bash
open /Applications/Docker.app
docker info --format '{{.ServerVersion}}'
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
brew install yq cosign
```

Chờ Docker engine chạy trước khi setup. Nếu Docker hoạt động nhưng Codex
sandbox không truy cập được socket, thao tác Docker cần chạy ngoài sandbox.
Không reset Docker hoặc xóa dữ liệu để chữa lỗi quyền.

## 2. Đăng nhập và cấp quyền GitHub

```bash
gh auth login --hostname github.com --web
gh auth refresh --hostname github.com --scopes workflow
gh auth status
```

Chọn HTTPS nếu hỏi; nhấn Enter để mở trình duyệt, nhập mã từ Terminal tại
https://github.com/login/device rồi Authorize GitHub CLI. Đăng nhập namnd74.
Scope workflow cần để push các file CI. Credential HTTPS/SSH cũ trên máy
đang thuộc namkma99, nên dùng credential của CLI trong các lệnh push bên dưới.

Tạo PAT classic ở https://github.com/settings/tokens/new: đặt tên gitops-demo,
thời hạn 30 ngày, chọn public_repo và read:packages cho hai repo public của lab.
Copy token và nhập tại prompt Terminal (không gửi vào chat/câu lệnh/Git):

```bash
gh secret set CONFIG_REPO_PAT --repo namnd74/gitops-manifests
# Nếu token BE cũ không còn hợp lệ, đặt cùng token mới ở repo BE:
gh secret set CONFIG_REPO_PAT --repo namnd74/be-service
gh secret list --repo namnd74/gitops-manifests
gh secret list --repo namnd74/be-service
```

GitHub chỉ hiển thị token mới một lần, không đọc lại được giá trị secret đã lưu.
Token Actions và credential CLI là hai việc riêng. Nếu repo private, điều
chỉnh quyền và cấu hình Argo credential/imagePullSecret.

## 3. Dựng hạ tầng và seal credential

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
bash scripts/demo.sh doctor
bash scripts/demo.sh setup
bash scripts/demo.sh seal
bash scripts/validate-manifests.sh
kubectl --context k3d-gitops-demo get nodes
kubectl --context k3d-gitops-demo get pods -A
```

Setup tạo k3d một server/hai agent, ingress, Sealed Secrets và Argo CD; phiên
bản pin trong scripts/tool-versions.env. Chờ rollout thành công. Nếu cluster
cũ đang dừng, k3d cluster start gitops-demo trước khi setup. Không xóa cluster
vì sẽ mất key controller; seal lại khi key đổi. Giữ .demo/ migration.

## 4. Argo CD

Mở http://localhost, tài khoản admin. Lấy mật khẩu trong Terminal cá nhân:

```bash
kubectl --context k3d-gitops-demo -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode
```

Không lưu mật khẩu vào log. Nếu ingress không truy cập được, dùng Terminal
riêng chạy port-forward rồi mở https://localhost:8080:

```bash
kubectl --context k3d-gitops-demo -n argocd port-forward svc/argocd-server 8080:443
```

## 5. Đưa cấu hình bootstrap lên GitHub

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
bash scripts/validate-manifests.sh
python3 -m unittest discover -s scripts/tests -v
actionlint
git diff --check
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin seminar/demo-ready
```

Tạo PR seminar/demo-ready vào config main, review/merge bằng merge commit.
Ciphertext lab được commit, plaintext/token/cache/.demo không được commit.
Để làm bước tạo branch tiếp theo, main remote phải chứa cấu hình mới này.

## 6. Bootstrap ba nhánh remote

Chỉ khi chưa tồn tại remote dev/staging/prod và config PR đã merge:

```bash
git fetch origin main
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin origin/main:refs/heads/dev origin/main:refs/heads/staging origin/main:refs/heads/prod
```

Repo GitOps đã đặt allow_merge_commit=true, allow_squash_merge=false và
allow_rebase_merge=false để giữ lịch sử promotion.

Ba nhánh bắt đầu cùng cấu hình (tag bootstrap chưa phải release). Không force
push nếu nhánh đã có. Branch local được chuẩn bị để review; khi remote mới
được bootstrap, fetch rồi fast-forward local tương ứng nếu cần. Bật required
validate và review trên dev/staging/prod. Chọn merge commit cho promotion.

## 7. Merge backend và release Dev

```bash
cd /Volumes/MacOs/workspaces/git-ops/be-service
GOCACHE=/private/tmp/gitops-go-build bash scripts/check-quality.sh
python3 -m unittest discover -s scripts/tests -v
actionlint
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin seminar/demo-ready
```

Tạo PR vào BE main, review/merge. IMAGE_ARCH=arm64 cho máy Apple Silicon.
CI build/scan/publish/attest/ký một digest, rồi mở release-be-service-dev vào
config dev. PR chỉ cập nhật apps/be-service/base/kustomization.yaml trên dev.
Review CI evidence và merge Dev PR:

```bash
gh run list --repo namnd74/be-service --workflow ci.yaml --limit 3
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
bash scripts/demo.sh connect
kubectl --context k3d-gitops-demo -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/be-service-dev --timeout=60s
bash scripts/demo.sh check dev
```

connect/check fetch từng remote branch và kiểm tra snapshot đó, không yêu cầu
checkout local cùng một main. Working tree vẫn phải sạch để tránh bỏ sót thay
đổi chưa publish. Staging/Prod bootstrap chưa được connect đến workload.

## 8. Demo merge dev → staging → prod

```bash
gh workflow run promote.yaml --repo namnd74/gitops-manifests --ref main -f from=dev -f to=staging
gh pr list --repo namnd74/gitops-manifests --base staging --head dev
```

Review PR rồi Create a merge commit. Sau merge:

```bash
bash scripts/demo.sh connect
kubectl --context k3d-gitops-demo -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/be-service-staging --timeout=60s
bash scripts/demo.sh check staging
gh workflow run promote.yaml --repo namnd74/gitops-manifests --ref main -f from=staging -f to=prod
# Review/merge PR staging → prod:
bash scripts/demo.sh connect
kubectl --context k3d-gitops-demo -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/be-service-prod --timeout=60s
bash scripts/demo.sh check prod
```

Workflow và required PR validation chặn cặp nhánh sai, nguồn fault, thay đổi
cấu hình môi trường/ciphertext và image chưa xác minh. Promotion không rebuild.
URL: http://dev.127.0.0.1.nip.io, http://staging.127.0.0.1.nip.io,
http://prod.127.0.0.1.nip.io. Mỗi workload chạy replica 1/2/3 tương ứng.

## 9. Evidence và rollback

check từng môi trường phải PASS: đúng nhánh/revision Argo, Synced/Healthy,
image digest, replica/pod readiness, OCI source/version và /version HTTP.
Lưu revision tốt theo nhánh. Fault, drift và rollback qua PR được mô tả trong
[runbook](demo-runbook.md).

Pod có thể rollout xong trước khi Argo cập nhật Healthy (đã gặp ở Staging).
Nếu check báo Argo chưa Healthy, xem Application/Ingress/Deployment, chờ
reconciliation rồi chạy lại check; không promote khi acceptance chưa PASS.

Nếu Docker Desktop credential helper làm `imagetools inspect` đứng khi đọc
image public, dùng config tạm không chứa credential, có đường dẫn plugin:

```bash
mkdir -p /private/tmp/gitops-docker-public
cat > /private/tmp/gitops-docker-public/config.json <<'JSON'
{"cliPluginsExtraDirs":["/Applications/Docker.app/Contents/Resources/cli-plugins"]}
JSON
DOCKER_CONFIG=/private/tmp/gitops-docker-public bash scripts/demo.sh connect
DOCKER_CONFIG=/private/tmp/gitops-docker-public bash scripts/demo.sh check dev
# check staging/prod tương tự; chỉ áp dụng cho image public của lab.
```

## Kết quả đã xác minh ngày 06/10/2026

Hạ tầng đã dựng: Docker29.4.0, ba node Ready, ingress/Sealed Secrets1/1 và
bảy pod Argo1/1; HTTP/HTTPS localhost200. Credential đã seal lại cho ba môi
trường và validate. BE Go quality PASS, coverage73,5%. Các kiểm tra workflow,
promotion/rollback/branch snapshots đã chạy lại: 38 test GitOps và 8 test
script BE PASS; actionlint ở cả hai repo và ba overlay đều PASS. Test Git
thực hiện hai chu kỳ merge release, giữ đúng replica và ciphertext.

CLI namnd74 đã được cấp quyền workflow. Cấu hình GitOps PR#1 đã merge vào
main (f6d9df1), ba remote branch dev/staging/prod đã tạo từ commit này và
đều bắt buộc check validate từ GitHub Actions, áp dụng cả admin. Repo chỉ
cho phép merge commit, chặn force push và xóa ba nhánh môi trường.

BE PR#1 đã merge (eecb51b) sau quality/build/security scan PASS. Lần CI đầu
thất bại khi cài Trivy0.63.0 do release không còn tồn tại; đã pin v0.75.0 và
CI PR chạy lại thành công. Pipeline main run37390533546 đã publish image và
tạo provenance, nhưng dừng khi installer Cosign cũ không xác minh được TUF
key; image này chưa được chấp nhận làm release. Cập nhật installer chính
thức v4.1.2 và Cosign v3.1.3 cho backend và GitOps rồi chạy lại pipeline.

Bản sửa Cosign đã merge ở config PR#2 (0e3f833) và BE PR#2 (4a8fcb9).
BE main run37391394498 PASS toàn bộ quality/build/scan/publish/sign và mở
config PR#3 vào dev cho v1.3.0. Digest:
`sha256:9f919a9f8409643a6069ab12575d59a942d61c9aa16735249cd156387e90a97d`.
Xác minh độc lập OCI source/version/revision, provenance từ BE main và
Cosign signer PASS. PR Dev cũng mang installer mới để staging/prod nhận
bản sửa qua merge. Fixture test connect được sửa để không phụ thuộc image
của checkout; cả 38 test PASS trên release digest.

CONFIG_REPO_PAT đã được thêm vào repo config. Validation PR Dev chạy lại
PASS; các workflow promotion, validation và review đều PASS trước merge.
Ba Application đã connect và kiểm tra live PASS: nhánh/revision Git đúng,
Synced/Healthy, đủ replica, runtime digest đúng, /healthz 200 và /version
khớp v1.3.0, source SHA 4a8fcb9313628bbf5a3f800c59aeae295d0cdd29 và env.

| Môi trường | Merge PR | Revision tốt của config | Pod Ready | Acceptance |
|---|---|---|---|---|
| Dev | [#3](https://github.com/namnd74/gitops-manifests/pull/3) | 6d5d87313f3a68076500474041356a84e65e616c | 1/1 | PASS |
| Staging | [#5](https://github.com/namnd74/gitops-manifests/pull/5) | 7bdef055a596bb7cd3a855bb36072485aac1d276 | 2/2 | PASS |
| Prod | [#6](https://github.com/namnd74/gitops-manifests/pull/6) | 4f907193382bc8a7eea0430a4b9925ed51471b98 | 3/3 | PASS |

Một vòng merge release thực tế đã hoàn tất dev → staging → prod, không
rebuild artifact khi promote, giữ nguyên env patch/ingress/Argo/ciphertext.
Fault/drift/rollback chưa chạy live trong vòng này; dùng runbook khi demo.

Links evidence:
- Config PR: https://github.com/namnd74/gitops-manifests/pull/1
- Backend PR: https://github.com/namnd74/be-service/pull/1
- BE CI PR PASS: https://github.com/namnd74/be-service/actions/runs/37390284792
- BE CI main: https://github.com/namnd74/be-service/actions/runs/37390533546
- BE CI signed release PASS: https://github.com/namnd74/be-service/actions/runs/37391394498
- Dev release PR: https://github.com/namnd74/gitops-manifests/pull/3
- Dev → Staging workflow PASS: https://github.com/namnd74/gitops-manifests/actions/runs/37392727175
- Staging → Prod workflow PASS: https://github.com/namnd74/gitops-manifests/actions/runs/37393046286
