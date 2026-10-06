# Kịch bản seminar: happy case và failure/rollback case

## Chạy tự động và tiếp tục khi bị ngắt

Chạy ở repo manifest, chọn happy case, failure case hoặc cả hai:

```bash
bash scripts/demo.sh --preflight
bash scripts/demo.sh --scenario all --count 1
```

| Case | Lệnh | Diễn biến / điểm kết thúc |
| --- | --- | --- |
| Happy | `bash scripts/demo.sh --scenario happy --count 1` | Feature → dev → stg → prod; build/deploy đều đạt, cả ba Healthy |
| Failure | `bash scripts/demo.sh --scenario failure --count 1` | Dev/stg đạt, prod build lỗi rồi rollout lỗi, PR revert phục hồi baseline prod |
| Cả hai | `bash scripts/demo.sh --scenario all --count 1` | Happy trước; bản prod tốt vừa phát hành trở thành baseline cho failure |

Mặc định `--scenario all`. Thay `1` bằng `10`, `100` hoặc `1000` để lặp tuần tự;
`all --count 10` là 10 cặp happy → failure. Không cần dựng lại cluster;
mỗi vòng ghi baseline mới, tự tăng patch version từ backend dev và dùng nhánh duy nhất.
Các môi trường ban đầu **có thể khác version**: sau diễn tập, dev/staging có thể ở B còn prod ở A.
Script lấy digest/version hiện tại của từng môi trường, không dùng lại các file baseline của lần cũ.

Happy case: feature PR → dev CI/image PR/deploy → dev-to-stg PR/CI/image PR/deploy →
stg-to-prod PR/CI/image PR/deploy; kiểm chứng tất cả Healthy và đúng image mới.
Không bật build fault, không đổi readiness và không tạo rollback PR trong happy case.

Failure case: feature PR → dev CI/image PR/deploy → dev-to-stg PR/CI/image PR/deploy →
stg-to-prod PR/build lỗi → xác nhận prod không đổi → dispatch prod build đạt → PR readiness fault →
xác nhận Argo Degraded và ba pod cũ còn phục vụ → PR revert toàn bộ fault merge → xác nhận rollback.
Không bỏ qua checks hoặc signature/provenance gate trong CI manifest.

Mỗi session lưu `.local/demos/SESSION/session.json`, `session.log`, hai clone riêng và thư mục
`0001`, `0002`, … khi chọn một case; `0001-happy`, `0001-failure`, … khi chọn `all`.
Mỗi thư mục chứa state/PR/run/artifact/baseline/deployment/rollback evidence riêng.
State được ghi trước network write và checkpoint chỉ tiến sau khi kiểm chứng bước hoàn tất.

```bash
bash scripts/demo.sh --resume SESSION
```

Theo dõi chi tiết ở một Terminal khác bằng `tail -f .local/demos/SESSION/session.log`.

Resume đọc số vòng **và case** đã lưu, tái sử dụng PR/commit/run; vòng đã hoàn thành không phát hành lại.
Không sửa checkpoint để bỏ qua bước. Khi script dừng, đọc log và khắc phục nguyên nhân rồi resume.
Mặc định mỗi lần chờ tối đa 3600 giây, poll 10 giây; có thể đặt `DEMO_WAIT_SECONDS`,
`DEMO_POLL_SECONDS` là số nguyên dương khi chạy.

Lưu ý khi bị gián đoạn:

- `Unfinished session` nghĩa là session trước chưa được ghi nhận hoàn tất. Dùng đúng ID trong thông báo
  với `--resume`; không tạo vòng mới hoặc xóa state để vượt qua kiểm tra. Nếu case đã tới checkpoint 7,
  resume chỉ chốt metadata, không chạy lại release. Checkpoint rỗng/hỏng sẽ bị từ chối; giữ log và
  bằng chứng CI/PR để phục hồi sau khi xác minh deployment thực tế.

- Script cố đưa `DEMO_FAIL_PROD_BUILD=false` khi thoát sau khi đã dùng biến fault.
  Nếu network không cho reset, script báo lệnh cần làm. Nếu prod fail run còn queued và đã nhận biến false,
  resume có thể phát hiện build đạt ngoài kỳ vọng và dừng; không coi đó là demo thành công.
- SIGKILL hoặc tắt máy không chạy cleanup. Xác nhận không còn runner trước khi xóa file
  `.local/demos/lock/owner` và dùng `rmdir .local/demos/lock`; kiểm tra biến fault trên GitHub.
