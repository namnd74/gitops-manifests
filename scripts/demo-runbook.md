# Cẩm Nang Thuyết Trình Seminar: GitOps & CI/CD Đa Môi Trường

## Bố Cục 4 Tab Màn Hình Chuẩn Bị
- **Tab 1:** Argo CD UI (`http://localhost`)
- **Tab 2:** Web App Demo (`http://localhost/app`)
- **Tab 3:** GitHub `be-service` (tab Actions)
- **Tab 4:** GitHub `gitops-manifests` (Pull Requests)

---

## 5 Bước Diễn Tập Live Demo

### Bước 1: Giới thiệu cấu trúc 2 Repo (2 phút)
- Giải thích: `be-service` (Developer) và `gitops-manifests` (DevOps).
- Mở `http://localhost/app` xem version hiện tại `v1.0.0` (Dev).

### Bước 2: Happy Path - Từ Commit đến Dev Auto-Sync (5 phút)
1. Mở `be-service/main.go`, đổi version thành `v1.1.0`.
2. Commit & push lên GitHub:
   ```bash
   git commit -am "feat: release version 1.1.0" && git push origin main
   ```
3. Mở GitHub Actions: Xem 4 jobs (Test -> Trivy scan -> GHCR push -> Auto update tag).
4. Mở Argo CD UI: Thấy `be-service-dev` tự động rolling update.
5. F5 lại `http://localhost/app`: Version chuyển thành `v1.1.0`!

### Bước 3: Quality Gate - Chặn đứng Image lỗi bảo mật (3 phút)
1. Mở `be-service/Dockerfile`, đổi base image thành bản cũ: `FROM alpine:3.14.0`.
2. Commit & push lên GitHub.
3. Mở GitHub Actions: Step Trivy Scan phát hiện lỗ hổng `CRITICAL` và fail pipeline.
4. Nhấn mạnh: Môi trường Dev không bị ảnh hưởng, image độc hại không được sinh ra!

### Bước 4: Environment Promotion - Thăng hạng sang Staging & Prod (4 phút)
1. Mở repo `gitops-manifests`, tạo Pull Request sửa image tag trong:
   `apps/be-service/envs/staging/kustomization.yaml` -> `v1.1.0`.
2. Review Git Diff minh bạch -> Merge PR -> Staging cập nhật 2 Pods.
3. Giải thích Prod có Manual Gate trên Argo CD (cần người bấm phê duyệt).

### Bước 5: Đỉnh cao - Giả lập Crash & Rollback trong 5 giây (4 phút)
1. Mở `http://localhost/app`, bấm nút đỏ **"Simulate Bug/Crash (Trigger Rollback)"**.
2. Endpoint `/healthz` trả về 500 -> Pod K8s chuyển CrashLoopBackOff.
3. Trên Argo CD UI: Bấm vào app `be-service-dev` -> **History and Rollback** -> Chọn bản trước -> Bấm **Rollback**.
4. Trong vòng 5 giây, Pod cũ được khôi phục, trang web xanh trở lại!
