#!/usr/bin/env bash
set -Eeuo pipefail
usage() {
    cat <<'HELP'
Usage: bash scripts/demo.sh [--count N | --resume SESSION] [--preflight]
       bash scripts/demo.sh --resume SESSION --dispatch-run RUN_ID
Run the agreed GitHub/Argo release+failure+rollback scenario sequentially.
--count N          Number of cycles (1..1000), default 1. Real builds and PR merges.
--resume SESSION   Continue an interrupted session using its saved checkpoints.
--dispatch-run ID  Attach the verified existing prod dispatch after an ambiguous POST.
--preflight        Check credentials, repo state and deployed baseline only; no releases.
--help             Show this message without requiring tools.
State/logs: .local/demos/SESSION. Stops on any unexpected result; never force pushes.
HELP
}
COUNT=1; RESUME=; PREFLIGHT=false; DISPATCH_RUN=; count_set=false
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --count|--resume|--dispatch-run)
            (($# >= 2)) || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in --count) COUNT=$2; count_set=true ;; --resume) RESUME=$2 ;; --dispatch-run) DISPATCH_RUN=$2 ;; esac
            shift 2 ;;
        --preflight) PREFLIGHT=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "$COUNT" =~ ^[1-9][0-9]{0,3}$ && "$COUNT" -le 1000 ]] || { echo 'Count must be 1..1000' >&2; exit 2; }