- Dispatch có thể được nhận dù client mất response. Script không tự POST lần hai.
  Nếu có nhiều dispatch ứng viên, kiểm tra SHA/event trên Actions rồi gắn run đúng:
  `bash scripts/demo.sh --resume SESSION --dispatch-run RUN_ID`.
  Nếu **không có run nào** sau khi xác nhận GitHub không nhận POST, xóa riêng
  `000N/dispatch-intent.json` (hoặc `000N-failure/dispatch-intent.json` với `all`) của vòng bị ngắt rồi resume. Không xóa marker khi run còn queued.
- Build/scan/sign/attest đạt nhưng tạo PR lỗi: runner chỉ phục hồi từ artifact và release branch CI đã push,
  kiểm tra đúng digest/source/version và vẫn chờ manifest CI. Run lỗi được giữ trong evidence.
- Dành riêng cả hai repo và cluster cho demo trong session; local lock không khóa người dùng máy khác.
  Thay đổi ngoài runner hoặc branch protection mới có thể làm script dừng để bạn xử lý.
- Các clone runtime/checkpoints cần giữ để resume. Không xóa `.local/demos` giữa session.

Happy case dùng ba CI build backend (dev, stg, prod); failure case dùng bốn (dev, stg,
prod cố ý fail, prod dispatch). Một vòng `all` dùng bảy build backend, cùng CI cho PRs.
Số vòng lớn tiêu thụ quota và dung lượng artifact; không tự động xóa Git history/package/evidence.
Các test dùng Git thật trên repo tạm và API/cluster giả lập; không thay thế một lần chạy end-to-end
trên GitHub/Argo của bên triển khai. Hãy chạy `--count 1` trước khi chọn số vòng lớn.

Happy case thao tác tay từng PR: [demo-happy.md](demo-happy.md).

## Cách trình bày hai case

1. **Happy case:** “Chúng ta đưa bản B qua dev, staging rồi production. Mỗi lần merge source có build riêng;
   merge PR manifest khiến Argo triển khai đúng môi trường. Cuối case cả ba chạy B và Healthy.”
2. **Failure case:** “B là bản tốt đang phục vụ production. Chúng ta đưa bản C qua dev/staging, chứng minh
   CI chặn prod build lỗi; sau khi build đạt, rollout có readiness lỗi. Revert manifest đưa production về B.”

A/B/C chỉ là vai trò của các bản, không phải version cố định. Trình diễn lần lượt Actions → PR manifest →
Argo → trang ứng dụng ở từng bước. Runner tự động dành cho chạy lặp; `session.log` và các snapshot
cho phép đối chiếu kết quả. Các bước thao tác tay bên dưới mô tả **failure case**.

## Flow và điều kiện bắt đầu

Backend: `feature → dev → stg → prod`. Mỗi nhánh tự build image riêng.
Manifest: PR digest vào nhánh tương ứng; merge thì Argo tự triển khai môi trường đó.
`stg` ánh xạ namespace/overlay `staging`.

Failure case có hai tình huống lỗi nối tiếp:

1. **Build prod fail:** không publish/không đổi manifest; production giữ bản cũ. Không cần rollback deployment.
2. **Build prod pass, rollout fail:** PR đưa image mới cùng readiness probe lỗi lên prod;
   PR revert khôi phục image/cấu hình cũ, Argo tự rollback. Không build lại image rollback.

Chuẩn bị theo README và chạy `bash scripts/check.sh` đạt. A là baseline riêng của từng môi trường;
không bắt buộc cả ba đang chạy cùng version.
Secrets/Variables đầy đủ, GHCR truy cập được, `DEMO_FAIL_PROD_BUILD` false hoặc chưa đặt.
Không có PR release cũ chưa xử lý; không có người khác cập nhật các nhánh trong khi trình diễn.
Bắt đầu Terminal Bash tại repo manifest; không dùng branch name đã tồn tại từ lần demo trước.

```bash
source scripts/local-common.sh
load_config
MANIFEST_DIR="$LOCAL_ROOT"
BACKEND_DIR="$BE_SOURCE_DIR"
BACKEND_REPO="$SOURCE_REPO"
MANIFEST_REPO="$CONFIG_REPO"
bash scripts/check.sh
```

Mở Actions backend, Pull Requests manifest, Argo và ba trang ứng dụng.
Namespace local mô phỏng môi trường; không thay thế cách cô lập production thật.

## 0. Ghi lại baseline production A

```bash
kubectl --context "$CONTEXT" -n prod get deployment be-service \
  -o jsonpath='{.spec.template.spec.containers[0].image}' > "$STATE_DIR/prod-before-image.txt"
curl -fsS -H 'Host: prod.127.0.0.1.nip.io' \
  "http://127.0.0.1:$HTTP_PORT/version" > "$STATE_DIR/prod-before-version.json"
gh api "repos/$MANIFEST_REPO/branches/prod" --jq .commit.sha > "$STATE_DIR/prod-before-revision.txt"
```

