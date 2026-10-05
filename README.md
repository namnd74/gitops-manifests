# GitOps manifests: ba nhánh môi trường

Repo cấu hình có ba nhánh triển khai: `dev`, `staging`, `prod`. Argo CD
`be-service-dev`, `be-service-staging`, `be-service-prod` theo dõi nhánh cùng
tên và overlay tương ứng. `main` giữ cấu hình bootstrap và workflow mặc định.

BE CI build/scan/publish/ký một image từ `be-service/main`, rồi mở PR cập nhật
`apps/be-service/base/kustomization.yaml` vào config `dev`. Promotion mở PR
trực tiếp `dev → staging`, `staging → prod`; merge commit giữ lịch sử và digest,
không rebuild. Ba overlay giữ namespace, host, replicas và secret riêng.

- [Hướng dẫn dựng lại và demo merge release](scripts/rebuild-step-by-step.md)
- [Runbook release, fault và rollback](scripts/demo-runbook.md)
- [Kế hoạch chuyển sang ba nhánh](docs/superpowers/plans/2026-10-06-three-branches.md)

```bash
bash scripts/demo.sh doctor
bash scripts/demo.sh setup
bash scripts/demo.sh seal
bash scripts/demo.sh connect
bash scripts/demo.sh status
bash scripts/demo.sh check dev
```

`connect/check` đọc snapshot từ remote branch của từng môi trường. `connect`
không tạo Application cho Staging/Prod còn bootstrap, và yêu cầu Dev có digest
đã xác minh. Chạy lại sau promotion đầu tiên. Tag bootstrap không phải release.
Giữ `.demo/` cũ; không tự động xóa cluster, registry, Git server hoặc backup.
