#!/usr/bin/env bash
# dlc-release.sh — release the current agent's reviewer claim without verdict.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dlc-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dlc-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dlc-release.sh <task-ref>

Releases only the current reviewer's lock. Exit: 0 ok, 10 held by another
reviewer, 20 missing task or usage failure.
EOF
}

TASK_REF=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) usage; dlc_die "$DLC_PRECOND" "unknown flag: $1" ;;
    *) [ -z "$TASK_REF" ] || { usage; dlc_die "$DLC_PRECOND" "unexpected extra argument: $1"; }
       TASK_REF="$1" ;;
  esac
  shift
done
[ -n "$TASK_REF" ] || { usage; dlc_die "$DLC_PRECOND" "task reference required"; }

dlc_require task jq flock
dlc_review_lock
raw="$(dlc_task_export "$TASK_REF")" \
  || dlc_die "$DLC_PRECOND" "failed to export review task: $TASK_REF"
[ "$(printf '%s' "$raw" | jq 'length')" = 1 ] \
  || dlc_die "$DLC_PRECOND" "task reference '$TASK_REF' must resolve to exactly one task"
uuid="$(printf '%s' "$raw" | jq -r '.[0].uuid')"
held="$(dlc_anno_get "$uuid" reviewer)"
if [ -z "$held" ]; then
  dlc_log "review already unclaimed: $uuid"
  exit "$DLC_OK"
fi
dlc_require_reviewer "$uuid"
dlc_anno_set "$uuid" review-start "" >/dev/null
dlc_anno_set "$uuid" reviewer "" >/dev/null
[ -z "$(dlc_anno_get "$uuid" reviewer)" ] \
  || dlc_die "$DLC_LOST" "review release lost a race for $uuid"
dlc_review_event "$uuid" "review released without verdict" >/dev/null
dlc_log "released review: $uuid"