[[ -z "$RESUME" || "$RESUME" =~ ^[a-zA-Z0-9-]+$ ]] || { echo 'Invalid session ID' >&2; exit 2; }
[[ -z "$RESUME" || "$count_set" == false ]] || { echo 'Resume uses the saved count' >&2; exit 2; }
[[ -z "$DISPATCH_RUN" || ( -n "$RESUME" && "$DISPATCH_RUN" =~ ^[1-9][0-9]*$ ) ]] || { echo '--dispatch-run requires --resume and a numeric run ID' >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-common.sh
source "$SCRIPT_DIR/local-common.sh"
# shellcheck source=demo-github.sh
source "$SCRIPT_DIR/demo-github.sh"
# shellcheck source=demo-cycle.sh
source "$SCRIPT_DIR/demo-cycle.sh"
init_local
require_tools gh kubectl curl kustomize yq docker go
POLL_SECONDS=${DEMO_POLL_SECONDS:-10}; WAIT_SECONDS=${DEMO_WAIT_SECONDS:-3600}
[[ "$POLL_SECONDS" =~ ^[1-9][0-9]*$ && "$WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail 'Demo wait/poll seconds must be positive integers'
IMAGE="ghcr.io/$(printf '%s' "$SOURCE_REPO" | tr '[:upper:]' '[:lower:]')"
export IMAGE
mkdir -p "$STATE_DIR/demos"
[[ ! -L "$STATE_DIR/demos" ]] || fail 'Demo state cannot be a symlink'
LOCK="$STATE_DIR/demos/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    fail "Another runner owns $LOCK. If it exited, inspect its pid/host then remove only this empty lock directory and pid file."
fi
printf '%s %s\n' "$$" "$(hostname)" > "$LOCK/owner"
cleanup() {
    local code=$?
    trap - EXIT
    # Best effort; a network failure is reported, not silently treated as cleanup success.
    if [[ "${FAULT_TOUCHED:-false}" == true ]]; then
        gh variable set DEMO_FAIL_PROD_BUILD --repo "$SOURCE_REPO" --body false || echo '[ERROR] Reset DEMO_FAIL_PROD_BUILD=false manually; GitHub unavailable' >&2
    fi
    rm -f "$LOCK/owner"; rmdir "$LOCK"
    if ((code != 0)) && [[ -n "${SESSION:-}" ]]; then
        if [[ "${LOG_STARTED:-false}" == true ]]; then
            tail -n 25 "$SESSION_DIR/session.log" >&3
            printf '[STOP] Resume: bash scripts/demo.sh --resume %s\n' "$SESSION" >&3
        else
            echo "[STOP] Saved state. Resume: bash scripts/demo.sh --resume $SESSION" >&2
        fi
    fi
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
preflight() {
    local repo variable prs runs
    gh auth status >/dev/null
    for repo in "$SOURCE_REPO" "$CONFIG_REPO"; do
        for branch in dev stg prod; do head_sha "$repo" "$branch" >/dev/null; done
        gh secret list --repo "$repo" --json name | jq -e 'any(.[]; .name == "CONFIG_REPO_PAT")' >/dev/null || fail "Missing CONFIG_REPO_PAT in $repo"
    done
    variable=$(gh variable get ENABLE_GITOPS_RELEASE --repo "$SOURCE_REPO")
    [[ "$variable" == true ]] || fail 'Run build.sh during bootstrap to enable GitOps release'
    [[ $(gh variable get CONFIG_REPO --repo "$SOURCE_REPO") == "$CONFIG_REPO" ]] || fail 'Backend CONFIG_REPO does not match local configuration'
    [[ $(gh variable get SOURCE_REPO --repo "$CONFIG_REPO") == "$SOURCE_REPO" ]] || fail 'Manifest SOURCE_REPO mismatch'
    [[ $(gh variable get IMAGE --repo "$CONFIG_REPO") == "$IMAGE" ]] || fail 'Manifest IMAGE mismatch'
    variable=$(gh variable list --repo "$SOURCE_REPO" --json name,value | jq -r '[.[] | select(.name == "DEMO_FAIL_PROD_BUILD")][0].value // "false"')
    [[ "$variable" == false ]] || fail 'Reset DEMO_FAIL_PROD_BUILD=false before a new session'
    runs=$(gh run list --repo "$SOURCE_REPO" --workflow ci.yaml --limit 100 --json status,event,headBranch)
    jq -e 'all(.[]; .status == "completed" or .event == "pull_request" or
      (.headBranch != "dev" and .headBranch != "stg" and .headBranch != "prod"))' <<< "$runs" >/dev/null || fail 'Wait for existing release CI runs before a new session'
    for repo in "$SOURCE_REPO" "$CONFIG_REPO"; do
        prs=$(gh pr list --repo "$repo" --state open --limit 100 --json number,baseRefName)
        jq -e 'all(.[]; (.baseRefName != "dev" and .baseRefName != "stg" and .baseRefName != "prod"))' <<< "$prs" >/dev/null || fail "Resolve open release PRs in $repo before a new session"
    done
    bash "$SCRIPT_DIR/check.sh"
}
if [[ "$PREFLIGHT" == true ]]; then preflight; echo '[PASS] Ready for demo'; exit 0; fi
SESSION=${RESUME:-$(date -u +%Y%m%dT%H%M%SZ)-$$}
SESSION_DIR="$STATE_DIR/demos/$SESSION"
if [[ -n "$RESUME" ]]; then
    [[ -f "$SESSION_DIR/session.json" && ! -L "$SESSION_DIR" ]] || fail 'Unknown session'
    jq -e --argjson config "$LOCAL_CONFIG" '.config == $config' "$SESSION_DIR/session.json" >/dev/null || fail 'Resume configuration differs from the saved session'
    COUNT=$(jq -er .count "$SESSION_DIR/session.json")
else
    for existing in "$STATE_DIR"/demos/*/session.json; do
        [[ ! -f "$existing" ]] || jq -e '.complete == true' "$existing" >/dev/null || fail "Unfinished session: $(dirname "$existing"); resume it first"
    done
    preflight
    mkdir "$SESSION_DIR"
    jq -n --argjson config "$LOCAL_CONFIG" --argjson count "$COUNT" '{config:$config,count:$count,complete:false}' > "$SESSION_DIR/session.json"
fi
# Clones isolate generated commits from the user's main checkout.
export BACKEND_CLONE="$SESSION_DIR/backend" MANIFEST_CLONE="$SESSION_DIR/manifests"
for repo in backend manifests; do
    directory="$SESSION_DIR/$repo"
    [[ ! -L "$directory" ]] || fail 'Clone cannot be a symlink'
    if [[ ! -d "$directory/.git" ]]; then
        url="https://github.com/$SOURCE_REPO.git"; [[ "$repo" != manifests ]] || url="$CONFIG_REPO_URL"
        git_demo clone --quiet "$url" "$directory"
    fi
    identity=$(gh api user --jq '.login + " <" + (.id|tostring) + "+" + .login + "@users.noreply.github.com>"')
    git -C "$directory" config user.name "${identity%% <*}"
    git -C "$directory" config user.email "$(printf '%s' "${identity#*<}" | tr -d '>')"
    git -C "$directory" config commit.gpgsign false
    git -C "$directory" config core.hooksPath /dev/null
 done
exec 3>&1
exec >> "$SESSION_DIR/session.log" 2>&1
LOG_STARTED=true
say() { printf '%s\n' "$*"; printf '%s\n' "$*" >&3; }
say "[SESSION] $SESSION — $COUNT cycle(s). State: $SESSION_DIR"
for ((ROUND=1; ROUND<=COUNT; ROUND++)); do
    CYCLE_DIR="$SESSION_DIR/$(printf '%04d' "$ROUND")"; mkdir -p "$CYCLE_DIR"
    CYCLE="$CYCLE_DIR/state.json"; LABEL="$SESSION-$(printf '%04d' "$ROUND")"; export LABEL
    [[ -f "$CYCLE" ]] || printf '{"stage":0}\n' > "$CYCLE"
    cycle
 done
temporary=$(mktemp "$SESSION_DIR/.session.XXXXXX")
jq '.complete = true' "$SESSION_DIR/session.json" > "$temporary"; mv "$temporary" "$SESSION_DIR/session.json"
say "[PASS] Completed $COUNT cycle(s). Evidence: $SESSION_DIR"
