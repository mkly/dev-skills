#!/usr/bin/env bash
# dl-release.sh — abandon a claim without completing the task.
#
#   dl-release.sh <uuid> [--stop-box] [--force] [--dry-run]
#
# Stops the task (clears +ACTIVE), clears the assignee so another owner can
# claim it, and parks its box for the next task unless explicitly stopped.
# Refuses to release a claim owned by a
# different owner unless --force. The task stays pending and re-claimable.
#
# Exit: 0 ok, 10 owned by another owner (without --force), 20 precondition.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-release.sh <uuid> [--stop-box] [--force] [--dry-run] [-h|--help]

  --stop-box  also stop the task's crabbox lease
  --force     release even if the claim is owned by another owner
  --dry-run   log mutations instead of performing them

Exit: 0 ok, 10 owned by another (use --force), 20 precondition.
EOF
}

UUID=""; STOP_BOX=0; FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stop-box) STOP_BOX=1 ;;
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

assignee="$(dl_task_field "$UUID" '.assignee // ""')"
owner_base="${assignee%%#*}"
if [ -n "$owner_base" ] && [ "$owner_base" != "$DEV_LOOP_OWNER" ] && [ "$FORCE" -ne 1 ]; then
  dl_die "$DL_LOST" "task $UUID is owned by '$owner_base', not you ($DEV_LOOP_OWNER); use --force to release anyway"
fi

# Park the box by default so the next task avoids a fresh warmup.
handle="$(dl_anno_get "$UUID" box)"
if [ -n "$handle" ]; then
  if [ "$STOP_BOX" -eq 1 ]; then
    dl_log "stopping box $handle"
    dl_do crabbox stop -provider "$CRABBOX_PROVIDER" -id "$handle" || dl_warn "could not stop box $handle (may already be gone)"
  elif [ -n "$DL_DRY_RUN" ]; then
    dl_log "DRY-RUN: park box $handle for the next task"
  elif dl_box_alive "$handle"; then
    parked="$(head -n1 "$(dl_idle_box_file)" 2>/dev/null || true)"
    if [ -n "$parked" ] && [ "$parked" != "$handle" ] && dl_box_alive "$parked"; then
      dl_log "a box is already parked ($parked); stopping box $handle"
      dl_do crabbox stop -provider "$CRABBOX_PROVIDER" -id "$handle" || dl_warn "could not stop box $handle (may already be gone)"
    else
      dl_idle_box_park "$handle"
      dl_log "parked box $handle for the next task (idle timeout will reap it)"
    fi
  else
    dl_warn "could not park box $handle (it is no longer live)"
  fi
fi

# Stop the task and clear the assignee so the slot frees up.
dl_do dl_task "$UUID" stop || true
dl_do dl_task "$UUID" modify assignee:
dl_anno_event "$UUID" "released claim"
dl_log "released: $UUID"
