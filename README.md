# Hướng Dẫn Vận Hành GitOps & CI/CD Đa Môi Trường (Dev - Staging - Prod)

Tài liệu này hướng dẫn chi tiết cách vận hành, kịch bản chạy **PASS (Thành công)** và **FAIL (Thất bại)** trên từng môi trường, giúp bạn hiểu rõ diễn biến hệ thống và tự tin trình diễn demo seminar.

---

## 🗺️ Mục Lục
1. [Khởi Động Nhanh Hệ Thống Lab](#1-khởi-động-nhanh-hệ-thống-lab)
2. [Môi Trường DEV (Continuous Deployment - Auto Sync)](#2-môi-trường-dev-continuous-deployment---auto-sync)
   - [Kịch bản 1: PASS - Happy Path (Commit -> Auto Deploy)](#kịch-bản-1-pass---happy-path-từ-commit-đến-auto-deploy)
   - [Kịch bản 2: FAIL - Quality Gate Chặn Đứng Code Lỗi](#kịch-bản-2-fail---quality-gate-chặn-đứng-code-lỗi)
   - [Kịch bản 3: FAIL - Security Gate (Trivy) Chặn Lỗ Hổng Bảo Mật](#kịch-bản-3-fail---security-gate-trivy-chặn-lỗ-hổng-bảo-mật)
   - [Kịch bản 4: FAIL & ROLLBACK - Giả Lập Pod Crash và Khôi Phục Trong 5s](#kịch-bản-4-fail--rollback---giả-lập-pod-crash-và-khôi-phục-trong-5s)
3. [Môi Trường STAGING (Promotion Qua Pull Request)](#3-môi-trường-staging-promotion-qua-pull-request)
   - [Kịch bản PASS: Thăng Hạng Phiên Bản Bằng PR](#kịch-bản-pass-thăng-hạng-phiên-bản-bằng-pr)
   - [Kịch bản FAIL: Chặn Cấu Hình Sai Khi Review](#kịch-bản-fail-chặn-cấu-hình-sai-khi-review)
4. [Môi Trường PROD (Production - Manual Approval Gate)](#4-môi-trường-prod-production---manual-approval-gate)
   - [Kịch bản PASS: Phê Duyệt Triển Khai Thủ Công](#kịch-bản-pass-phê-duyệt-triển-khai-thủ-công)
   - [Kịch bản FAIL: Cơ Chế Khóa An Toàn Khi Chưa Duyệt](#kịch-bản-fail-cơ-chế-khóa-an-toàn-khi-chưa-duyệt)
5. [Bảng Tra Cứu Lệnh Nhanh (Cheat Sheet)](#5-bảng-tra-cứu-lệnh-nhanh-cheat-sheet)

---

## 1. Khởi Động Nhanh Hệ Thống Lab

Trong môi trường WSL (Ubuntu):
```bash
cd /mnt/f/gitops-seminar
chmod +x setup.sh
./setup.sh
```

Sau khi script chạy xong, bạn mở trình duyệt:
* 🌐 **Argo CD UI:** [`http://localhost`](http://localhost) (Tài khoản: `admin` | Mật khẩu lấy từ log script hoặc lệnh `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`)
* 🌐 **Môi trường DEV:** [`http://localhost/app`](http://localhost/app) *(hoặc `http://dev.local`)*
* 🌐 **Môi trường STAGING:** [`http://localhost/staging`](http://localhost/staging) *(hoặc `http://staging.local`)*
* 🌐 **Môi trường PROD:** [`http://localhost/prod`](http://localhost/prod) *(hoặc `http://prod.local`)*

---

## 2. Môi Trường DEV (Continuous Deployment - Auto Sync)

* **Đặc tính:** 1 Pod, tự động 100%. Mọi commit hợp lệ trên nhánh `main` của repo code sẽ tự động được build, quét bảo mật, đóng gói và triển khai ngay vào Dev mà không cần con người can thiệp.

```
[Developer Push Code] ──> [GitHub Actions 4 Jobs] ──> [Auto Commit Tag sang Manifest] ──> [ArgoCD Auto Sync sang Dev Pod]
```

---

### Kịch bản 1: PASS - Happy Path (Từ Commit đến Auto Deploy)

#### 👉 Thao tác thực hiện:
1. Mở file [`be-service/main.go`](file:///F:/gitops-seminar/be-service/main.go), tìm dòng:
   ```go
   AppVersion = "v1.0.0"
   ```
   Đổi thành:
   ```go
   AppVersion = "v1.1.0"
   ```
2. Commit và push lên GitHub:
   ```bash
   cd /mnt/f/gitops-seminar/be-service
   git commit -am "feat: release version 1.1.0"
   git push origin main
   ```

#### 🔍 Diễn biến khi PASS:
* **Trên GitHub Actions:** Cả 4 jobs đều hiển thị màu **XANH**:
  1. `1. Test & Quality Gate`: Pass các unit tests và định dạng code.
  2. `2. Container Security Scan (Trivy)`: Quét không phát hiện CVE CRITICAL.
  3. `3. Publish Artifact`: Đẩy image `ghcr.io/<user>/be-service:sha-xxxxxxx` lên GHCR.
  4. `4. Auto-Trigger GitOps`: Tự động sửa `newTag` trong [`apps/be-service/envs/dev/kustomization.yaml`](file:///F:/gitops-seminar/gitops-manifests/apps/be-service/envs/dev/kustomization.yaml) và push commit mới lên repo `gitops-manifests`.
* **Trên Argo CD UI:**
  * Ứng dụng `be-service-dev` phát hiện commit mới từ repo cấu hình.
  * Tự động chuyển trạng thái `Syncing` $\rightarrow$ `Synced` & `Healthy`.
  * Thực hiện **Rolling Update**: Pod mới được tạo ra, khi sẵn sàng thì Pod cũ được giải phóng mà không làm gián đoạn dịch vụ.
* **Trên Trình Duyệt ([`http://localhost/app`](http://localhost/app)):**
  * Nhấn `F5`: Huy hiệu Version chuyển sang **`v1.1.0`**, màu badge xanh dương đặc trưng cho môi trường Dev.

---

### Kịch bản 2: FAIL - Quality Gate Chặn Đứng Code Lỗi

#### 👉 Thao tác thực hiện:
1. Mở file [`be-service/main_test.go`](file:///F:/gitops-seminar/be-service/main_test.go), cố tình sửa giá trị kỳ vọng thành sai:
   ```go
   // Sửa status mong đợi từ StatusOK (200) thành StatusNotFound (404)
   if status := rr.Code; status != http.StatusNotFound {
       t.Errorf("handler returned wrong status code...")
   }
   ```
2. Commit và push:
   ```bash
   cd /mnt/f/gitops-seminar/be-service
   git commit -am "test: break unit test" && git push origin main
   ```

#### 🔍 Diễn biến khi FAIL:
* **Trên GitHub Actions:**
  * Job `1. Test & Quality Gate` bị **ĐỎ (Failed)** ngay tại bước `Run Unit Tests`.
  * Các Job 2, 3, 4 phía sau chuyển sang trạng thái **Skipped** (Bị hủy, không chạy).
* **Kết quả bảo vệ:**
  * Không có image Docker nào được build hay push lên Registry.
  * Repo cấu hình K8s không bị sửa đổi.
  * Môi trường Dev trên cụm K8s hoàn toàn không bị ảnh hưởng, người dùng vẫn sử dụng bình thường phiên bản trước đó.

---

### Kịch bản 3: FAIL - Security Gate (Trivy) Chặn Lỗ Hổng Bảo Mật

#### 👉 Thao tác thực hiện:
1. Mở file [`be-service/Dockerfile`](file:///F:/gitops-seminar/be-service/Dockerfile), đổi base image runtime thành một phiên bản rất cũ chứa nhiều lỗ hổng đã biết:
   ```dockerfile
   # Đổi từ alpine:3.20 sang bản cũ alpine:3.14.0
   FROM alpine:3.14.0
   ```
2. Commit và push:
   ```bash
   cd /mnt/f/gitops-seminar/be-service
   git commit -am "chore: downgrade to insecure base image" && git push origin main
   ```

#### 🔍 Diễn biến khi FAIL:
* **Trên GitHub Actions:**
  * Job `1. Test & Quality Gate` vẫn XANH (vì code Go không lỗi cú pháp).
  * Job `2. Container Security Scan (Trivy)` bị **ĐỎ (Failed)**: Trivy in ra bảng danh sách các CVE `CRITICAL` và dừng pipeline với mã `exit code 1`.
  * Job 3 và Job 4 bị **Skipped**.
* **Ý nghĩa seminar:**
  * Minh họa vai trò của **DevSecOps**: Phát hiện sớm lỗ hổng bảo mật của hạ tầng container ngay trong CI, ngăn chặn rò rỉ image độc hại vào cụm K8s.

---

### Kịch bản 4: FAIL & ROLLBACK - Giả Lập Pod Crash và Khôi Phục Trong 5s

#### 👉 Thao tác thực hiện:
1. Mở trình duyệt vào ứng dụng Dev: [`http://localhost/app`](http://localhost/app).
2. Nhấn vào nút đỏ lớn: **`Simulate Bug/Crash (Trigger Rollback)`**.

#### 🔍 Diễn biến khi FAIL:
* Trang web hiển thị cảnh báo: *"System crashed! Healthcheck endpoint /healthz is now returning 500"*.
* Kiểm tra trạng thái Pod trong terminal:
  ```bash
  kubectl get pods -n dev -w
  ```
  * Sau 15 giây (3 lần `livenessProbe` fail liên tiếp), Kubernetes phát hiện Pod không còn lành mạnh và tự động khởi động lại Pod.
  * Số lần Restarts tăng lên và Pod rơi vào trạng thái **`CrashLoopBackOff`**.
* **Trên Argo CD UI:** Ứng dụng `be-service-dev` chuyển sang trạng thái cảnh báo **`Degraded`**.

#### 🔄 Thao tác khôi phục (ROLLBACK trong 5 giây):
1. Trên giao diện Argo CD: Bấm vào App `be-service-dev`.
2. Chọn menu **History and Rollback**.
3. Chọn phiên bản lịch sử chạy ổn định trước đó (Revision 1 hoặc 2) $\rightarrow$ Bấm nút **Rollback**.
4. **Kết quả:** Ngay lập tức K8s phục hồi ReplicaSet cũ, Pod mới khỏe mạnh khởi động thay thế trong 5 giây, trang [`http://localhost/app`](http://localhost/app) hoạt động bình thường trở lại!

---

## 3. Môi Trường STAGING (Promotion Qua Pull Request)

* **Đặc tính:** 2 Pods (Đảm bảo tính sẵn sàng cao High Availability). Không tự động nhận commit từ Dev mà phải được kiểm duyệt thông qua **Pull Request** trên repo cấu hình [`gitops-manifests`](file:///F:/gitops-seminar/gitops-manifests).

---

### Kịch bản PASS: Thăng Hạng Phiên Bản Bằng PR

#### 👉 Thao tác thực hiện:
1. Mở file [`gitops-manifests/apps/be-service/envs/staging/kustomization.yaml`](file:///F:/gitops-seminar/gitops-manifests/apps/be-service/envs/staging/kustomization.yaml).
2. Thay đổi `newTag` sang tag vừa được kiểm thử thành công ở Dev (ví dụ `v1.1.0` hoặc tag `sha-xxxxxxx`).
3. Đẩy lên nhánh mới và tạo Pull Request:
   ```bash
   cd /mnt/f/gitops-seminar/gitops-manifests
   git checkout -b promote-staging-v1.1.0
   git commit -am "chore(staging): promote be-service to v1.1.0"
   git push origin promote-staging-v1.1.0
   ```
4. Lên giao diện GitHub tạo PR vào nhánh `main` $\rightarrow$ Review sự khác biệt (Git Diff) $\rightarrow$ Bấm **Merge Pull Request**.

#### 🔍 Diễn biến khi PASS:
* Argo CD ứng dụng `be-service-staging` phát hiện nhánh `main` có commit mới.
* Tự động triển khai tuần tự trên 2 Pods của Staging để đảm bảo zero-downtime.
* Kiểm tra trong WSL:
  ```bash
  kubectl get pods -n staging
  ```
  👉 Kết quả: Thấy 2 Pods đều ở trạng thái `2/2 Running`.

---

### Kịch bản FAIL: Chặn Cấu Hình Sai Khi Review

#### 👉 Thao tác thực hiện:
* Nếu ai đó tạo PR sửa nhầm port, gõ sai tên image (`ghcr.io/namnd74/be-service:non-existing-tag`) hoặc vi phạm cú pháp YAML.

#### 🔍 Diễn biến khi FAIL:
* **Giai đoạn Review:** Người phụ trách (DevOps Lead) nhìn thấy ngay Git Diff bất thường trên PR của GitHub và bấm **Close PR (Reject)**. Môi trường Staging hoàn toàn không bị tác động.
* **Nếu lỡ merge nhầm tag không tồn tại:**
  * Argo CD sẽ cố gắng kéo image nhưng bị lỗi `ImagePullBackOff`.
  * Nhờ chiến lược Rolling Update của Kubernetes, các Pod cũ vẫn tiếp tục phục vụ người dùng cho đến khi Pod mới sẵn sàng. Vì Pod mới không khởi động được nên hệ thống **không bao giờ gỡ bỏ Pod cũ**, dịch vụ trên Staging vẫn hoạt động liên tục!

---

## 4. Môi Trường PROD (Production - Manual Approval Gate)

* **Đặc tính:** 3 Pods. Đây là môi trường quan trọng nhất, nơi diễn ra giao dịch thực tế của khách hàng. Ứng dụng được cấu hình **tắt tính năng tự động đồng bộ** (`syncPolicy.automated: false`).

---

### Kịch bản PASS: Phê Duyệt Triển Khai Thủ Công (Manual Gate)

#### 👉 Thao tác thực hiện:
1. Tạo Pull Request cập nhật image tag trong [`gitops-manifests/apps/be-service/envs/prod/kustomization.yaml`](file:///F:/gitops-seminar/gitops-manifests/apps/be-service/envs/prod/kustomization.yaml) $\rightarrow$ Merge PR vào `main`.
2. Mở giao diện **Argo CD UI** ([`http://localhost`](http://localhost)).
3. Quan sát ứng dụng **`be-service-prod`**.

#### 🔍 Diễn biến khi PASS:
* Trạng thái ứng dụng chuyển sang **`OutOfSync` (Màu vàng)**: Báo hiệu rằng trên Git đã có phiên bản mới hơn phiên bản đang chạy dưới cụm K8s, **nhưng hệ thống chưa tự động deploy**.
* Người có thẩm quyền (Release Manager) bấm vào App `be-service-prod` $\rightarrow$ Chọn **App Diff** để xem lại các thay đổi.
* Sau khi xác nhận an toàn, bấm nút **`SYNC`** $\rightarrow$ Chọn **`Synchronize`**.
* Argo CD tiến hành cập nhật lần lượt 3 Pods trên Production một cách êm ái.

---

### Kịch bản FAIL: Cơ Chế Khóa An Toàn Khi Chưa Duyệt

#### 🔍 Diễn biến khi xảy ra sự cố:
* Nếu Developer vô tình commit nhầm lên nhánh `main` của repo manifest hoặc merge PR trước thời điểm cho phép:
  * **Hệ thống tự động khóa an toàn:** Do tính năng `automated` bị tắt, Argo CD sẽ chỉ cảnh báo `OutOfSync` mà **tuyệt đối không áp dụng cấu hình mới**.
  * Cụm Production vẫn được bảo vệ nguyên vẹn 100%, ngăn ngừa tuyệt đối rủi ro phát hành ngoài ý muốn.

---

## 5. Bảng Tra Cứu Lệnh Nhanh (Cheat Sheet)

| Mục đích kiểm tra | Lệnh thực hiện trong WSL | Kết quả mong đợi |
| :--- | :--- | :--- |
| **Kiểm tra Pod môi trường Dev** | `kubectl get pods -n dev` | `be-service-xxx` trạng thái `1/1 Running` |
| **Kiểm tra Pod môi trường Staging** | `kubectl get pods -n staging` | 2 Pods trạng thái `1/1 Running` |
| **Kiểm tra Pod môi trường Prod** | `kubectl get pods -n prod` | 3 Pods trạng thái `1/1 Running` (sau khi Sync) |
| **Xem chi tiết lý do lỗi Pod** | `kubectl describe pod <tên-pod> -n dev` | Xem mục `Events` ở cuối để biết lỗi image/crashes |
| **Theo dõi log ứng dụng thời gian thực** | `kubectl logs -f -l app=be-service -n dev` | Xem log HTTP request của Go server |
| **Kiểm tra Ingress Routing** | `kubectl get ingress -A` | Thấy đầy đủ rules cho `argocd` và `be-service` |
| **Kiểm tra Secret mã hóa** | `kubectl get sealedsecrets -n dev` | Trạng thái `Synced = True` |
| **Test phản hồi Web nhanh qua cURL** | `curl -s http://localhost/app \| grep "Version"` | Trả về thẻ HTML chứa đúng phiên bản đang chạy |
