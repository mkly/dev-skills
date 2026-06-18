#!/usr/bin/env bash
# dl-claim.sh — Phase 2: claim a task (the lock).
#
#   dl-claim.sh                      # auto-pick the highest-urgency READY task
#   dl-claim.sh <uuid>               # claim a specific task
#   dl-claim.sh [--steal-after <dur>] [--dry-run]
#
# On success: prints the claimed task uuid to stdout, exit 0.
# Lost race (owned by another): exit 10. Auto-pick with nothing available:
# exit 0 with EMPTY stdout. Bad uuid / not pending: exit 20.
#
# Locking: a per-host flock (true mutex for this file-based Taskwarrior) wraps
# the read-modify-verify. A compare-and-swap on the `assignee` field (write,
# then read back and confirm it is still ours) is a best-effort cross-host
# layer should a taskd sync server ever be added.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-claim.sh [<uuid>] [--steal-after <dur>] [--dry-run] [-h|--help]

  <uuid>          claim this specific task (default: auto-pick highest-urgency READY)
  --steal-after   reclaim a stale +ACTIVE task whose claim is older than <dur>
                  (e.g. 4h, 90m); the takeover is recorded as an annotation
  --dry-run       log mutations instead of performing them

Prints the claimed uuid on stdout. Exit: 0 ok, 10 lost-race, 20 bad/absent task.
EOF
}

UUID=""
STEAL_SECS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --steal-after) shift; [ "$#" -gt 0 ] || { usage; dl_die "$DL_PRECOND" "--steal-after needs a value"; }
                   STEAL_SECS="$(dl_dur_to_secs "$1")" ;;
    --dry-run)     DL_DRY_RUN=1 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            usage; dl_die "$DL_PRECOND" "unknown flag: $1" ;;
    *)             [ -z "$UUID" ] || { usage; dl_die "$DL_PRECOND" "unexpected extra argument: $1"; }
                   UUID="$1" ;;
  esac
  shift
done

dl_require task jq flock

# dl_lock <name> — acquire an exclusive flock on fd 9 (released on process exit).
dl_lock() {
  local name="$1" timeout="${2:-10}" lf
  mkdir -p "$DEV_LOOP_STATE_DIR/locks"
  lf="$DEV_LOOP_STATE_DIR/locks/${name}.lock"
  exec 9>"$lf"
  flock -w "$timeout" 9 \
    || dl_die "$DL_PRECOND" "could not acquire lock '$name' within ${timeout}s (another claim in progress)"
}

# owner_base <assignee> — strip any legacy "#nonce" suffix for comparison.
owner_base() { printf '%s' "${1%%#*}"; }

# claim_one <uuid> — attempt to claim. Echoes uuid on success.
# Returns: 0 claimed, 10 owned-by-another / lost, 20 absent or not pending.
claim_one() {
  local uuid="$1" status assignee start owner age now epoch
  dl_task_exists "$uuid" || { dl_err "no such task: $uuid"; return "$DL_PRECOND"; }

  status="$(dl_task_field "$uuid" '.status // ""')"
  if [ "$status" != "pending" ]; then
    dl_err "task $uuid is '$status', not pending — cannot claim"
    return "$DL_PRECOND"
  fi

  assignee="$(dl_task_field "$uuid" '.assignee // ""')"
  start="$(dl_task_field "$uuid" '.start // ""')"
  owner="$(owner_base "$assignee")"

  # Already ours → idempotent re-claim (ensure it is started).
  if [ -n "$owner" ] && [ "$owner" = "$DEV_LOOP_OWNER" ]; then
    if [ -z "$start" ]; then dl_do dl_task "$uuid" start; fi
    dl_log "re-claimed (already owned by you): $uuid"
    printf '%s\n' "$uuid"
    return "$DL_OK"
  fi

  # Owned by someone else → only proceed if a stale steal is permitted.
  if [ -n "$owner" ]; then
    if [ -n "$STEAL_SECS" ] && [ -n "$start" ]; then
      epoch="$(dl_ts_to_epoch "$start")"; now="$(date -u +%s)"
      if [ -n "$epoch" ]; then
        age=$(( now - epoch ))
        if [ "$age" -ge "$STEAL_SECS" ]; then
          dl_warn "stealing stale claim on $uuid (owner=$owner, active ${age}s ≥ ${STEAL_SECS}s)"
          dl_anno_event "$uuid" "stolen from $owner after ${age}s idle"
        else
          dl_err "task $uuid owned by '$owner' (active only ${age}s < ${STEAL_SECS}s) — not stale"
          return "$DL_LOST"
        fi
      else
        dl_err "task $uuid owned by '$owner'; could not parse start time — refusing to steal"
        return "$DL_LOST"
      fi
    else
      dl_err "task $uuid already owned by '$owner' (use --steal-after to reclaim a stale active task)"
      return "$DL_LOST"
    fi
  fi

  # Compare-and-swap: write our owner, read it back, confirm it is still ours.
  dl_do dl_task "$uuid" modify assignee:"$DEV_LOOP_OWNER"
  if [ -z "$DL_DRY_RUN" ]; then
    local readback
    readback="$(owner_base "$(dl_task_field "$uuid" '.assignee // ""')")"
    if [ "$readback" != "$DEV_LOOP_OWNER" ]; then
      dl_err "lost race for $uuid (now owned by '$readback')"
      return "$DL_LOST"
    fi
  fi
  dl_do dl_task "$uuid" start
  dl_anno_event "$uuid" "claimed"
  dl_log "claimed: $uuid"
  printf '%s\n' "$uuid"
  return "$DL_OK"
}

# Small randomized jitter to de-synchronize concurrent starts.
sleep "0.$(printf '%03d' $((RANDOM % 250)))" 2>/dev/null || true

if [ -n "$UUID" ]; then
  dl_lock "task-$UUID"
  rc=0; claim_one "$UUID" || rc=$?
  exit "$rc"
fi

# Auto-pick: serialize selection+claim across this host with one lock.
dl_lock "select"

# READY, not active, unassigned — highest urgency first.
mapfile -t candidates < <(
  dl_task_export +READY -ACTIVE status:pending \
    | jq -r '[ .[] | select((.assignee // "") == "") ]
             | sort_by(.urgency // 0) | reverse | .[].uuid' 2>/dev/null
)

for c in "${candidates[@]:-}"; do
  [ -n "$c" ] || continue
  rc=0; claim_one "$c" || rc=$?
  [ "$rc" -eq "$DL_OK" ] && exit "$DL_OK"          # got one
  [ "$rc" -eq "$DL_LOST" ] && continue             # cross-host race: try next
  exit "$rc"                                        # unexpected
done

# Optional: reclaim a stale active task if stealing is permitted.
if [ -n "$STEAL_SECS" ]; then
  mapfile -t actives < <(
    dl_task_export +ACTIVE status:pending | jq -r '.[].uuid' 2>/dev/null
  )
  for c in "${actives[@]:-}"; do
    [ -n "$c" ] || continue
    rc=0; claim_one "$c" || rc=$?
    [ "$rc" -eq "$DL_OK" ] && exit "$DL_OK"
  done
fi

dl_log "no claimable tasks"
exit "$DL_OK"
