#!/usr/bin/env bash
# dl-done.sh — Phase 5: complete a task and free its box.
#
#   dl-done.sh <uuid> [--keep-box] [--keep-worktree] [--force] [--dry-run]
#
# Stops the task's crabbox lease (Incus delete-on-release frees the instance),
# removes the task's per-task git worktree and its scratch branch dl/<slug> (the
# review/<slug> branch is KEPT), marks the task done (which drops it from pending
# and releases the claim), and records a lifecycle annotation. Refuses to
# complete a task owned by another owner unless --force.
#
# Exit: 0 ok, 10 owned by another owner (without --force), 20 precondition.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-done.sh <uuid> [--keep-box] [--keep-worktree] [--force] [--dry-run] [-h|--help]

  --keep-box       leave the crabbox lease running (default: stop it)
  --keep-worktree  leave the per-task worktree + scratch branch in place
  --force          complete even if the claim is owned by another owner
  --dry-run        log mutations instead of performing them

Exit: 0 ok, 10 owned by another (use --force), 20 precondition.
EOF
}

UUID=""; KEEP_BOX=0; KEEP_WT=0; FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep-box)      KEEP_BOX=1 ;;
    --keep-worktree) KEEP_WT=1 ;;
    --force)    FORCE=1 ;;
    --dry-run)  DL_DRY_RUN=1 ;;
    -h|--help)  usage; exit 0 ;;
    -*) usage; dl_die "$DL_PRECOND" "unknown flag: $1" ;;
    *)  [ -z "$UUID" ] || { usage; dl_die "$DL_PRECOND" "unexpected extra argument: $1"; }
        UUID="$1" ;;
  esac
  shift
done
[ -n "$UUID" ] || { usage; dl_die "$DL_PRECOND" "task uuid required"; }

dl_require task jq crabbox
dl_task_exists "$UUID" || dl_die "$DL_PRECOND" "no such task: $UUID"

status="$(dl_task_field "$UUID" '.status // ""')"
if [ "$status" = "completed" ]; then
  dl_log "task $UUID already completed"
  exit "$DL_OK"
fi

assignee="$(dl_task_field "$UUID" '.assignee // ""')"
owner_base="${assignee%%#*}"
if [ -n "$owner_base" ] && [ "$owner_base" != "$DEV_LOOP_OWNER" ] && [ "$FORCE" -ne 1 ]; then
  dl_die "$DL_LOST" "task $UUID is owned by '$owner_base', not you ($DEV_LOOP_OWNER); use --force to complete anyway"
fi

# Stop the box (best-effort) unless asked to keep it.
if [ "$KEEP_BOX" -ne 1 ]; then
  handle="$(dl_anno_get "$UUID" box)"
  if [ -n "$handle" ]; then
    dl_log "stopping box $handle"
    dl_do crabbox stop -provider "$CRABBOX_PROVIDER" -id "$handle" || dl_warn "could not stop box $handle (may already be gone)"
  fi
fi

branch="$(dl_anno_get "$UUID" branch)"

# Remove the per-task worktree and its scratch branch (best-effort). The
# review/<slug> branch is shared in the repo and is KEPT — only the throwaway
# worktree + dl/<slug> pointer go away, freeing the tree for reuse and keeping
# `git worktree list` clean. Must run from inside the repo (not the worktree).
if [ "$KEEP_WT" -ne 1 ]; then
  wt="$(dl_anno_get "$UUID" worktree)"
  if [ -n "$wt" ] && command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    desc="$(dl_task_field "$UUID" '.description // ""')"
    wbranch="dl/$(dl_slug "$UUID" "$desc")"
    dl_log "removing worktree $wt (scratch branch $wbranch)"
    dl_do git worktree remove --force "$wt" 2>/dev/null \
      || dl_warn "could not remove worktree $wt (may already be gone)"
    dl_do git worktree prune 2>/dev/null || true
    dl_do git branch -D "$wbranch" 2>/dev/null \
      || dl_warn "could not delete scratch branch $wbranch (may already be gone)"
  elif [ -n "$wt" ]; then
    dl_warn "not inside a git repo; leaving worktree $wt in place (remove with: git worktree remove --force '$wt')"
  fi
fi

dl_anno_event "$UUID" "completed${branch:+ (review branch: $branch)}"
# shellcheck disable=SC1010  # 'done' is the Taskwarrior subcommand, not a loop keyword
dl_do dl_task "$UUID" done
if [ -n "$branch" ]; then
  dl_log "done: $UUID — review branch \"$branch\" awaits merge"
else
  dl_log "done: $UUID"
fi