Không ghi password hoặc token vào bằng chứng demo.
Lời dẫn: “Production đang chạy bản A. Chúng ta ghi lại digest, version và Git revision để chứng minh release bị chặn và rollback đúng bản.”

## 1. Feature → dev: release B đạt

```bash
cd "$BACKEND_DIR"
git status --short
git fetch origin
git switch -c feature/seminar-release-b origin/dev
```

Nếu worktree không sạch, dừng và xử lý thay đổi riêng trước.
Trong `main.go`, đổi `ServiceName` thành `Backend API Service - Release B`.
Nếu tiêu đề B đã được dùng, chọn tiêu đề khác để thấy thay đổi.
Tăng patch version trong `VERSION` so với baseline (ví dụ v1.3.1 → v1.3.2).

```bash
gofmt -w main.go
bash scripts/check-quality.sh
git diff --check
git add main.go VERSION
git commit -m 'feat: demonstrate release B'
git push -u origin feature/seminar-release-b
gh pr create --repo "$BACKEND_REPO" --base dev --head feature/seminar-release-b \
  --title 'Seminar: release B to dev' --body 'Update the service title and version for the three-environment release demo.'
gh pr checks feature/seminar-release-b --repo "$BACKEND_REPO" --watch
```

Review diff và checks trước khi merge:

```bash
gh pr merge feature/seminar-release-b --repo "$BACKEND_REPO" --merge
DEV_SHA=$(gh pr view feature/seminar-release-b --repo "$BACKEND_REPO" --json mergeCommit --jq .mergeCommit.oid)
gh run list --repo "$BACKEND_REPO" --workflow ci.yaml --branch dev --commit "$DEV_SHA"
```

Chờ **push run của merge commit** thành công, không nhầm PR run. Dùng run ID từ danh sách:

```bash
gh run watch <DEV_PUSH_RUN_ID> --repo "$BACKEND_REPO" --exit-status
gh pr view release-be-service-dev --repo "$MANIFEST_REPO"
gh pr checks release-be-service-dev --repo "$MANIFEST_REPO" --watch
```

PR chỉ thay image digest; source commit phải đúng `DEV_SHA`, có CI evidence và checks đạt.

```bash
gh pr merge release-be-service-dev --repo "$MANIFEST_REPO" --merge
cd "$MANIFEST_DIR"
bash scripts/check.sh
```

Dev có tiêu đề/version B, staging/prod vẫn A. Không gọi build/render/deploy cho release này.
Lời dẫn: “Merge backend tự tạo artifact. Merge manifest tự triển khai dev; hai môi trường còn lại không bị cập nhật.”

## 2. Dev → stg: staging đạt

```bash
gh pr create --repo "$BACKEND_REPO" --base stg --head dev \
  --title 'Seminar: promote release B to staging' --body 'Promote the changes verified in dev.'
gh pr checks dev --repo "$BACKEND_REPO" --watch
gh pr merge dev --repo "$BACKEND_REPO" --merge
STG_SHA=$(gh pr view dev --repo "$BACKEND_REPO" --json mergeCommit --jq .mergeCommit.oid)
gh run list --repo "$BACKEND_REPO" --workflow ci.yaml --branch stg --commit "$STG_SHA"
gh run watch <STG_PUSH_RUN_ID> --repo "$BACKEND_REPO" --exit-status
gh pr checks release-be-service-stg --repo "$MANIFEST_REPO" --watch
gh pr view release-be-service-stg --repo "$MANIFEST_REPO"
gh pr merge release-be-service-stg --repo "$MANIFEST_REPO" --merge
cd "$MANIFEST_DIR"
bash scripts/check.sh
```

Review cả PR backend và manifest trước merge; xác nhận source đúng `STG_SHA`.
Staging có B; prod vẫn A. Hai build dev/stg có thể khác digest vì commit merge khác nhau.
Không merge nhánh manifest dev vào stg: env/secret/cấu hình đích phải được giữ riêng.

## 3. Stg → prod: cố ý làm Docker build thất bại

Chỉ bật lỗi trong repo demo, ngay trước khi merge prod:

