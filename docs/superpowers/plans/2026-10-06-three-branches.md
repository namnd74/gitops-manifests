# Demo release qua ba nhánh môi trường

Thiết kế được yêu cầu: config repo có `dev`, `staging`, `prod`. BE vẫn phát
hành artifact một lần từ `main`; PR image vào config `dev`. Promotion mở PR
trực tiếp `dev -> staging`, `staging -> prod`, merge commit giữ lịch sử.

Một image reference chung ở `apps/be-service/base/kustomization.yaml` trên
mỗi nhánh; ba overlay chỉ giữ namespace, host, replicas, env và ciphertext.
Argo Application từng môi trường theo dõi nhánh cùng tên, đường dẫn overlay
tương ứng. Promotion không sửa hoặc copy image sang thư mục khác.

1. Viết test cho image chung, PR branch đích, promotion không mutate nguồn,
   rollback image chung, connect/check đọc đúng revision từng nhánh.
2. Chuyển image vào base và đặt targetRevision cho Argo.
3. Chuyển CI BE checkout/base PR sang `dev`; workflow promotion mở PR giữa
   nhánh sau kiểm tra digest/fault/secret; rollback checkout nhánh môi trường.
4. Connect/check lấy snapshot từ remote từng nhánh vào thư mục tạm, kiểm tra
   snapshot/revision đó thay vì dùng một HEAD cho cả ba môi trường.
5. Cập nhật runbook về merge commit, bootstrap và secret; chạy test, validate,
   actionlint; review thay đổi và commit.
6. Tạo ba nhánh local từ commit bootstrap chung. Push/PR khi CLI có scope
   workflow. Không tạo nhánh remote từ main cũ thiếu script và cấu hình mới.
7. Sau merge cấu hình, CI BE và Dev release PR, nối Argo; promotion tuần tự
   giữ digest; chứng minh mỗi môi trường theo revision của nhánh riêng.

Điều kiện hoàn tất live demo: ba remote branch có cấu hình mới, artifact CI
đã ký/xác minh, ba Argo Applications Synced/Healthy và check từng môi trường
PASS. Hiện quyền CLI workflow và CONFIG_REPO_PAT config vẫn chưa có.
