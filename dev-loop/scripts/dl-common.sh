# shellcheck shell=bash
# dl-common.sh — shared helpers for the dev-loop skill scripts.
# Sourced, never executed directly. Keep POSIX-ish bash; assume bash 4+.

# ---------------------------------------------------------------------------
# Exit codes (stable contract the agent branches on; see reference.md).
#   0  ok
#   10 lost-race  (task already claimed by another owner)
#   20 precondition / doctor / usage failure
#   30 merge-back conflict, empty diff, or branch collision
# ---------------------------------------------------------------------------
DL_OK=0
DL_LOST=10
DL_PRECOND=20
DL_MERGE=30
export DL_OK DL_LOST DL_PRECOND DL_MERGE

# ---------------------------------------------------------------------------
# Logging — everything diagnostic goes to stderr so stdout stays parseable.
# ---------------------------------------------------------------------------
dl_log()  { printf 'dev-loop: %s\n' "$*" >&2; }
dl_warn() { printf 'dev-loop: WARN: %s\n' "$*" >&2; }
dl_err()  { printf 'dev-loop: ERROR: %s\n' "$*" >&2; }
# dl_die <exit-code> <message...>
dl_die()  { local code="$1"; shift; dl_err "$*"; exit "$code"; }

# ---------------------------------------------------------------------------
# Environment knobs (all overridable; documented in reference.md).
# ---------------------------------------------------------------------------
: "${CRABBOX_PROVIDER:=incus}"
: "${DEV_LOOP_TTL:=2h}"          # crabbox lease ttl
: "${DEV_LOOP_STALE:=4h}"        # default age past which an active claim is "stale"
: "${INCUS_IMAGE:=}"             # optional -incus-image override
: "${INCUS_TYPE:=}"              # optional -incus-instance-type (container|vm)
: "${INCUS_REMOTE:=}"            # optional -incus-remote
: "${DEV_LOOP_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/dev-loop}"
: "${DEV_LOOP_WORKTREE_DIR:=${DEV_LOOP_STATE_DIR}/worktrees}"  # per-task git worktrees (outside the repo tree)
export CRABBOX_PROVIDER DEV_LOOP_TTL DEV_LOOP_STALE DEV_LOOP_STATE_DIR DEV_LOOP_WORKTREE_DIR

# Stable, attributable owner id. Distinctness between two agents as the same
# Unix user requires exporting DEV_LOOP_OWNER (see SKILL.md Phase 0); the
# default is stable across this user's script invocations so ownership checks
# work, but is NOT distinct per agent.
dl_default_owner() {
  local host
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
  printf '%s@%s' "${USER:-$(id -un 2>/dev/null || echo user)}" "$host"
}
: "${DEV_LOOP_OWNER:=$(dl_default_owner)}"
export DEV_LOOP_OWNER

# DL_DRY_RUN (non-empty) → mutating ops are logged, not executed. Reads still run.
DL_DRY_RUN="${DL_DRY_RUN:-}"

# dl_do <cmd...> — run a mutating command, or just log it under --dry-run.
dl_do() {
  if [ -n "$DL_DRY_RUN" ]; then
    dl_log "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Preconditions.
# ---------------------------------------------------------------------------
# dl_require <cmd...> — fail (20) if any command is missing.
dl_require() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    dl_die "$DL_PRECOND" "missing required command(s): ${missing[*]}"
  fi
}

# dl_in_git_repo — fail (20) unless cwd is inside a git work tree.
dl_in_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || dl_die "$DL_PRECOND" "not inside a git repository (run from your repo checkout)"
}

# ---------------------------------------------------------------------------
# Taskwarrior wrappers — deterministic, non-interactive.
# ---------------------------------------------------------------------------
# dl_task <args...> — mutating/quiet task invocation (no prompts, quiet).
dl_task() {
  task rc.confirmation=no rc.recurrence.confirmation=no rc.verbose=nothing "$@"
}

# dl_task_export <filter...> — JSON array of matching tasks on stdout.
dl_task_export() {
  task rc.confirmation=no rc.json.array=on rc.verbose=nothing "$@" export 2>/dev/null
}

# dl_task_field <uuid> <jq-expr> — print one field (jq -r) of a single task.
# Example: dl_task_field "$uuid" '.assignee // ""'
dl_task_field() {
  local uuid="$1" expr="$2"
  dl_task_export "$uuid" | jq -r ".[0] | ${expr}" 2>/dev/null
}

