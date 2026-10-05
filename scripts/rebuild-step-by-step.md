# Dựng lại lab GitOps từng bước

Workspace: `/Volumes/MacOs/workspaces/git-ops`. Hướng dẫn thực hành ngày
06/10/2026, giờ Việt Nam. Hai repo độc lập: `be-service` và `gitops-manifests`.

Luồng triển khai: BE CI → GHCR → PR cấu hình Dev → merge → Argo CD → k3d.
Promotion và rollback đi qua PR; không build image local để thay thế artifact CI.

## 1. Kiểm tra Docker Desktop

Mở Docker Desktop, chờ engine chạy rồi thực hiện:

```bash
docker context ls
docker info --format '{{.ServerVersion}}'
docker ps -a
k3d cluster list
```

Chỉ tiếp tục khi `docker info` thành công. Nếu thấy lỗi socket không tồn tại:

```bash
open /Applications/Docker.app
```

Chờ engine rồi kiểm tra lại. Trong Codex, Docker có thể chạy nhưng sandbox
không truy cập được socket; cần chạy thao tác Docker ngoài sandbox bằng quyền
của công cụ. Không reset Docker hoặc xóa dữ liệu để xử lý lỗi quyền này.

## 2. Kiểm tra công cụ và GitHub

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
for tool in docker kubectl k3d kubeseal kustomize yq jq git gh cosign python3 openssl; do
  command -v "$tool" || break
done
```

Máy này thiếu `yq` và `cosign` khi bắt đầu; cài bằng Homebrew:

```bash
brew install yq cosign
gh auth login --hostname github.com --web
gh auth status
bash scripts/demo.sh doctor
```

Đăng nhập bằng tài khoản có quyền với `namnd74/be-service` và
`namnd74/gitops-manifests`. Không đưa token hoặc plaintext secret vào Git/chat.
Hạ tầng ở bước 3 có thể dựng trước khi đăng nhập GitHub; bước kết nối release
vẫn cần tài khoản và artifact CI hợp lệ.

Chi tiết thao tác đăng nhập:

1. Mở ứng dụng Terminal trên Mac và chạy lệnh `gh auth login` phía trên.
2. Nếu được hỏi giao thức Git, chọn **HTTPS**. Nếu được hỏi xác thực Git bằng
   credential GitHub, chọn **Yes**.
3. CLI hiển thị mã dùng một lần. Nhấn Enter để mở trình duyệt; nếu không tự
   mở, vào `https://github.com/login/device`.
4. Đăng nhập đúng tài khoản GitHub, nhập mã từ Terminal và chọn
   **Authorize GitHub CLI**.
5. Quay lại Terminal, chờ CLI hoàn tất rồi chạy `gh auth status`.
   Chỉ tiếp tục khi lệnh xác nhận đã đăng nhập đúng tài khoản.

## 3. Dựng Kubernetes và các controller

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
bash scripts/demo.sh setup
```

Script tạo cluster `gitops-demo` nếu chưa có: một server, hai agent, ánh xạ
`127.0.0.1:80` và `127.0.0.1:443`; cài ingress-nginx, Sealed Secrets, Argo CD.
Phiên bản được đọc từ `scripts/tool-versions.env`. Script chờ rollout và dừng
khi có lỗi. Nếu cluster đã có nhưng đang dừng, chạy `k3d cluster start gitops-demo`
trước khi chạy lại setup. Không xóa cluster cũ: xóa sẽ mất key Sealed Secrets.

Kiểm chứng:

```bash
kubectl --context k3d-gitops-demo get nodes
kubectl --context k3d-gitops-demo get pods -A
kubectl --context k3d-gitops-demo -n ingress-nginx get deployment
kubectl --context k3d-gitops-demo -n kube-system get deployment sealed-secrets-controller
kubectl --context k3d-gitops-demo -n argocd get deployment,statefulset,ingress
curl -I http://localhost
```

Ba node phải Ready, các controller phải đủ replica sẵn sàng. Bước này chưa
triển khai `be-service`.

## 4. Mở Argo CD

Truy cập `http://localhost`, tài khoản `admin`. Lấy mật khẩu trực tiếp trong
Terminal cá nhân, không lưu vào hướng dẫn hay log:

```bash
kubectl --context k3d-gitops-demo -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode
```

Nếu ingress chưa truy cập được, dùng Terminal riêng:

```bash
kubectl --context k3d-gitops-demo -n argocd port-forward svc/argocd-server 8080:443
```

Sau đó mở `https://localhost:8080` (chứng chỉ local).

## 5. Seal credential lab theo key của cluster

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
bash scripts/demo.sh seal
for env in dev staging prod; do
  kubeseal --context k3d-gitops-demo --validate \
    < "apps/be-service/envs/$env/sealed-secret.yaml"
done
bash scripts/validate-manifests.sh
```

`seal` giữ ciphertext còn hợp lệ, tạo credential ngẫu nhiên chỉ cho lab nếu
ciphertext cũ không giải mã được. Nó thay đổi manifest local; cần review và
đưa ciphertext lên GitHub trước khi Argo sử dụng.

## 6. Chuẩn bị và merge cấu hình GitOps

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
git status --short --branch
bash scripts/validate-manifests.sh
python3 -m unittest discover -s scripts/tests -v
git diff --check
```

Review thay đổi đang có ở branch `seminar/demo-ready`; đưa cấu hình và script
lên PR vào `main` theo quy trình repo. Chỉ stage file đã review, không stage
`.demo/`, cache, token hay plaintext credential. Runbook seminar có các lệnh
commit/push/PR. Không chạy `connect` với working tree còn thay đổi.

