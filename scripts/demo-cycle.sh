#!/usr/bin/env bash
# Checkpointed stages of one seminar cycle. Used only by demo.sh.
get() { jq -r --arg key "$1" '.[$key] // empty' "$CYCLE"; }
put() {
    local temporary
    temporary=$(mktemp "$CYCLE_DIR/.state.XXXXXX")
    jq --arg key "$1" --arg value "$2" '.[$key] = $value' "$CYCLE" > "$temporary"
    mv "$temporary" "$CYCLE"
}
next_version() {
    local version=$1 major minor patch
    [[ "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "Invalid VERSION: $version"
    version=${version#v}; major=${version%%.*}; version=${version#*.}; minor=${version%%.*}; patch=${version#*.}
    printf 'v%s.%s.%s\n' "$major" "$minor" "$((patch+1))"
}
checkpoint() { put stage "$1"; say "[CHECKPOINT] Round $ROUND, stage $1 completed"; }
prepare_branch() {
    local clone=$1 branch=$2 base=$3 key=$4 saved
    git_demo -C "$clone" fetch origin >&2
    saved=$(get "$key")
    if [[ -n "$saved" ]]; then
        git -C "$clone" reset --hard >&2
        git -C "$clone" checkout -B "$branch" "$saved" >&2
        return
    fi
    git -C "$clone" reset --hard >&2
    git -C "$clone" checkout -B "$branch" "origin/$base" >&2
}
push_branch() {
    local clone=$1 branch=$2 key=$3 sha remote
    sha=$(git -C "$clone" rev-parse HEAD)
    [[ -z $(get "$key") || $(get "$key") == "$sha" ]] || fail 'Saved branch head differs from local commit'
    put "$key" "$sha" # Record intent before the network write.
    remote=$(git_demo -C "$clone" ls-remote --heads origin "refs/heads/$branch")
    if [[ -n "$remote" ]]; then
        [[ "${remote%%[[:space:]]*}" == "$sha" ]] || fail "Remote demo branch changed: $branch"
    else
        git_demo -C "$clone" push -u origin "$branch" >&2
    fi
}
check_snapshot() {
    local name=$1
    local deadline=$((SECONDS+WAIT_SECONDS))
    until bash "$SCRIPT_DIR/check.sh"; do
        ((SECONDS < deadline)) || fail "Readiness/runtime verification timeout: $name"
        sleep "$POLL_SECONDS"
    done
    cp "$STATE_DIR/release.json" "$CYCLE_DIR/$name.json"
}
assert_snapshot() {
    local name=$1 dev=$2 stg=$3 prod=$4
    jq -e --arg dev "$dev" --arg stg "$stg" --arg prod "$prod" '
      .environments.dev.image == $dev and .environments.staging.image == $stg and
      .environments.prod.image == $prod' "$CYCLE_DIR/$name.json" >/dev/null || fail "Environment isolation failed at $name"
}
assert_prod_unchanged() {
    local image revision
    image=$(k -n prod get deployment be-service -o json | jq -er '.spec.template.spec.containers[0].image')
    revision=$(head_sha "$CONFIG_REPO" prod)
    [[ "$image" == "$(jq -r .environments.prod.image "$CYCLE_DIR/baseline.json")" ]] || fail 'Prod digest changed during blocked build'
    [[ "$revision" == "$(jq -r .environments.prod.revision "$CYCLE_DIR/baseline.json")" ]] || fail 'Prod Git revision changed during blocked build'
}
promote_source() {
    local key=$1 base=$2 head=$3 expected=$4 number
    number=$(set -e; ensure_pr "${key}_pr" "$SOURCE_REPO" "$base" "$head" "Seminar $LABEL: $head to $base" 'Automated seminar promotion; checks must pass before merge.')
    merge_pr "${key}_sha" "$SOURCE_REPO" "$number" "$expected"
}
assert_no_prod_release_pr() {
    local rows
    rows=$(gh pr list --repo "$CONFIG_REPO" --base prod --head release-be-service-prod --state open --json number)
    [[ $(jq length <<< "$rows") == 0 ]] || fail 'Unexpected prod image PR after failed Docker build'
}
prod_dispatch() {
    local before rows run marker="$CYCLE_DIR/dispatch-intent.json" sha
    sha=$(get prod_sha)
    run=$(get prod_dispatch_run)
    if [[ -n "$DISPATCH_RUN" ]]; then
        [[ -f "$marker" ]] || fail '--dispatch-run requires an existing dispatch intent for this case'
        [[ -z "$run" || "$run" == "$DISPATCH_RUN" ]] || fail 'Saved dispatch run differs from --dispatch-run'
        put prod_dispatch_run "$DISPATCH_RUN"; run=$DISPATCH_RUN
        DISPATCH_RUN= # Apply the attached run only to this interrupted case, not future rounds.
    fi
    if [[ -z "$run" ]]; then
        if [[ ! -f "$marker" ]]; then
            before=$(gh run list --repo "$SOURCE_REPO" --workflow ci.yaml --branch prod --commit "$sha" --event workflow_dispatch --limit 100 --json databaseId)
            printf '%s\n' "$before" > "$marker"
            # POST may succeed even when the client loses its response: never repost on resume.
            gh workflow run ci.yaml --repo "$SOURCE_REPO" --ref prod
        fi
        before=$(cat "$marker")
        local deadline=$((SECONDS+WAIT_SECONDS))
        while :; do
            rows=$(gh run list --repo "$SOURCE_REPO" --workflow ci.yaml --branch prod --commit "$sha" --event workflow_dispatch --limit 100 --json databaseId)
            rows=$(jq --argjson before "$before" '[.[] | select(.databaseId as $id | all($before[]; .databaseId != $id))]' <<< "$rows")
            [[ $(jq length <<< "$rows") -le 1 ]] || fail 'Ambiguous dispatch; use --resume SESSION --dispatch-run ID after checking Actions'
            run=$(jq -r '.[0].databaseId // empty' <<< "$rows")
            [[ -z "$run" ]] || break
            ((SECONDS < deadline)) || fail 'Dispatch POST uncertain. Inspect Actions; attach an existing run with --dispatch-run. If no run exists, remove dispatch-intent.json only after confirming it was never accepted.'
            sleep "$POLL_SECONDS"
        done
        put prod_dispatch_run "$run"
    fi
    wait_run "$run" "$sha" workflow_dispatch prod
    release_pr prod "$sha" "$run"
}
wait_rollout_failure() {
    local deadline=$((SECONDS+WAIT_SECONDS)) app deployment pods response bad_image old_image
    bad_image=$(get prod_image); old_image=$(jq -r .environments.prod.image "$CYCLE_DIR/baseline.json")
    k -n argocd annotate application be-service-prod argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    while :; do
        app=$(k -n argocd get application be-service-prod -o json)
        deployment=$(k -n prod get deployment be-service -o json)
        if jq -e --arg sha "$(get bad_merge)" '.status.sync.status == "Synced" and .status.sync.revision == $sha and .status.health.status == "Degraded"' <<< "$app" >/dev/null &&
            jq -e --arg image "$bad_image" '.spec.template.spec.containers[0].image == $image and
              .spec.template.spec.containers[0].readinessProbe.httpGet.port == 8081 and
              any(.status.conditions[]?; .type == "Progressing" and .status == "False" and .reason == "ProgressDeadlineExceeded")' <<< "$deployment" >/dev/null; then break; fi
        ((SECONDS < deadline)) || fail 'Prod did not reach the expected readiness-only rollout failure'
        sleep "$POLL_SECONDS"
    done
    pods=$(k -n prod get pods -l app=be-service -o json)
    jq -e --arg old "$old_image" --arg bad "$bad_image" '
      ([.items[] | select(.metadata.deletionTimestamp == null and .spec.containers[0].image == $old and .status.containerStatuses[0].ready == true)] | length) == 3 and
      any(.items[]; .metadata.deletionTimestamp == null and .spec.containers[0].image == $bad and
        .status.phase == "Running" and .status.containerStatuses[0].ready == false and .status.containerStatuses[0].restartCount == 0)
      ' <<< "$pods" >/dev/null || fail 'Fault did not preserve old prod pods or created a crash loop'
    response=$(curl -fsS --max-time 10 -H 'Host: prod.127.0.0.1.nip.io' "http://127.0.0.1:$HTTP_PORT/version")
    jq -e --argjson baseline "$(jq .environments.prod "$CYCLE_DIR/baseline.json")" '.version == $baseline.version and .git_commit == $baseline.source_sha' <<< "$response" >/dev/null || fail 'Prod stopped serving its baseline during readiness failure'
    printf '%s\n' "$app" > "$CYCLE_DIR/prod-degraded.json"
    printf '%s\n' "$deployment" > "$CYCLE_DIR/prod-failed-deployment.json"
    printf '%s\n' "$pods" > "$CYCLE_DIR/prod-failed-pods.json"
    printf '%s\n' "$response" > "$CYCLE_DIR/prod-serving-baseline.json"
    for env in dev staging; do
        k -n argocd get application "be-service-$env" -o json | jq -e '.status.health.status == "Healthy" and .status.sync.status == "Synced"' >/dev/null || fail "$env affected by prod fault"
    done
}
cycle() {
    local stage feature fault rollback number sha run stg_old prod_old
    stage=$(get stage); feature="feature/seminar-$LABEL"; fault="demo/prod-fault-$LABEL"; rollback="rollback/prod-$LABEL"
    [[ $(get scenario) == "$SCENARIO" || -z $(get scenario) ]] || fail 'Saved case differs from the session'
    say "[ROUND] $ROUND/$COUNT — $SCENARIO — $LABEL (saved stage $stage)"
    if ((stage == 0)); then
        if [[ ! -f "$CYCLE_DIR/baseline.json" ]]; then check_snapshot baseline; fi
        git_demo -C "$BACKEND_CLONE" fetch origin
        if [[ -z $(get version) ]]; then
            put version "$(next_version "$(git -C "$BACKEND_CLONE" show origin/dev:VERSION)")"
        fi
        checkpoint 1; stage=1
    fi
    stg_old=$(jq -r .environments.staging.image "$CYCLE_DIR/baseline.json")
    prod_old=$(jq -r .environments.prod.image "$CYCLE_DIR/baseline.json")
    if ((stage == 1)); then
        say '[1] Feature -> dev -> image PR -> Argo dev'
        prepare_branch "$BACKEND_CLONE" "$feature" dev feature_head
        if [[ -z $(get feature_head) ]]; then
            printf '%s\n' "$(get version)" > "$BACKEND_CLONE/VERSION"
            awk -v title="Backend API Service - Seminar $LABEL" '
              /ServiceName: "/ { sub(/ServiceName: "[^"]*"/, "ServiceName: \"" title "\""); changed++ } { print }
              END { if (changed != 1) exit 1 }' "$BACKEND_CLONE/main.go" > "$CYCLE_DIR/main.go"
            mv "$CYCLE_DIR/main.go" "$BACKEND_CLONE/main.go"
            (cd "$BACKEND_CLONE" || exit; gofmt -w main.go; bash scripts/check-quality.sh; git diff --check; git add main.go VERSION; git commit -m "feat: seminar $LABEL $(get version)")
        fi
        push_branch "$BACKEND_CLONE" "$feature" feature_head
        promote_source dev dev "$feature" "$(get feature_head)"
        sha=$(get dev_sha); run=$(set -e; find_run dev_run dev "$sha" push); wait_run "$run" "$sha" push dev
        release_pr dev "$sha" "$run"
        merge_pr dev_manifest_merge "$CONFIG_REPO" "$(get dev_release_pr)" "$(get dev_release_head)"
        check_snapshot dev-deployed
        assert_snapshot dev-deployed "$(get dev_image)" "$stg_old" "$prod_old"
        checkpoint 2; stage=2
    fi
    if ((stage == 2)); then
        say '[2] dev -> stg -> image PR -> Argo staging'
        promote_source stg stg dev "$(get dev_sha)"
        sha=$(get stg_sha); run=$(set -e; find_run stg_run stg "$sha" push); wait_run "$run" "$sha" push stg
        release_pr stg "$sha" "$run"
        merge_pr stg_manifest_merge "$CONFIG_REPO" "$(get stg_release_pr)" "$(get stg_release_head)"
        check_snapshot stg-deployed
        assert_snapshot stg-deployed "$(get dev_image)" "$(get stg_image)" "$prod_old"
        checkpoint 3; stage=3
    fi
    if ((stage == 3)) && [[ "$SCENARIO" == happy ]]; then
        say '[3] Happy case: stg -> prod -> image PR -> Argo prod Healthy'
        export FAULT_TOUCHED=true
        gh variable set DEMO_FAIL_PROD_BUILD --repo "$SOURCE_REPO" --body false
        promote_source prod prod stg "$(get stg_sha)"
        sha=$(get prod_sha); run=$(set -e; find_run prod_run prod "$sha" push); wait_run "$run" "$sha" push prod
        release_pr prod "$sha" "$run"
        merge_pr prod_manifest_merge "$CONFIG_REPO" "$(get prod_release_pr)" "$(get prod_release_head)"
        check_snapshot prod-deployed
        assert_snapshot prod-deployed "$(get dev_image)" "$(get stg_image)" "$(get prod_image)"
        checkpoint 7; stage=7
    fi
    if ((stage == 3)) && [[ "$SCENARIO" == failure ]]; then
        say '[3] stg -> prod: expected Docker build failure'
        export FAULT_TOUCHED=true
        gh variable set DEMO_FAIL_PROD_BUILD --repo "$SOURCE_REPO" --body true
        promote_source prod prod stg "$(get stg_sha)"
        sha=$(get prod_sha); run=$(set -e; find_run prod_failed_run prod "$sha" push); wait_run "$run" "$sha" push prod
        verify_build_failure "$SOURCE_REPO" "$run"
        assert_prod_unchanged; assert_no_prod_release_pr
        check_snapshot prod-build-blocked
        assert_snapshot prod-build-blocked "$(get dev_image)" "$(get stg_image)" "$prod_old"
        gh variable set DEMO_FAIL_PROD_BUILD --repo "$SOURCE_REPO" --body false
        checkpoint 4; stage=4
    fi
    if ((stage == 4)); then
        say '[4] Publish signed prod image, then deploy marked readiness fault'
        export FAULT_TOUCHED=true
        gh variable set DEMO_FAIL_PROD_BUILD --repo "$SOURCE_REPO" --body false
        [[ $(head_sha "$SOURCE_REPO" prod) == "$(get prod_sha)" ]] || fail 'Backend prod changed since this round'
        prod_dispatch
        prepare_branch "$MANIFEST_CLONE" "$fault" prod fault_head
        if [[ -z $(get fault_head) ]]; then
            # Copy exactly the validated release PR image file, not a moving branch.
            git -C "$MANIFEST_CLONE" restore --source "$(get prod_release_head)" -- apps/be-service/base/kustomization.yaml
            yq -i '.metadata.annotations."seminar.gitops.io/scenario" = "prod-readiness-failure" |
              .spec.template.spec.containers[0].name = "app" |
              .spec.template.spec.containers[0].readinessProbe.httpGet.port = 8081' "$MANIFEST_CLONE/apps/be-service/envs/prod/deployment-env-patch.yaml"
            (cd "$MANIFEST_CLONE" || exit; bash scripts/validate-manifests.sh; git diff --check; git add apps; git commit -m "demo: prod readiness failure $LABEL")
        fi
        push_branch "$MANIFEST_CLONE" "$fault" fault_head
        number=$(set -e; ensure_pr fault_pr "$CONFIG_REPO" prod "$fault" "Seminar $LABEL: prod rollout failure" 'Deploy the signed prod artifact with an explicit readiness-only fault; old pods keep serving.')
        wait_checks "$CONFIG_REPO" "$number"
        if [[ $(gh pr view "$(get prod_release_pr)" --repo "$CONFIG_REPO" --json state --jq .state) == OPEN ]]; then
            gh pr close "$(get prod_release_pr)" --repo "$CONFIG_REPO"
        fi
        merge_pr bad_merge "$CONFIG_REPO" "$number" "$(get fault_head)"
        checkpoint 5; stage=5
    fi
    if ((stage == 5)); then
        say '[5] Assert Argo Degraded, failed rollout, old prod still serving'
        wait_rollout_failure
        checkpoint 6; stage=6
    fi
    if ((stage == 6)); then
        say '[6] Revert the complete fault merge via PR; Argo restores baseline prod'
        prepare_branch "$MANIFEST_CLONE" "$rollback" prod rollback_head
        if [[ -z $(get rollback_head) ]]; then
            [[ $(git -C "$MANIFEST_CLONE" rev-parse HEAD) == "$(get bad_merge)" ]] || fail 'Manifest prod changed before rollback; manual review required'
            git -C "$MANIFEST_CLONE" revert -m 1 --no-edit "$(get bad_merge)"
            (cd "$MANIFEST_CLONE" || exit; bash scripts/validate-manifests.sh; git diff --check)
        fi
        push_branch "$MANIFEST_CLONE" "$rollback" rollback_head
        number=$(set -e; ensure_pr rollback_pr "$CONFIG_REPO" prod "$rollback" "Seminar $LABEL: rollback prod" 'Restore the recorded prod baseline image and readiness configuration through GitOps; do not rebuild.')
        merge_pr rollback_merge "$CONFIG_REPO" "$number" "$(get rollback_head)"
        check_snapshot rollback-verified
        assert_snapshot rollback-verified "$(get dev_image)" "$(get stg_image)" "$prod_old"
        git_demo -C "$MANIFEST_CLONE" fetch origin prod
        git -C "$MANIFEST_CLONE" diff --exit-code "$(jq -r .environments.prod.revision "$CYCLE_DIR/baseline.json")" "$(get rollback_merge)" -- apps
        k -n prod get deployment be-service -o json | jq -e '
          .spec.template.spec.containers[0].readinessProbe.httpGet.port == 8080 and
          .spec.template.spec.containers[0].livenessProbe.httpGet.port == 8080 and
          .metadata.annotations["seminar.gitops.io/scenario"] == null' >/dev/null || fail 'Rollback left the readiness fault enabled'
        gh variable set DEMO_FAIL_PROD_BUILD --repo "$SOURCE_REPO" --body false
        checkpoint 7
    fi
    if [[ "$SCENARIO" == happy ]]; then
        say "[PASS] Round $ROUND happy: dev/staging/prod $(get version), all Healthy"
    else
        say "[PASS] Round $ROUND failure: dev/staging $(get version), prod baseline restored"
    fi
}
