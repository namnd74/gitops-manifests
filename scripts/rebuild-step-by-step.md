# Dựng GitOps local từ source

## 1. Chuẩn bị

Dùng macOS/Linux hoặc terminal Linux trong WSL2 với Docker khả dụng. Cài Bash,
Python 3, Git, Docker, k3d, kubectl, kubeseal, Kustomize và Mike Farah yq v4.
Docker phải chạy, có BuildKit/buildx hỗ trợ `--provenance=false`; các lệnh
đều dùng Docker context hiện tại. Local build tắt attestation tự động của BuildKit
để build lặp lại không đổi image chỉ vì metadata thời gian. Hosted CI giữ
scan, ký và provenance riêng khi bật phát hành.
Các phiên bản controller/image hạ tầng được pin trong `scripts/tool-versions.env`;
Git server được build từ `scripts/local-git/Dockerfile`.
Alpine tách daemon thành [package git-daemon riêng](https://pkgs.alpinelinux.org/package/v3.22/main/x86_64/git-daemon).
Lần dựng đầu cần Internet và đủ tài nguyên cho một server, hai agent, Argo CD
và các controller. Chưa xác nhận khả năng chạy trên mọi hệ điều hành bằng kiểm thử thực tế.

## 2. Clone hai repo của bạn

Thay URL bên dưới bằng repo hoặc fork của bạn, giữ tên hai thư mục:

```bash
mkdir gitops-workspace
cd gitops-workspace
git clone <BE_REPOSITORY_URL> be-service
git clone <CONFIG_REPOSITORY_URL> gitops-manifests
cd be-service
git switch main
cd ../gitops-manifests
git switch main
```

Không cần `gh auth login` hoặc `CONFIG_REPO_PAT` cho flow local.

## 3. Cấu hình local

```bash
cp .env.local.example .env.local
```

Mặc định `BE_SOURCE_DIR=../be-service`, `CLUSTER_NAME=gitops-local`,
`HTTP_PORT=8088`, `HTTPS_PORT=8443`, `STATE_DIR=.local`.
Đường dẫn tương đối được tính từ repo cấu hình. Nếu backend nằm chỗ khác,
chỉnh `BE_SOURCE_DIR`. Nếu port bận, chọn hai port khác nhau trong `.env.local`.
`STATE_DIR` chỉ được nằm trong `.local/` để dữ liệu sinh ra luôn được Git bỏ qua.
Có thể đặt biến môi trường để ghi đè từng giá trị.

Giữ tên cluster riêng nếu máy đã có lab khác. Launcher từ chối dùng cluster
có cùng tên nhưng không có metadata hoặc có cấu hình khác. Để đổi port/mount
của cluster đã dựng, xóa cluster bằng `down` trước rồi chỉnh cấu hình.

## 4. Dựng toàn bộ

```bash
bash scripts/local-dev.sh up
```

Lệnh thực hiện tuần tự:

1. Kiểm tra tool và cấu hình, tạo cluster k3d cùng ingress/controller.
2. Build image backend và Git server (có package `git-daemon` đã pin) cho
   kiến trúc Docker host và import vào cluster.
3. Tạo secret riêng cho ba namespace bằng Sealed Secrets. Mật khẩu chỉ truyền
   qua stdin, private key của controller không được xuất ra máy.
4. Render image và ciphertext vào `.local/rendered`, commit snapshot vào Git
   nội bộ trên `main` rồi phục vụ read-only trong cluster.
5. Áp dụng ba Argo Application theo dõi `main` và overlay tương ứng.
6. Chờ Argo `Synced/Healthy`, kiểm tra revision, image đang chạy, replica,
   `/healthz` và `/version`. Chỉ báo `[PASS]` nếu kiểm tra thành công.

Manifest bootstrap trong source là template, không phải image release để deploy
trực tiếp. Ciphertext trong template cũng được thay bằng ciphertext của controller local.
Không cần đẩy Git, đăng nhập GHCR hoặc dùng secret của máy dựng trước.

## 5. Mở Argo CD và backend

Argo CD mặc định <http://localhost:8088>, tài khoản `admin`.
Chạy lệnh sau trong terminal của bạn để xem mật khẩu ban đầu:

```bash
kubectl --context k3d-gitops-local -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode
```

Nếu đổi `CLUSTER_NAME`, thay tên context tương ứng. Mật khẩu không lưu trong
hướng dẫn và không đưa vào Git.

| Môi trường | URL | Replica |
| --- | --- | --- |
| dev | http://dev.127.0.0.1.nip.io:8088/version | 1 |
| staging | http://staging.127.0.0.1.nip.io:8088/version | 2 |
| prod | http://prod.127.0.0.1.nip.io:8088/version | 3 |

Đổi port trong URL nếu chỉnh cấu hình. Các hostname `nip.io` cần DNS khả dụng;
kiểm tra CLI dùng IP loopback và Host header nên không phụ thuộc DNS này.

## 6. Sửa source và chạy lại

Sửa backend hoặc manifest trên `main`, rồi chạy:

```bash
bash scripts/local-dev.sh up
bash scripts/local-dev.sh status
bash scripts/local-dev.sh check
```

Image dùng tag gắn với image ID để cập nhật rollout khi nội dung thay đổi.
Ciphertext hợp lệ được tái sử dụng, tránh đổi password mỗi lần chạy.
Cả ba môi trường local nhận cùng image; không có bước merge release giữa các
nhánh trong flow local mặc định. CI GitHub và release ký là flow tùy chọn riêng.
Launcher không tự commit/push các thay đổi source.

## 7. Xóa và dựng lại

```bash
bash scripts/local-dev.sh down
bash scripts/local-dev.sh up
```

`down` chỉ xóa cluster đã cấu hình; giữ `.local/`. Khi tạo controller mới,
launcher kiểm tra ciphertext cũ và tạo lại nếu không giải mã được. Đừng sao chép
`.local/` hoặc `.env.local` sang máy khác; clone source và dựng lại trên máy mới.

## 8. Khi lệnh thất bại

Kiểm tra Docker và các tool trước, rồi xem trạng thái:

```bash
docker info
bash scripts/local-dev.sh status
kubectl --context k3d-gitops-local -n argocd get applications
kubectl --context k3d-gitops-local -n gitops-system get pods
kubectl --context k3d-gitops-local -n dev get pods
kubectl --context k3d-gitops-local -n argocd describe application be-service-dev
```

Nếu port bận hoặc metadata cluster không khớp, chọn tên cluster khác hoặc xóa
cluster bằng cấu hình cũ trước khi đổi. Nếu controller/image chưa tải được,
kiểm tra Internet và proxy của Docker. Không bỏ qua lỗi rollout hoặc coi timeout
là dựng thành công. Dùng [runbook](demo-runbook.md) cho kiểm tra source và CI tùy chọn.

## Phạm vi đã kiểm chứng

Đã kiểm thử trên macOS với Docker `linux/arm64`: dựng cluster mới, Argo/Git
nội bộ, secret, replica và HTTP của cả ba môi trường; cập nhật backend rồi
khôi phục source chính; chạy lại cùng source giữ nguyên image, Git revision
và ciphertext. Kiểm tra source: 47 test manifest, 9 test backend, Go test/race/vet,
actionlint và shellcheck. Các nền tảng khác vẫn cần chạy `up`/`check` để xác nhận.
