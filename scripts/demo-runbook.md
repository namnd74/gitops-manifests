# Vận hành local và release tùy chọn

## Local dev: chỉ dùng main

Theo [hướng dẫn dựng từng bước](rebuild-step-by-step.md), rồi dùng:

```bash
bash scripts/local-dev.sh up
bash scripts/local-dev.sh status
bash scripts/local-dev.sh check
bash scripts/local-dev.sh down
```

`up` cập nhật Git snapshot nội bộ từ working tree hiện tại. `dev/staging/prod`
là ba overlay trên `main`, dùng cùng image với replica 1/2/3. Thay đổi source
chỉ có hiệu lực trong cluster sau khi chạy lại `up`. Local image chưa được
scan/ký/attest bằng GitHub Actions; đây là flow phát triển local.

Kiểm tra không cần cluster:

```bash
bash scripts/validate-manifests.sh
python3 -m unittest discover -s scripts/tests -v
```

Các test cần Git, Kustomize, Mike Farah yq v4 và jq. Các template bootstrap dùng
`ghcr.io/example/be-service:bootstrap`; launcher thay image trước khi triển khai.

## Tùy chọn: GitHub Actions và GHCR

Chỉ cấu hình phần này nếu muốn build/scan/publish/ký và mở PR cập nhật image.
Dùng repo/fork của tổ chức bạn, không phụ thuộc tài khoản có sẵn trong hướng dẫn.

| Repo | Variable/secret | Ý nghĩa |
| --- | --- | --- |
| Backend | `ENABLE_GITOPS_RELEASE=true` | Bật publish và PR cập nhật config; mặc định tắt |
| Backend | `CONFIG_REPO=owner/config-repo` | Repo manifest nhận PR |
| Backend | `CONFIG_BRANCH=main` | Nhánh nhận PR; mặc định main |
| Backend | `IMAGE_ARCH=amd64` hoặc `arm64` | Kiến trúc image hosted; mặc định amd64 |
| Backend | secret `CONFIG_REPO_PAT` | Quyền đọc/ghi contents và pull requests repo config |
| Config | `SOURCE_REPO=owner/backend-repo` | Repo nguồn để xác minh chữ ký/provenance |
| Config | `IMAGE=ghcr.io/owner/backend-repo` | Image được phép trong manifest |
| Config | secret `CONFIG_REPO_PAT` | Token dùng verify và tạo PR khi chạy promotion/rollback |

CI quality/build/scan vẫn chạy khi chưa bật phát hành. Backend dùng tên GitHub
repo hiện tại làm image name. Với tên có chữ hoa, dùng repo tên lowercase cho GHCR.
Tạo PAT trong GitHub Settings → Developer settings, giới hạn quyền vào repo
cần thiết. Nhập token qua prompt `gh secret set CONFIG_REPO_PAT --repo owner/repo`,
không lưu token vào source, file hướng dẫn hoặc chat.

Hosted Argo phải được cấu hình repoURL GitHub, credential nếu repo private,
nhánh `main` và overlay tương ứng; template Applications mặc định dành cho local.
Đồng thời cần seal secret bằng controller của cluster hosted. Hosted CI chỉ
cập nhật digest trong Git; không tự kết nối cluster local tới GitHub.
Các overlay trên cùng main sẽ cùng cập nhật sau khi merge PR image.

## Tùy chọn nâng cao: demo promotion ba nhánh

Các workflow `promote.yaml`, `rollback.yaml` và helper `demo.sh` vẫn phục vụ
flow `dev → staging → prod` cho deployment hosted đã cấu hình riêng.
Flow này không được bật/tạo nhánh khi dựng local. Nếu dùng, chuẩn bị ba nhánh
với cùng manifest môi trường, đặt backend `CONFIG_BRANCH=dev`, cấu hình Argo
mỗi environment theo nhánh cùng tên và bảo vệ nhánh bằng required validation.
Promotion giữ nguyên digest đã xác minh, rollback chỉ phục hồi image/patch.

Helper hosted yêu cầu cấu hình rõ ràng:

```bash
export SOURCE_REPO=owner/backend-repo
export CONFIG_REPO_URL=https://github.com/owner/config-repo.git
export IMAGE=ghcr.io/owner/backend-repo
export CONTEXT=k3d-your-hosted-lab
bash scripts/demo.sh connect
bash scripts/demo.sh check dev
```

Helper đọc snapshot remote branch. Kiểm tra signature/provenance phải thành công
trước khi kết nối hoặc promotion. Không dùng `demo.sh setup/seal/connect` để thay
cho launcher local mặc định. Đọc `--help` trước khi chạy helper hosted.
