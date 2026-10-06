#!/usr/bin/env bash
# Shared configuration and metadata helpers. This file does not deploy anything.
set -Eeuo pipefail
LOCAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LOCAL_ROOT="$(cd "$LOCAL_SCRIPT_DIR/.." && pwd -P)"

fail() { echo "[ERROR] $*" >&2; exit 1; }
require_tools() {
    local tool
    for tool in "$@"; do command -v "$tool" >/dev/null || fail "Missing tool: $tool"; done
}
trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}
# Normalize absolute paths without requiring GNU realpath or Python.
absolute_path() {
    local path=$1 part result=''
    local components=() normalized=()
    [[ "$path" == /* ]] || path="$LOCAL_ROOT/$path"
    IFS=/ read -r -a components <<< "$path"
    for part in ${components[@]+"${components[@]}"}; do
        case "$part" in
            ''|.) ;;
            ..) if ((${#normalized[@]})); then unset "normalized[$((${#normalized[@]}-1))]"; fi ;;
            *) normalized+=("$part") ;;
        esac
    done
    for part in ${normalized[@]+"${normalized[@]}"}; do result="$result/$part"; done
    printf '%s' "${result:-/}"
}
github_repository() {
    local url=$1
    case "$url" in
        https://github.com/*) url=${url#https://github.com/} ;;
        git@github.com:*) url=${url#git@github.com:} ;;
        ssh://git@github.com/*) url=${url#ssh://git@github.com/} ;;
        *) fail 'CONFIG_REPO_URL must be a GitHub repository URL without credentials' ;;
    esac
    url=${url%.git}
    [[ "$url" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Invalid GitHub repository URL'
    printf '%s' "$url"
}
load_config() {
    local key value line port path part
    local overrides=() components=()
    for key in BE_SOURCE_DIR CLUSTER_NAME HTTP_PORT HTTPS_PORT STATE_DIR CONFIG_REPO_URL SOURCE_REPO; do
        if value=$(printenv "$key"); then overrides+=("$key=$value"); fi
    done
    BE_SOURCE_DIR=../be-service; CLUSTER_NAME=gitops-local
    HTTP_PORT=8088; HTTPS_PORT=8443; STATE_DIR=.local
    CONFIG_REPO_URL=; SOURCE_REPO=
    if [[ -f "$LOCAL_ROOT/.env.local" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line=$(trim "$line")
            [[ -z "$line" || "$line" == \#* ]] && continue
            [[ "$line" == *=* ]] || fail "Expected KEY=value in .env.local"
            key=$(trim "${line%%=*}"); value=$(trim "${line#*=}")
            case "$key" in BE_SOURCE_DIR|CLUSTER_NAME|HTTP_PORT|HTTPS_PORT|STATE_DIR|CONFIG_REPO_URL|SOURCE_REPO) ;;
                *) fail "Unknown local configuration: $key" ;; esac
            if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then value=${value:1:${#value}-2}; fi
            printf -v "$key" '%s' "$value"
        done < "$LOCAL_ROOT/.env.local"
    fi
    for line in ${overrides[@]+"${overrides[@]}"}; do printf -v "${line%%=*}" '%s' "${line#*=}"; done
    [[ "$CLUSTER_NAME" =~ ^[a-z][a-z0-9-]{0,40}$ ]] || fail 'Invalid CLUSTER_NAME'
    for key in HTTP_PORT HTTPS_PORT; do
        value=${!key}
        [[ "$value" =~ ^[0-9]{1,5}$ ]] || fail "Invalid $key"
        port=$((10#$value))
        ((port >= 1 && port <= 65535)) || fail "Invalid $key"
        printf -v "$key" '%s' "$port"
    done
    [[ "$HTTP_PORT" != "$HTTPS_PORT" ]] || fail 'HTTP_PORT and HTTPS_PORT must differ'
    [[ -n "$BE_SOURCE_DIR" && -n "$STATE_DIR" ]] || fail 'Paths must not be empty'
    # Reject traversal before normalizing, and symlinks in the runtime path.
    IFS=/ read -r -a components <<< "$STATE_DIR"
    for part in ${components[@]+"${components[@]}"}; do [[ "$part" != .. ]] || fail 'STATE_DIR cannot contain ..'; done
    STATE_DIR=$(absolute_path "$STATE_DIR")
    [[ "$STATE_DIR" == "$LOCAL_ROOT/.local" || "$STATE_DIR" == "$LOCAL_ROOT/.local/"* ]] || fail 'STATE_DIR must be inside .local'
    path=$STATE_DIR
    while [[ "$path" != "$LOCAL_ROOT" ]]; do
        [[ ! -L "$path" ]] || fail 'STATE_DIR cannot use symlinks'
        path=$(dirname "$path")
    done
    BE_SOURCE_DIR=$(absolute_path "$BE_SOURCE_DIR")
    if [[ -d "$BE_SOURCE_DIR" ]]; then BE_SOURCE_DIR=$(cd "$BE_SOURCE_DIR" && pwd -P); fi
    if [[ -z "$CONFIG_REPO_URL" ]]; then CONFIG_REPO_URL=$(git -C "$LOCAL_ROOT" remote get-url origin); fi
    CONFIG_REPO=$(github_repository "$CONFIG_REPO_URL")
    CONFIG_REPO_URL="https://github.com/$CONFIG_REPO.git"
    if [[ -z "$SOURCE_REPO" ]]; then
        if [[ -d "$BE_SOURCE_DIR/.git" ]] && remote=$(git -C "$BE_SOURCE_DIR" remote get-url origin); then
            SOURCE_REPO=$(github_repository "$remote")
        else SOURCE_REPO="${CONFIG_REPO%%/*}/be-service"; fi
    fi
    [[ "$SOURCE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'SOURCE_REPO must be OWNER/REPO'
    CONTEXT="k3d-$CLUSTER_NAME"
    export BE_SOURCE_DIR CLUSTER_NAME HTTP_PORT HTTPS_PORT STATE_DIR CONFIG_REPO_URL SOURCE_REPO
}
config_json() {
    jq -n --arg BE_SOURCE_DIR "$BE_SOURCE_DIR" --arg CLUSTER_NAME "$CLUSTER_NAME" \
        --arg HTTP_PORT "$HTTP_PORT" --arg HTTPS_PORT "$HTTPS_PORT" --arg STATE_DIR "$STATE_DIR" \
        --arg CONFIG_REPO_URL "$CONFIG_REPO_URL" --arg SOURCE_REPO "$SOURCE_REPO" \
        '$ARGS.named'
}
settings_json() { jq '{CLUSTER_NAME,HTTP_PORT,HTTPS_PORT,STATE_DIR}' <<< "$LOCAL_CONFIG"; }
k() { kubectl --context "$CONTEXT" --request-timeout=30s "$@"; }
read_state() {
    local name=$1 previous=$2 file="$STATE_DIR/$1"
    [[ -f "$file" ]] || fail "Missing $name; run scripts/$previous.sh first"
    jq -e --argjson config "$LOCAL_CONFIG" '.config == $config' "$file" >/dev/null || \
        fail "Configuration changed; run setup.sh and build.sh again"
    cat "$file"
}
write_state() {
    local name=$1 temporary
    mkdir -p "$STATE_DIR"
    [[ ! -L "$STATE_DIR/$name" ]] || fail "Runtime file cannot be a symlink: $name"
    temporary=$(mktemp "$STATE_DIR/.metadata.XXXXXX")
    jq --argjson config "$LOCAL_CONFIG" '. + {config:$config}' > "$temporary"
    mv "$temporary" "$STATE_DIR/$name"
}
# Scripts call this after handling --help, so help works without jq or Docker.
init_local() {
    require_tools jq git
    load_config
    LOCAL_CONFIG=$(config_json)
}
