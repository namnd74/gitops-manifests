# Happy case: tự sửa code, tạo PR và xem CI/CD từng bước

Chạy từng khối lệnh khi bước trước đã đạt, giữ cùng một Terminal Bash để giữ các biến.
Bạn tự sửa source, review và merge PR; GitHub Actions build/publish/tạo PR image,
Argo CD tự deploy sau khi merge PR manifest. Không chạy runner tự động song song.

## 0. Chuẩn bị tại repo manifest

Mở Terminal tại repo `gitops-manifests`, vào Bash rồi đọc cấu hình của máy:

```bash
bash
source scripts/local-common.sh
load_config
MANIFEST_DIR="$LOCAL_ROOT"
BACKEND_DIR="$BE_SOURCE_DIR"
BACKEND_REPO="$SOURCE_REPO"
MANIFEST_REPO="$CONFIG_REPO"
DEMO_ID=$(date +%Y%m%d-%H%M%S)
FEATURE_BRANCH="feature/happy-$DEMO_ID"
gh variable set DEMO_FAIL_PROD_BUILD --repo "$BACKEND_REPO" --body false
bash scripts/demo.sh --preflight
```

Chờ `[PASS] Ready for demo`. Không tiếp tục nếu CI/PR cũ còn chờ, baseline không khớp Git
hoặc có runner/session đang diễn tập. `preflight` kiểm tra, không chủ động deploy.
Ghi nhận version hiện tại trên ba trang ứng dụng hoặc `/version`; mỗi môi trường có thể khác version.
Các URL/port lấy theo `.env.local`; với port mặc định là:

- Dev: http://dev.127.0.0.1.nip.io:8088/
- Staging: http://staging.127.0.0.1.nip.io:8088/
- Prod: http://prod.127.0.0.1.nip.io:8088/
- Argo: http://localhost:8088/

## 1. Tạo feature từ dev và tự sửa code

```bash
cd "$BACKEND_DIR"
git status --short
```

Nếu có thay đổi chưa commit, xử lý riêng trước; không xóa/ghi đè chúng để chạy demo.
Nếu worktree sạch:

```bash
git fetch origin
git switch -c "$FEATURE_BRANCH" origin/dev
cat VERSION
```

Sửa **hai file** bằng editor:

1. Trong `main.go`, tìm `ServiceName:` ở hàm `handleIndex`, đổi giá trị thành:

   ```go
   ServiceName: "Backend API Service - Happy Release",
   ```

   Nếu tiêu đề đó đã dùng ở lần trước, chọn tiêu đề mới để nhận ra thay đổi trên trang.
2. Trong `VERSION`, tăng patch version so với **nhánh dev vừa checkout**, ví dụ
   `v1.3.3` → `v1.3.4`. Giữ dạng `vX.Y.Z` và newline cuối file.

Chỉ đổi title và version trong happy case; giữ env/probe/replica hiện tại.
Kiểm tra và commit:

```bash
gofmt -w main.go
bash scripts/check-quality.sh
git diff --check
git diff -- main.go VERSION
git add main.go VERSION
git commit -m "feat: happy release $DEMO_ID"
git push -u origin "$FEATURE_BRANCH"
```

## 2. PR feature → dev: xem checks rồi merge source

```bash
FEATURE_PR=$(gh pr create --repo "$BACKEND_REPO" --base dev --head "$FEATURE_BRANCH" \
  --title "Happy $DEMO_ID: release to dev" \
  --body 'Change the page title and patch version for a successful three-environment release.')
gh pr view "$FEATURE_PR" --repo "$BACKEND_REPO" --web
```

Ở tab PR, xem **Files changed** chỉ có hai file và **Checks** chạy.
Quality và build/security phải đạt. Publish/update-config được skip ở PR run:
image release và manifest PR được tạo ở **push run sau merge**.
Chờ checks hiển thị trên GitHub rồi có thể theo dõi tại Terminal:

```bash
gh pr checks "$FEATURE_PR" --repo "$BACKEND_REPO" --watch
```

Khi checks đạt, review xong thì merge bằng UI hoặc lệnh sau (chọn một cách):

```bash
gh pr merge "$FEATURE_PR" --repo "$BACKEND_REPO" --merge
```

Chờ PR có trạng thái **Merged**, rồi lấy merge SHA và mở Actions:

```bash
DEV_SHA=$(gh pr view "$FEATURE_PR" --repo "$BACKEND_REPO" --json mergeCommit --jq .mergeCommit.oid)
gh browse --repo "$BACKEND_REPO" --actions
gh run list --repo "$BACKEND_REPO" --workflow ci.yaml --branch dev --event push --commit "$DEV_SHA"
```

Trong Actions, chọn đúng **branch dev / event push / merge SHA DEV_SHA**.
Quan sát quality → build/scan → publish/sign/attest → propose image update.
Chờ cả run đạt; app dev chưa đổi cho tới khi merge PR manifest.

## 3. Merge PR manifest dev: xem Argo tự deploy

Chỉ chạy khi push run đã đạt và PR image mới xuất hiện:

```bash
DEV_CONFIG_PR=$(gh pr list --repo "$MANIFEST_REPO" --base dev \
  --head release-be-service-dev --state open --json url --jq '.[0].url // empty')
gh pr view "$DEV_CONFIG_PR" --repo "$MANIFEST_REPO" --web
```

Review: base `dev`, chỉ đổi `apps/be-service/base/kustomization.yaml`, image digest mới,
Source trong body trỏ đúng `DEV_SHA`. Đợi check `validate` đạt (gồm xác minh artifact).
Khi checks đã xuất hiện:

```bash
gh pr checks "$DEV_CONFIG_PR" --repo "$MANIFEST_REPO" --watch
gh pr merge "$DEV_CONFIG_PR" --repo "$MANIFEST_REPO" --merge
```

Mở Argo → `be-service-dev`, quan sát tự sync và rollout pod mới.
Không bấm Sync để thay thế auto-sync. Khi Healthy, kiểm tra:

```bash
cd "$MANIFEST_DIR"
bash scripts/check.sh
curl -fsS --max-time 10 -H 'Host: dev.127.0.0.1.nip.io' "http://127.0.0.1:$HTTP_PORT/version"
```

Dev hiển thị title/version mới; staging và prod giữ bản lúc bắt đầu.

## 4. PR dev → stg: build staging

```bash
STG_PR=$(gh pr create --repo "$BACKEND_REPO" --base stg --head dev \
  --title "Happy $DEMO_ID: promote dev to staging" \
  --body 'Promote the source changes verified in dev.')
gh pr view "$STG_PR" --repo "$BACKEND_REPO" --web
```

Review diff, đợi checks xuất hiện và đạt, rồi merge:

```bash
gh pr checks "$STG_PR" --repo "$BACKEND_REPO" --watch
gh pr merge "$STG_PR" --repo "$BACKEND_REPO" --merge
```

Chờ PR **Merged**, chọn push run staging đúng SHA:

```bash
STG_SHA=$(gh pr view "$STG_PR" --repo "$BACKEND_REPO" --json mergeCommit --jq .mergeCommit.oid)
gh browse --repo "$BACKEND_REPO" --actions
gh run list --repo "$BACKEND_REPO" --workflow ci.yaml --branch stg --event push --commit "$STG_SHA"
```

## 5. Merge PR manifest stg: deploy staging

Chờ run `stg` đạt và PR image mới xuất hiện:

```bash
STG_CONFIG_PR=$(gh pr list --repo "$MANIFEST_REPO" --base stg \
  --head release-be-service-stg --state open --json url --jq '.[0].url // empty')
gh pr view "$STG_CONFIG_PR" --repo "$MANIFEST_REPO" --web
```

