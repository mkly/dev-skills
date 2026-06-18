#!/usr/bin/env bash
# dl-done.sh — Phase 5: complete a task and free its box.
#
#   dl-done.sh <uuid> [--keep-box] [--force] [--dry-run]
#
# Stops the task's crabbox lease (Incus delete-on-release frees the instance),
# marks the task done (which drops it from pending and releases the claim), and
# records a lifecycle annotation. Refuses to complete a task owned by another
# owner unless --force.
#
# Exit: 0 ok, 10 owned by another owner (without --force), 20 precondition.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-done.sh <uuid> [--keep-box] [--force] [--dry-run] [-h|--help]

  --keep-box  leave the crabbox lease running (default: stop it)
  --force     complete even if the claim is owned by another owner
  --dry-run   log mutations instead of performing them

Exit: 0 ok, 10 owned by another (use --force), 20 precondition.
EOF
}

UUID=""; KEEP_BOX=0; FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep-box) KEEP_BOX=1 ;;
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
dl_anno_event "$UUID" "completed${branch:+ (review branch: $branch)}"
# shellcheck disable=SC1010  # 'done' is the Taskwarrior subcommand, not a loop keyword
dl_do dl_task "$UUID" done
if [ -n "$branch" ]; then
  dl_log "done: $UUID — review branch \"$branch\" awaits merge"
else
  dl_log "done: $UUID"
fi