# dl_task_exists <uuid> — true if exactly one task matches.
dl_task_exists() {
  local uuid="$1" n
  n="$(dl_task_export "$uuid" | jq 'length' 2>/dev/null || echo 0)"
  [ "${n:-0}" = "1" ]
}

# owner_base <assignee> — strip any "#nonce" suffix for display and ownership
# comparisons. The full assignee value is still used for claim CAS.
owner_base() { printf '%s' "${1%%#*}"; }

# dl_require_owner <uuid> — fail unless the current owner owns the task.
dl_require_owner() {
  local uuid="$1" assignee owner
  assignee="$(dl_task_field "$uuid" '.assignee // ""')"
  owner="$(owner_base "$assignee")"
  if [ -z "$owner" ]; then
    dl_die "$DL_LOST" "task $uuid is unclaimed; claim it first with dl-claim.sh"
  fi
  if [ "$owner" != "$DEV_LOOP_OWNER" ]; then
    dl_die "$DL_LOST" "task $uuid is owned by '$owner', not you ($DEV_LOOP_OWNER)"
  fi
}

# ---------------------------------------------------------------------------
# Structured annotations as recoverable machine state (box=, base=, branch=).
# Annotations are append-only (an audit trail); reads take the LAST match.
# ---------------------------------------------------------------------------
# dl_anno_get <uuid> <key> — latest value for key, or empty.
dl_anno_get() {
  local uuid="$1" key="$2"
  dl_task_export "$uuid" \
    | jq -r --arg k "$key" '
        (.[0].annotations // [])
        | map(.description)
        | map(select(startswith($k + "=")))
        | last // ""
        | if . == "" then "" else (.[($k|length)+1:]) end
      ' 2>/dev/null
}

# dl_anno_set <uuid> <key> <value> — append a key=value annotation.
dl_anno_set() {
  local uuid="$1" key="$2" value="$3"
  dl_do dl_task "$uuid" annotate "${key}=${value}"
}

# dl_anno_event <uuid> <message> — append a free-form lifecycle note.
dl_anno_event() {
  local uuid="$1" msg="$2"
  dl_do dl_task "$uuid" annotate "dev-loop: ${msg} (by ${DEV_LOOP_OWNER})"
}

# ---------------------------------------------------------------------------
# Time helpers.
# ---------------------------------------------------------------------------
# dl_dur_to_secs <dur> — parse 90s / 30m / 2h / 1d / 2h30m → seconds on stdout.
dl_dur_to_secs() {
  local s="$1" total=0 num unit rest="$1"
  [ -n "$s" ] || dl_die "$DL_PRECOND" "unparseable duration: '' (use forms like 90s, 30m, 2h, 1d, 2h30m)"
  if [[ "$s" =~ ^[0-9]+$ ]]; then printf '%s' "$s"; return 0; fi
  while [[ "$rest" =~ ^([0-9]+)([smhd])(.*)$ ]]; do
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
    case "$unit" in
      s) total=$(( total + num )) ;;
      m) total=$(( total + num * 60 )) ;;
      h) total=$(( total + num * 3600 )) ;;
      d) total=$(( total + num * 86400 )) ;;
    esac
  done
  if [ -n "$rest" ]; then
    dl_die "$DL_PRECOND" "unparseable duration: '$1' (use forms like 90s, 30m, 2h, 1d, 2h30m)"
  fi
  printf '%s' "$total"
}

# dl_ts_to_epoch <taskwarrior-ts> — 20260616T143000Z → epoch seconds, or empty.
dl_ts_to_epoch() {
  local ts="$1" iso
  [ -n "$ts" ] || { printf ''; return 0; }
  # YYYYMMDDTHHMMSSZ -> YYYY-MM-DDTHH:MM:SSZ
  if [[ "$ts" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]]; then
    iso="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}T${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}Z"
    date -u -d "$iso" +%s 2>/dev/null || printf ''
  else
    date -u -d "$ts" +%s 2>/dev/null || printf ''
  fi
}

# ---------------------------------------------------------------------------
# Slug helper — friendly, filesystem/branch-safe identifier for a task.
# dl_slug <uuid> [<description>]  e.g. -> dl-1a2b3c4d-add-login
# ---------------------------------------------------------------------------
dl_slug() {
  local uuid="$1" desc="${2:-}" short words
  short="$(printf '%s' "$uuid" | tr -d -)"; short="${short:0:8}"
  words="$(printf '%s' "$desc" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | tr -s '-' \
    | sed 's/^-//; s/-$//')"
  words="${words:0:24}"; words="${words%-}"
  if [ -n "$words" ]; then printf 'dl-%s-%s' "$short" "$words"; else printf 'dl-%s' "$short"; fi
}

