# GitOps manifests

Hướng dẫn thực hành: [dựng lại lab từng bước](scripts/rebuild-step-by-step.md),
gồm đăng nhập GitHub và nhật ký kiểm chứng trên máy ngày 06/10/2026.

Repo cấu hình Dev/Staging/Prod. Argo CD đọc repo GitHub này để triển khai
backend; repo không build image.

- `apps/`: base và overlay Kustomize; image production luôn được ghim bằng
  digest. `deployment-env-patch.yaml` chứa biến môi trường theo từng môi trường.
- `argocd/`: Applications; cả ba môi trường bật autosync và self-heal sau khi
  PR đã merge.
- `.github/workflows/`: validate, promotion PR và rollback PR.
- `setup.sh`, `scripts/`: hạ tầng lab, Sealed Secret, kiểm tra và runbook.

Flow duy nhất: BE CI → GHCR → Dev PR → Argo CD → k3d. Promotion chỉ hỗ trợ
`dev -> staging` và `staging -> prod`, giữ nguyên digest đã scan. Rollback nhận
`env` và `revision`, mở PR phục hồi image cùng env patch từ revision tốt; Sealed
Secret được giữ nguyên.

```bash
bash scripts/demo.sh --help
bash scripts/demo.sh doctor
bash scripts/demo.sh setup
bash scripts/demo.sh seal
bash scripts/demo.sh connect
bash scripts/demo.sh status
bash scripts/demo.sh check dev
```

Chỉ sáu lệnh demo được hỗ trợ: `doctor`, `setup`, `seal`, `connect`, `status`,
`check`. Không có lệnh sync Prod riêng; Prod tự reconcile sau khi PR merge.
Đọc [runbook](scripts/demo-runbook.md) để cấu hình GitHub, chạy CI, promotion,
security gate, secret, drift và rollback. Cấu hình bootstrap hiện dùng tag
`sha-9912c6b`, chưa phải artifact đã xác minh; remote/live acceptance chưa được
thực hiện.

Giữ các container `.demo/` cũ cho migration lab. Appendix trong runbook chỉ
hướng dẫn xử lý sau migration và không tự động xóa chúng.