```bash
gh variable set DEMO_FAIL_PROD_BUILD --repo "$BACKEND_REPO" --body true
gh pr create --repo "$BACKEND_REPO" --base prod --head stg \
  --title 'Seminar: promote release B to prod' --body 'Demonstrate a prod build failure that blocks publication and deployment.'
gh pr checks stg --repo "$BACKEND_REPO" --watch
gh pr merge stg --repo "$BACKEND_REPO" --merge
PROD_SHA=$(gh pr view stg --repo "$BACKEND_REPO" --json mergeCommit --jq .mergeCommit.oid)
gh run list --repo "$BACKEND_REPO" --workflow ci.yaml --branch prod --commit "$PROD_SHA"
```

Quan sát đúng push run; `gh run watch <PROD_FAILED_RUN_ID> --exit-status` sẽ trả mã lỗi (đúng kỳ vọng).
PR checks không bật fault; build sau merge trên prod nhận `DEMO_BUILD_FAIL=true` và Dockerfile cố ý exit 1.
Publish/update-config phải **Skipped**. Không được tạo manifest PR mới cho source commit này.

```bash
cd "$MANIFEST_DIR"
ACTUAL_IMAGE=$(kubectl --context "$CONTEXT" -n prod get deployment be-service -o jsonpath='{.spec.template.spec.containers[0].image}')
test "$ACTUAL_IMAGE" = "$(cat "$STATE_DIR/prod-before-image.txt")"
test "$(gh api "repos/$MANIFEST_REPO/branches/prod" --jq .commit.sha)" = "$(cat "$STATE_DIR/prod-before-revision.txt")"
bash scripts/check.sh
```

Prod vẫn A và Healthy. Không gọi rollback deployment ở bước này.
Lời dẫn: “CI chặn lỗi trước khi xuất bản image; trạng thái mong muốn trong Git và production không đổi.”

## 4. Gỡ lỗi build, chuẩn bị PR triển khai prod lỗi readiness

```bash
gh variable set DEMO_FAIL_PROD_BUILD --repo "$BACKEND_REPO" --body false
gh workflow run ci.yaml --repo "$BACKEND_REPO" --ref prod
gh run list --repo "$BACKEND_REPO" --workflow ci.yaml --branch prod --event workflow_dispatch
```

Chọn dispatch run vừa tạo, chờ thành công và PR `release-be-service-prod` có digest đã ký đúng prod:

```bash
gh run watch <PROD_SUCCESS_RUN_ID> --repo "$BACKEND_REPO" --exit-status
gh pr checks release-be-service-prod --repo "$MANIFEST_REPO" --watch
gh pr view release-be-service-prod --repo "$MANIFEST_REPO"
```

**Chưa merge PR image tự sinh.** Tạo một PR seminar chứa chính image đó cùng readiness fault:

```bash
cd "$MANIFEST_DIR"
git status --short
git fetch origin prod release-be-service-prod
git switch -c demo/prod-rollout-failure origin/prod
git restore --source origin/release-be-service-prod -- apps/be-service/base/kustomization.yaml
yq -i '.metadata.annotations."seminar.gitops.io/scenario" = "prod-readiness-failure" |
  .spec.template.spec.containers[0].name = "app" |
  .spec.template.spec.containers[0].readinessProbe.httpGet.port = 8081' \
  apps/be-service/envs/prod/deployment-env-patch.yaml
IMAGE="ghcr.io/$(printf '%s' "$BACKEND_REPO" | tr '[:upper:]' '[:lower:]')" bash scripts/validate-manifests.sh
git diff --check
git diff
git add apps/be-service/base/kustomization.yaml apps/be-service/envs/prod/deployment-env-patch.yaml
git commit -m 'demo: deploy release B with an intentional prod readiness failure'
git push -u origin demo/prod-rollout-failure
gh pr create --repo "$MANIFEST_REPO" --base prod --head demo/prod-rollout-failure \
  --title 'Seminar: prod rollout failure' --body 'Use the signed prod image with an explicit readiness-only seminar fault; liveness and existing-pod availability remain unchanged.'
gh pr checks demo/prod-rollout-failure --repo "$MANIFEST_REPO" --watch
```

Review diff: image B và readiness port 8081 ở **prod**, annotation seminar rõ ràng.
Backend chỉ nghe 8080 nên pod mới không Ready; liveness vẫn 8080, không tạo crash loop.
CI cho phép đúng tình huống có annotation và vẫn verify image signature/provenance trên prod.
Không bật `DEMO_MODE` hoặc `DEMO_FAULT` của ứng dụng trên prod.

```bash
gh pr close release-be-service-prod --repo "$MANIFEST_REPO"
gh pr merge demo/prod-rollout-failure --repo "$MANIFEST_REPO" --merge
BAD_MERGE=$(gh pr view demo/prod-rollout-failure --repo "$MANIFEST_REPO" --json mergeCommit --jq .mergeCommit.oid)
printf '%s\n' "$BAD_MERGE" > "$STATE_DIR/prod-bad-merge.txt"
```

