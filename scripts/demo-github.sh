#!/usr/bin/env bash
# shellcheck disable=SC2153
# GitHub/Git operations used by demo.sh. All waits have a deadline.
git_demo() { GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }
head_sha() { gh api "repos/$1/branches/$2" --jq .commit.sha; }
wait_checks() {
    local repo=$1 pr=$2 deadline=$((SECONDS+WAIT_SECONDS)) checks code
    while :; do
        code=0
        checks=$(gh pr checks "$pr" --repo "$repo" --json bucket,name,link 2>&1) || code=$?
        # GitHub may not have registered jobs yet immediately after PR creation.
        if [[ "$code" == 1 && "$checks" == "no checks reported on the '"*"' branch" ]]; then
            checks='[]'
            printf '[WAIT] Checks not registered yet for %s#%s\n' "$repo" "$pr" >&2
        elif [[ "$code" != 0 && "$code" != 8 ]]; then
            fail "Cannot read checks for $repo#$pr: $checks"
        fi
        jq -e 'type == "array"' <<< "$checks" >/dev/null || fail "Invalid checks response for $repo#$pr: $checks"
        if jq -e --arg backend "${SOURCE_REPO:-}" --arg repo "$repo" '
          any(.[]; .bucket == "fail" or .bucket == "cancel" or
            (.bucket == "skipping" and ($repo != $backend or
              (.name != "Publish immutable image and release metadata" and .name != "Propose image update"))))' <<< "$checks" >/dev/null; then
            fail "Checks failed/unexpectedly skipped for $repo#$pr: $checks"
        fi
        if jq -e --arg backend "${SOURCE_REPO:-}" --arg repo "$repo" '
          length > 0 and
          (if $repo == $backend then
            any(.[]; .name == "Test, race, vet, and format" and .bucket == "pass") and
            any(.[]; .name == "Build once and security gate" and .bucket == "pass")
          else any(.[]; .name == "validate" and .bucket == "pass") end) and
          all(.[]; .bucket == "pass" or (.bucket == "skipping" and $repo == $backend and
            (.name == "Publish immutable image and release metadata" or .name == "Propose image update")))
          ' <<< "$checks" >/dev/null; then return 0; fi
        ((SECONDS < deadline)) || fail "Checks timeout for $repo#$pr (no checks also blocks merge)"
        sleep "$POLL_SECONDS"
    done
}
ensure_pr() {
    local key=$1 repo=$2 base=$3 head=$4 title=$5 body=$6 number rows
    number=$(get "$key")
    if [[ -z "$number" ]]; then
        rows=$(gh pr list --repo "$repo" --base "$base" --head "$head" --state all --limit 100 --json number,title,state)
        number=$(jq -r --arg title "$title" '[.[] | select(.title == $title)] | if length == 1 then .[0].number else empty end' <<< "$rows")
        [[ $(jq --arg title "$title" '[.[] | select(.title == $title)] | length' <<< "$rows") -le 1 ]] || fail "Ambiguous PR: $title"
        if [[ -z "$number" ]]; then
            printf '%s\n' "$body" > "$CYCLE_DIR/pr-body.txt"
            # If POST returns an ambiguous error, resume discovers the PR by title.
            gh pr create --repo "$repo" --base "$base" --head "$head" --title "$title" --body-file "$CYCLE_DIR/pr-body.txt" >&2
            rows=$(gh pr list --repo "$repo" --base "$base" --head "$head" --state all --limit 100 --json number,title)
            number=$(jq -er --arg title "$title" '[.[] | select(.title == $title)] | select(length == 1) | .[0].number' <<< "$rows")
        fi
        put "$key" "$number"
    fi
    printf '%s' "$number"
}
merge_pr() {
    local key=$1 repo=$2 number=$3 expected=$4 pr sha
    pr=$(gh pr view "$number" --repo "$repo" --json state,headRefOid,mergeCommit,url)
    [[ $(jq -r .headRefOid <<< "$pr") == "$expected" ]] || fail "PR head changed: $repo#$number"
    case $(jq -r .state <<< "$pr") in
        MERGED) ;;
        OPEN)
            wait_checks "$repo" "$number"
            gh pr merge "$number" --repo "$repo" --merge --match-head-commit "$expected" >&2
            pr=$(gh pr view "$number" --repo "$repo" --json state,mergeCommit,url)
            [[ $(jq -r .state <<< "$pr") == MERGED ]] || fail "PR awaits review/merge queue: $repo#$number; resume after merge" ;;
        *) fail "PR was closed without merging: $repo#$number" ;;
    esac
    sha=$(jq -er '.mergeCommit.oid' <<< "$pr")
    put "$key" "$sha"
    printf '%s\n' "$pr" > "$CYCLE_DIR/$key-pr.json"
}
find_run() {
    local key=$1 branch=$2 sha=$3 event=$4 run deadline=$((SECONDS+WAIT_SECONDS)) rows
    run=$(get "$key")
    if [[ -z "$run" ]]; then
        while :; do
            rows=$(gh run list --repo "$SOURCE_REPO" --workflow ci.yaml --branch "$branch" --commit "$sha" --event "$event" --limit 100 --json databaseId,headSha,event)
            run=$(jq -r 'if length == 1 then .[0].databaseId else empty end' <<< "$rows")
            [[ $(jq length <<< "$rows") -le 1 ]] || fail "Multiple runs for $sha/$event; stop rather than select the wrong run"
            [[ -z "$run" ]] || break
            ((SECONDS < deadline)) || fail "No CI run for $sha/$event"
            sleep "$POLL_SECONDS"
        done
        put "$key" "$run"
    fi
    printf '%s' "$run"
}
wait_run() {
    local run=$1 sha=$2 event=$3 branch=$4 deadline=$((SECONDS+WAIT_SECONDS)) result
    while :; do
        result=$(gh run view "$run" --repo "$SOURCE_REPO" --json status,conclusion,headSha,headBranch,event,url,jobs)
        jq -e --arg sha "$sha" --arg event "$event" --arg branch "$branch" '.headSha == $sha and .event == $event and .headBranch == $branch' <<< "$result" >/dev/null || fail "Wrong run $run"
        printf '%s\n' "$result" > "$CYCLE_DIR/run-$run.json"
        [[ $(jq -r .status <<< "$result") != completed ]] || return 0
        ((SECONDS < deadline)) || fail "CI timeout: $run; resume to wait again"
        sleep "$POLL_SECONDS"
    done
}
verify_build_failure() {
    local result log
    result=$(gh run view "$2" --repo "$1" --json jobs)
    jq -e '
      any(.jobs[]; .name == "Test, race, vet, and format" and .conclusion == "success") and
      any(.jobs[]; .name == "Build once and security gate" and .conclusion == "failure" and
        any(.steps[]; .name == "Build the single local image" and .conclusion == "failure")) and
      any(.jobs[]; .name == "Publish immutable image and release metadata" and .conclusion == "skipped") and
      any(.jobs[]; .name == "Propose image update" and .conclusion == "skipped")
    ' <<< "$result" >/dev/null || fail 'Prod failure was not the expected Docker build gate'
    log=$(gh run view "$2" --repo "$1" --log-failed)
    [[ "$log" =~ \#[0-9]+[[:space:]][0-9.]+[[:space:]]SEMINAR:[[:space:]]intentional[[:space:]]prod[[:space:]]build[[:space:]]failure ]] || fail 'Docker failed without executing the intentional seminar fault'
    if [[ -n "${CYCLE_DIR:-}" ]]; then printf '%s\n' "$log" > "$CYCLE_DIR/prod-build-failure.log"; fi
}
release_pr() {
    local branch=$1 sha=$2 run=$3 result artifact rows number head image env=$1 key="${1}_release_pr"
    result=$(cat "$CYCLE_DIR/run-$run.json")
    jq -e '
      any(.jobs[]; .name == "Test, race, vet, and format" and .conclusion == "success") and
      any(.jobs[]; .name == "Build once and security gate" and .conclusion == "success") and
      any(.jobs[]; .name == "Publish immutable image and release metadata" and .conclusion == "success") and
      any(.jobs[]; .name == "Propose image update" and (.conclusion == "success" or .conclusion == "failure"))
    ' <<< "$result" >/dev/null || fail "Release pipeline $run did not publish/sign/attest successfully"
    artifact="$CYCLE_DIR/artifact-$branch"
    if [[ ! -f "$artifact/release.json" ]]; then
        mkdir -p "$artifact"
        gh run download "$run" --repo "$SOURCE_REPO" --name "be-service-release-$sha" --dir "$artifact"
    fi
    jq -e --arg sha "$sha" --arg version "$(get version)" --arg image "$IMAGE" '
      .source_sha == $sha and .version == $version and .image == $image and
      (.digest | test("^sha256:[0-9a-f]{64}$"))' "$artifact/release.json" >/dev/null || fail 'Release metadata does not match this cycle'
    image=$(jq -r '.image + "@" + .digest' "$artifact/release.json")
    put "${branch}_image" "$image"
    number=$(get "$key")
    if [[ -z "$number" ]]; then
        rows=$(gh pr list --repo "$CONFIG_REPO" --base "$branch" --head "release-be-service-$branch" --state open --json number)
        [[ $(jq length <<< "$rows") -le 1 ]] || fail 'Multiple image PRs'
        number=$(jq -r '.[0].number // empty' <<< "$rows")
        if [[ -z "$number" ]]; then
            [[ $(jq -r .conclusion <<< "$result") == failure ]] || fail 'Successful pipeline did not create the image PR'
            echo "[RECOVERY] $run: publish succeeded, PR job failed; verify the existing release branch" >&2
            git_demo -C "$MANIFEST_CLONE" fetch origin "release-be-service-$branch" >&2
            # The same signed artifact is used; validation checks still gate merge.
            printf 'Recover published release from CI %s\nImage: %s\nSource: %s\n' "$run" "$image" "$sha" > "$CYCLE_DIR/pr-body.txt"
            gh pr create --repo "$CONFIG_REPO" --base "$branch" --head "release-be-service-$branch" \
                --title "release($branch): $(get version)" --body-file "$CYCLE_DIR/pr-body.txt" >&2
            rows=$(gh pr list --repo "$CONFIG_REPO" --base "$branch" --head "release-be-service-$branch" --state open --json number)
            number=$(jq -er 'select(length == 1) | .[0].number' <<< "$rows")
        fi
        put "$key" "$number"
    fi
    head=$(gh pr view "$number" --repo "$CONFIG_REPO" --json headRefOid --jq .headRefOid)
    git_demo -C "$MANIFEST_CLONE" fetch origin "refs/pull/$number/head" >&2
    [[ $(git -C "$MANIFEST_CLONE" rev-parse FETCH_HEAD) == "$head" ]] || fail 'Image PR changed while fetching'
    git -C "$MANIFEST_CLONE" archive "$head" apps | tar -x -C "$artifact"
    [[ "$env" != stg ]] || env=staging
    [[ $(kustomize build "$artifact/apps/be-service/envs/$env" | yq -er 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image') == "$image" ]] || fail 'Image PR differs from the published digest'
    [[ $(gh pr diff "$number" --repo "$CONFIG_REPO" --name-only) == apps/be-service/base/kustomization.yaml ]] || fail 'Image PR contains unexpected configuration changes'
    put "${branch}_release_head" "$head"
    wait_checks "$CONFIG_REPO" "$number"
}