# ---------------------------------------------------------------------------
# Crabbox wrapper — applies provider + incus overrides consistently.
# Usage: dl_crabbox <subcommand> [args...]
# Incus overrides are appended only when set, so they never clobber defaults.
# ---------------------------------------------------------------------------
dl_crabbox_incus_flags() {
  local -a f=()
  [ -n "$INCUS_IMAGE" ]  && f+=(-incus-image "$INCUS_IMAGE")
  [ -n "$INCUS_TYPE" ]   && f+=(-incus-instance-type "$INCUS_TYPE")
  [ -n "$INCUS_REMOTE" ] && f+=(-incus-remote "$INCUS_REMOTE")
  # Print nothing (not a blank line) when no overrides are set, so callers can
  # safely `mapfile` the result without picking up an empty argument.
  if [ "${#f[@]}" -gt 0 ]; then printf '%s\n' "${f[@]}"; fi
}

# ---------------------------------------------------------------------------
# Per-task worktree helpers.
#
# Each task edits in its own git worktree on a scratch branch, so many agents
# can work the same repo on one machine without sharing a working tree. The
# worktree lives OUTSIDE the repo (under DEV_LOOP_WORKTREE_DIR), namespaced per
# repo, and its absolute path is recorded as a worktree= annotation — that
# annotation is the single source of truth every later phase reads.
# ---------------------------------------------------------------------------
# dl_repo_key — stable short id for THIS repo, to namespace shared state dirs so
# two checkouts on one machine never collide. Derived from the git common dir
# (shared by all of a repo's worktrees), so it is identical whether called from
# the main checkout or a per-task worktree.
dl_repo_key() {
  local cdir base
  cdir="$(git rev-parse --git-common-dir 2>/dev/null || echo .)"
  cdir="$(cd "$cdir" 2>/dev/null && pwd -P || printf '%s' "$cdir")"
  base="$(basename "$(dirname "$cdir")")"
  printf '%s-%s' "$base" "$(printf '%s' "$cdir" | cksum | cut -d' ' -f1)"
}

# dl_worktree_dir_for <slug> — absolute path of the per-task worktree for <slug>.
dl_worktree_dir_for() {
  printf '%s/%s/%s' "$DEV_LOOP_WORKTREE_DIR" "$(dl_repo_key)" "$1"
}

# dl_worktree_snapshot_tree <worktree> — write a tree from the worktree's whole
# source state using a throwaway index. Prints the tree sha.
dl_worktree_snapshot_tree() {
  local wt="$1" tmp_index snap_tree
  [ -d "$wt" ] || dl_die "$DL_PRECOND" "recorded worktree is missing: $wt"
  tmp_index="$(mktemp "${TMPDIR:-/tmp}/dl-index.XXXXXX")" \
    || dl_die "$DL_PRECOND" "could not allocate temporary git index"
  rm -f "$tmp_index"
  if ! GIT_INDEX_FILE="$tmp_index" git -C "$wt" add -A; then
    rm -f "$tmp_index"
    dl_die "$DL_PRECOND" "failed to stage worktree snapshot: $wt"
  fi
  snap_tree="$(GIT_INDEX_FILE="$tmp_index" git -C "$wt" write-tree)" || {
    rm -f "$tmp_index"
    dl_die "$DL_PRECOND" "failed to write worktree snapshot tree: $wt"
  }
  rm -f "$tmp_index"
  [ -n "$snap_tree" ] || dl_die "$DL_PRECOND" "snapshot produced no tree"
  printf '%s\n' "$snap_tree"
}

# dl_worktree_dirty_vs_base <worktree> <base> — return 0 when the worktree's
# current source tree differs from base, 1 when identical. Missing base is
# treated as dirty so cleanup never discards work it cannot compare.
dl_worktree_dirty_vs_base() {
  local wt="$1" base="$2" snap_tree
  [ -n "$base" ] || return 0
  if ! git -C "$wt" cat-file -e "${base}^{tree}" 2>/dev/null; then
    return 0
  fi
  snap_tree="$(dl_worktree_snapshot_tree "$wt")"
  ! git -C "$wt" diff --quiet "${base}^{tree}" "$snap_tree" 2>/dev/null
}

# Resolve the directory this library lives in (for sibling-script lookups).
DL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DL_SCRIPT_DIR