Review đúng `STG_SHA` trong body, chỉ đổi image; checks đạt rồi merge:

```bash
gh pr checks "$STG_CONFIG_PR" --repo "$MANIFEST_REPO" --watch
gh pr merge "$STG_CONFIG_PR" --repo "$MANIFEST_REPO" --merge
```

Argo Application là `be-service-staging`, namespace `staging`; Git branch là `stg`.

```bash
cd "$MANIFEST_DIR"
bash scripts/check.sh
curl -fsS --max-time 10 -H 'Host: staging.127.0.0.1.nip.io' "http://127.0.0.1:$HTTP_PORT/version"
```

Dev và staging có bản mới; prod vẫn giữ baseline.

## 6. PR stg → prod: build production

Giữ `DEMO_FAIL_PROD_BUILD=false` trong toàn bộ happy case.

```bash
PROD_PR=$(gh pr create --repo "$BACKEND_REPO" --base prod --head stg \
  --title "Happy $DEMO_ID: promote staging to prod" \
  --body 'Promote the source changes verified in staging.')
gh pr view "$PROD_PR" --repo "$BACKEND_REPO" --web
```

Review, đợi checks xuất hiện và đạt rồi merge:

```bash
gh pr checks "$PROD_PR" --repo "$BACKEND_REPO" --watch
gh pr merge "$PROD_PR" --repo "$BACKEND_REPO" --merge
```

Chờ PR **Merged**, xem đúng push run prod:

```bash
PROD_SHA=$(gh pr view "$PROD_PR" --repo "$BACKEND_REPO" --json mergeCommit --jq .mergeCommit.oid)
gh browse --repo "$BACKEND_REPO" --actions
gh run list --repo "$BACKEND_REPO" --workflow ci.yaml --branch prod --event push --commit "$PROD_SHA"
```

## 7. Merge PR manifest prod: kết thúc happy case

Chờ prod run đạt và PR image mới xuất hiện:

```bash
PROD_CONFIG_PR=$(gh pr list --repo "$MANIFEST_REPO" --base prod \
  --head release-be-service-prod --state open --json url --jq '.[0].url // empty')
gh pr view "$PROD_CONFIG_PR" --repo "$MANIFEST_REPO" --web
```

Review đúng `PROD_SHA`, digest và check `validate`, rồi merge:

```bash
gh pr checks "$PROD_CONFIG_PR" --repo "$MANIFEST_REPO" --watch
gh pr merge "$PROD_CONFIG_PR" --repo "$MANIFEST_REPO" --merge
```

Mở Argo → `be-service-prod`, theo dõi rollout và chờ Healthy:

```bash
cd "$MANIFEST_DIR"
bash scripts/check.sh
kubectl --context "$CONTEXT" -n argocd get applications -o wide
for environment in dev staging prod; do
  curl -fsS --max-time 10 -H "Host: $environment.127.0.0.1.nip.io" \
    "http://127.0.0.1:$HTTP_PORT/version"
done
```

Kết quả: ba môi trường cùng title/version mới, `Synced / Healthy`, replica 1/2/3.
Image digest và `git_commit` có thể khác nhau vì mỗi nhánh có merge commit/build riêng.
Source backend vẫn ở feature vừa tạo; khi muốn quay về workspace chính, chỉ chạy `git switch main`
ở repo backend sau khi chắc chắn không còn thay đổi chưa commit.

Không cần gọi `build.sh`, `render.sh`, `deploy.sh` hay runner `demo.sh --scenario happy` cho các bước này.
Nếu một CI run lỗi, dừng ở bước đó và xem job/log. PR image chưa xuất hiện thì không chạy các lệnh
view/merge với biến rỗng. Không merge nhánh manifest `dev` sang `stg` hoặc `stg` sang `prod`.
Lưu các link PR và push runs để trình bày bằng chứng CI/CD.