Trong GitHub, bật Actions và đặt secret `CONFIG_REPO_PAT` ở cả hai repo:
quyền contents/pull_requests trên config repo và đọc packages/provenance BE.
Đặt variable `IMAGE_ARCH=arm64` cho lab Apple Silicon. Nếu GitHub/GHCR private,
cấu hình credential đọc repo cho Argo và imagePullSecret cho workload.

Kiểm tra tên secret (không đọc được giá trị secret đã lưu trên GitHub):

```bash
gh secret list --repo namnd74/be-service
gh secret list --repo namnd74/gitops-manifests
```

Ngày thực hiện, BE đã có secret nhưng config repo chưa có. Dùng PAT bạn giữ
riêng có các quyền nêu trên; nếu không còn giữ giá trị, tạo PAT mới phù hợp.
Thêm bằng prompt tương tác trong Terminal:

Với hai repo public của lab, tạo token classic ở
`https://github.com/settings/tokens/new`: đặt tên `gitops-demo`, thời hạn 30
ngày, chọn `public_repo` và `read:packages`, rồi Generate token. Copy token
vừa tạo để nhập vào prompt sau; GitHub chỉ hiển thị token một lần. Token này
dùng cho workflow mở PR cấu hình và đọc image, không dùng để push thay đổi
workflow từ máy local. Nếu chuyển repo thành private, cần điều chỉnh quyền.

```bash
gh secret set CONFIG_REPO_PAT --repo namnd74/gitops-manifests
```

Dán token khi CLI hỏi, không đặt token trực tiếp trong câu lệnh. Nếu dùng PAT
mới để thay token BE, cập nhật cả repo BE:

```bash
gh secret set CONFIG_REPO_PAT --repo namnd74/be-service
```

## 7. Phát hành backend qua CI

```bash
cd /Volumes/MacOs/workspaces/git-ops/be-service
bash scripts/check-quality.sh
python3 -m unittest discover -s scripts/tests -v
git diff --check
git status --short --branch
```

Review và đưa thay đổi BE lên PR, merge vào `main`, sau đó theo dõi:

```bash
gh run list --repo namnd74/be-service --workflow ci.yaml --limit 3
```

CI phải qua quality/build/scan, publish image, tạo provenance/chữ ký và mở
Dev PR trong config repo. Review và merge Dev PR. Không coi tag bootstrap
`sha-9912c6b` là release đã xác minh; cần image reference `@sha256:...` thật.

## 8. Kết nối Argo và kiểm chứng Dev

Sau khi mọi thay đổi config đã merge, chuyển về `main` với working tree sạch
(không bỏ thay đổi local để ép sạch):

```bash
cd /Volumes/MacOs/workspaces/git-ops/gitops-manifests
git switch main
git pull --ff-only origin main
bash scripts/demo.sh connect
bash scripts/demo.sh status
bash scripts/demo.sh check dev
```

`connect` kiểm tra HEAD bằng remote main, manifest, image supply chain và
Sealed Secrets trước khi apply Applications. Chờ Argo reconcile rồi chạy
`check dev` lại nếu rollout chưa xong. `check` đối chiếu Git revision,
Argo Synced/Healthy, digest pod và `/version`, không chỉ HTTP 200.

Các URL workload theo manifest:

- `http://dev.127.0.0.1.nip.io`
- `http://staging.127.0.0.1.nip.io`
- `http://prod.127.0.0.1.nip.io`

## 9. Promotion và rollback

Sau khi `check dev` đạt:

```bash
gh workflow run promote.yaml --repo namnd74/gitops-manifests -f from=dev -f to=staging
```

Review/merge PR, pull config main, chạy `bash scripts/demo.sh check staging`.
Khi Staging đạt, promotion `staging → prod`, review/merge và kiểm chứng Prod:

```bash
gh workflow run promote.yaml --repo namnd74/gitops-manifests -f from=staging -f to=prod
# Sau merge và pull main:
bash scripts/demo.sh check prod
```

Rollback và demo fault/drift có trong [runbook seminar](demo-runbook.md).
Không cần lệnh sync riêng cho Prod: Argo autosync sau merge.

## Nhật ký thực hiện 06/10/2026

- Docker engine 29.4.0 đã được kiểm tra ngoài sandbox.
- Khi bắt đầu, Docker không có container và k3d chưa có cluster.
- Đã cài `yq` 4.54.1 và `cosign` 3.1.3.
- Đã đăng nhập GitHub `namnd74`; `bash scripts/demo.sh doctor` PASS.
- `bash scripts/demo.sh setup` hoàn tất với exit code 0: ba node Ready,
  ingress-nginx và Sealed Secrets đều 1/1; cả bảy pod Argo CD Running, 1/1.
- `http://localhost` và `https://localhost` đều trả HTTP 200 (HTTPS kiểm tra
  với chứng chỉ local qua `curl -k`).
- Đã seal lại credential lab cho ba môi trường; cả ba ciphertext validate
  thành công và ba overlay manifest PASS.
- 27 test GitOps, 8 test script BE đều PASS; Go test/race/vet/format PASS,
  coverage 73,5%. `git diff --check` không báo lỗi.
- Chưa có Argo Applications hay workload backend. Chưa thực hiện live
  acceptance của release, promotion hoặc rollback.
- Hai repo có thay đổi chưa commit trên branch `seminar/demo-ready`.
  Overlay vẫn dùng tag bootstrap `sha-9912c6b`, chưa có digest release mới.
- Hai GitHub repo đều public. BE có `CONFIG_REPO_PAT`; config repo chưa có.
  Giá trị và hiệu lực PAT BE chưa được xác minh.
- Điểm tiếp tục: thêm PAT cho config repo (bước 6), review/merge cấu hình,
  phát hành BE qua CI (bước 7), merge Dev PR và chạy connect/check (bước 8).
