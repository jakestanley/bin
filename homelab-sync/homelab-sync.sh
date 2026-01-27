#!/usr/bin/env bash
set -euo pipefail

log() { printf '[homelab-sync] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1; shift ;;
  "") ;;
  *) die "usage: homelab-sync [--dry-run]" ;;
esac

run() {
  if (( DRY_RUN )); then
    printf '+ %q' "$1" >&2
    shift
    for arg in "$@"; do
      printf ' %q' "$arg" >&2
    done
    printf '\n' >&2
    return 0
  fi
  "$@"
}

abspath() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    die "not a directory: $path"
  fi
  (cd "$path" && pwd -P)
}

# Resolve symlink so SCRIPT_DIR is the real script location
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE (copy .env.example -> .env and fill it in)"

# shellcheck disable=SC1090
source "$ENV_FILE"

[[ -n "${HOMELAB_SYNC_ROOT:-}" ]] || die "HOMELAB_SYNC_ROOT not set"
[[ -n "${HOMELAB_SYNC_REQUIRED_REPOS:-}" ]] || die "HOMELAB_SYNC_REQUIRED_REPOS not set"
[[ -n "${HOMELAB_SYNC_IMPORTS_SCRIPT:-}" ]] || die "HOMELAB_SYNC_IMPORTS_SCRIPT not set"
[[ -n "${HOMELAB_SYNC_VENV_DIR_CANDIDATES:-}" ]] || die "HOMELAB_SYNC_VENV_DIR_CANDIDATES not set"
[[ -n "${HOMELAB_SYNC_GIT_REMOTE:-}" ]] || die "HOMELAB_SYNC_GIT_REMOTE not set"
[[ -n "${HOMELAB_SYNC_PYTHON:-}" ]] || die "HOMELAB_SYNC_PYTHON not set"

require_cmd git

ROOT_ABS="$(abspath "$HOMELAB_SYNC_ROOT")"
GIT_REMOTE="$HOMELAB_SYNC_GIT_REMOTE"
IMPORTS_REL="$HOMELAB_SYNC_IMPORTS_SCRIPT"
PYTHON_FALLBACK_CMD="$HOMELAB_SYNC_PYTHON"

read -r -a REQUIRED_REPOS <<<"$HOMELAB_SYNC_REQUIRED_REPOS"
read -r -a OPTIONAL_REPOS <<<"${HOMELAB_SYNC_OPTIONAL_REPOS:-}"
read -r -a VENV_DIRS <<<"$HOMELAB_SYNC_VENV_DIR_CANDIDATES"

(( ${#REQUIRED_REPOS[@]} > 0 )) || die "HOMELAB_SYNC_REQUIRED_REPOS is empty"
(( ${#VENV_DIRS[@]} > 0 )) || die "HOMELAB_SYNC_VENV_DIR_CANDIDATES is empty"

git_path_exists() {
  local repo_dir="$1"
  local rel="$2"
  local path
  path="$(git -C "$repo_dir" rev-parse --git-path "$rel" 2>/dev/null)" || return 1
  [[ -e "$path" ]]
}

ensure_repo_ready() {
  local repo_dir="$1"
  local repo_name="$2"

  git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$repo_name is not a git repository: $repo_dir"
  git -C "$repo_dir" remote get-url "$GIT_REMOTE" >/dev/null 2>&1 || die "$repo_name: missing git remote '$GIT_REMOTE'"

  git -C "$repo_dir" symbolic-ref -q HEAD >/dev/null 2>&1 || die "$repo_name: detached HEAD (check out a branch first)"
  git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || die "$repo_name: no upstream configured for current branch"

  if git_path_exists "$repo_dir" rebase-apply || \
    git_path_exists "$repo_dir" rebase-merge || \
    git_path_exists "$repo_dir" MERGE_HEAD || \
    git_path_exists "$repo_dir" CHERRY_PICK_HEAD || \
    git_path_exists "$repo_dir" REVERT_HEAD; then
    die "$repo_name: repository has an in-progress operation (rebase/merge/cherry-pick/revert)"
  fi

  local dirty
  dirty="$(git -C "$repo_dir" status --porcelain)"
  if [[ -n "$dirty" ]]; then
    log "$repo_name: uncommitted changes detected:"
    printf '%s\n' "$dirty" >&2
    die "$repo_name: commit/stash/clean changes and retry"
  fi
}

sync_repo() {
  local repo_dir="$1"
  local repo_name="$2"

  log "$repo_name: fetch"
  run git -C "$repo_dir" fetch "$GIT_REMOTE" --prune

  log "$repo_name: pull (--ff-only)"
  run git -C "$repo_dir" pull --ff-only

  log "$repo_name: push"
  run git -C "$repo_dir" push "$GIT_REMOTE"
}

find_repo_python() {
  local repo_dir="$1"
  local venv_dir

  for venv_dir in "${VENV_DIRS[@]}"; do
    if [[ -x "$repo_dir/$venv_dir/bin/python" ]]; then
      echo "$repo_dir/$venv_dir/bin/python"
      return 0
    fi
    if [[ -x "$repo_dir/$venv_dir/bin/python3" ]]; then
      echo "$repo_dir/$venv_dir/bin/python3"
      return 0
    fi
  done

  command -v "$PYTHON_FALLBACK_CMD" >/dev/null 2>&1 || die "missing command: $PYTHON_FALLBACK_CMD"
  echo "$PYTHON_FALLBACK_CMD"
}

run_import_sync() {
  local repo_dir="$1"
  local repo_name="$2"
  local imports_path="$repo_dir/$IMPORTS_REL"
  [[ -f "$imports_path" ]] || die "$repo_name: missing $IMPORTS_REL"

  local python_exec
  python_exec="$(find_repo_python "$repo_dir")"

  log "$repo_name: sync imports ($IMPORTS_REL)"
  if (( DRY_RUN )); then
    run bash -lc "cd \"${repo_dir}\" && \"${python_exec}\" \"${IMPORTS_REL}\""
    return 0
  fi
  (cd "$repo_dir" && "$python_exec" "$IMPORTS_REL")
}

main() {
  local -a repos=()
  local repo

  for repo in "${REQUIRED_REPOS[@]}"; do
    [[ -n "$repo" ]] || continue
    [[ -d "$ROOT_ABS/$repo" ]] || die "missing required repo: $ROOT_ABS/$repo"
    repos+=("$repo")
  done

  for repo in "${OPTIONAL_REPOS[@]}"; do
    [[ -n "$repo" ]] || continue
    if [[ -d "$ROOT_ABS/$repo" ]]; then
      repos+=("$repo")
    else
      log "skip optional repo (not found): $ROOT_ABS/$repo"
    fi
  done

  local repo_name repo_dir
  for repo_name in "${repos[@]}"; do
    repo_dir="$ROOT_ABS/$repo_name"
    ensure_repo_ready "$repo_dir" "$repo_name"
  done

  for repo_name in "${repos[@]}"; do
    repo_dir="$ROOT_ABS/$repo_name"
    sync_repo "$repo_dir" "$repo_name"
    run_import_sync "$repo_dir" "$repo_name"
  done

  log "done"
}

main "$@"