Quan sát Argo tự sync (poll mặc định, hoặc refresh UI). Kubernetes có thể nhận manifest thành công
nhưng Deployment không Healthy; **Synced không có nghĩa Healthy**.

```bash
kubectl --context "$CONTEXT" -n prod get pods -l app=be-service
kubectl --context "$CONTEXT" -n prod rollout status deployment/be-service --timeout=90s
```

Lệnh rollout được kỳ vọng fail; sau `progressDeadlineSeconds=60`, Argo báo Degraded.
`maxUnavailable=0`, `maxSurge=1` giữ các pod A phục vụ khi pod B không Ready.
Kubernetes/Argo **không tự rollback chỉ vì readiness fail**.
Dev/staging vẫn Healthy và chạy B. Không dùng `check.sh` như kỳ vọng pass ở thời điểm prod đang lỗi.

## 5. Rollback production bằng PR revert

Revert merge commit chứa **cả image B lẫn readiness fault**, không chỉ sửa probe:

```bash
cd "$MANIFEST_DIR"
git fetch origin prod
git switch -c rollback/seminar-prod origin/prod
BAD_MERGE=$(cat "$STATE_DIR/prod-bad-merge.txt")
git show --stat "$BAD_MERGE"
git revert -m 1 --no-edit "$BAD_MERGE"
IMAGE="ghcr.io/$(printf '%s' "$BACKEND_REPO" | tr '[:upper:]' '[:lower:]')" bash scripts/validate-manifests.sh
git diff --check
git push -u origin rollback/seminar-prod
gh pr create --repo "$MANIFEST_REPO" --base prod --head rollback/seminar-prod \
  --title 'Seminar: rollback prod to release A' --body 'Restore the previous image digest and readiness configuration through GitOps.'
gh pr checks rollback/seminar-prod --repo "$MANIFEST_REPO" --watch
gh pr view rollback/seminar-prod --repo "$MANIFEST_REPO"
gh pr merge rollback/seminar-prod --repo "$MANIFEST_REPO" --merge
```

Review rollback khôi phục `DIGEST_A`, probe 8080 và bỏ annotation fault; chữ ký image A phải hợp lệ trên prod.
Không xóa/push đè Git history, không build image rollback, không dùng `kubectl rollout undo`.

```bash
bash scripts/check.sh
ACTUAL_IMAGE=$(kubectl --context "$CONTEXT" -n prod get deployment be-service -o jsonpath='{.spec.template.spec.containers[0].image}')
test "$ACTUAL_IMAGE" = "$(cat "$STATE_DIR/prod-before-image.txt")"
gh variable set DEMO_FAIL_PROD_BUILD --repo "$BACKEND_REPO" --body false
git switch main
```

Kết quả: prod A Synced/Healthy; dev/staging B. Manifest prod đã có commit rollback mới,
nhưng `/version.git_commit` trở về commit image A. Backend prod vẫn chứa code B;
rollback deployment và revert source là hai thao tác khác nhau.

Lời dẫn: “Git ghi nhận quyết định quay về bản tốt. Argo tự đồng bộ lại image và cấu hình;
production được khôi phục mà không build thủ công.”

## Checklist kết thúc

- Dev và staging B Healthy; prod A Healthy, digest đúng baseline.
- `DEMO_FAIL_PROD_BUILD=false`; không còn readiness fault trong prod.
- Lưu link PR, CI runs và Git revisions; giữ Git history để giải thích rollback.
- Không merge lại PR image prod đã đóng trong demo; release tiếp theo phải được duyệt riêng.
- Các nhánh demo dùng tên mới cho lần tiếp theo; baseline A/B là tên vai trò, không là version cố định.
- Không chạy promote toàn bộ nhánh manifest; chỉ cập nhật artifact và cấu hình đích cần thiết.

## Khi GitHub API tạo PR bị lỗi

Nếu build/scan/publish/sign/attest đạt nhưng job tạo PR báo HTTP 5xx, deployment vẫn giữ nguyên.
Đối chiếu log và xác nhận nhánh `release-be-service-<env>` đã được CI push; thử rerun **failed jobs**
trên Actions, giữ nguyên artifact đã ký. Nếu API rerun cũng lỗi, dùng `gh pr create` với base nhánh đích
và head nhánh release đã có; lấy digest/source/evidence từ log CI làm body PR.
Chờ checks manifest (gồm signature/provenance) đạt trước khi merge. Không tự build Docker local,
không bỏ checks, không xem một run có job thất bại là toàn bộ CI thành công.
