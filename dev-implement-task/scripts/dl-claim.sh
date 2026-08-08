#!/usr/bin/env bash
# dl-claim.sh — claim one implementation task (the lock).
#
#   dl-claim.sh                      # auto-pick the highest-urgency READY task
#   dl-claim.sh <uuid>               # claim a specific task
#   dl-claim.sh [--small|--large] [--goal <slug>] [--loop-id <uuid>]
#               [--loop-round <n>]
#               [--steal-after <dur>] [--dry-run]
#
# On success: prints the claimed task uuid to stdout, exit 0.
# Lost race (owned by another): exit 10. Auto-pick with nothing available:
# exit 0 with EMPTY stdout. Bad uuid / not pending: exit 20.
#
# Locking: a per-host flock wraps the multi-command read-modify-verify sequence;
# Taskwarrior 3's SQLite transaction boundary covers each command, not the whole
# claim. Reading `assignee` back detects a competing local write. TaskChampion
# synchronization is not a distributed mutex, so claims on separate replicas
# require external coordination.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-claim.sh [<uuid>] [identity filters] [--steal-after <dur>] [--dry-run]

  <uuid>          claim this specific task (default: auto-pick highest-urgency READY)
  --small         select +SMALL tasks that are not escalated to +LARGE
  --large         select only +LARGE tasks
  --goal <slug>   require this exact goal annotation
  --loop-id <id>  require this exact controller UUID annotation
  --loop-round <n> require this exact positive round annotation
  --steal-after   reclaim a stale +ACTIVE task whose claim is older than <dur>
                  (e.g. 4h, 90m); the takeover is recorded as an annotation
  --dry-run       log mutations instead of performing them

Prints the claimed uuid on stdout. Exit: 0 ok, 10 lost-race, 20 bad/absent task.
EOF
}

UUID=""
STEAL_SECS=""
GOAL_FILTER=""
LOOP_ID_FILTER=""
LOOP_ROUND_FILTER=""
LARGE_WORKER=0
SMALL_WORKER=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --small)       SMALL_WORKER=1 ;;
    --large)       LARGE_WORKER=1 ;;
    --goal)        shift; [ "$#" -gt 0 ] || { usage; dl_die "$DL_PRECOND" "--goal needs a value"; }
                   GOAL_FILTER="$1" ;;
    --loop-id)     shift; [ "$#" -gt 0 ] || { usage; dl_die "$DL_PRECOND" "--loop-id needs a value"; }
                   LOOP_ID_FILTER="${1,,}" ;;
    --loop-round)  shift; [ "$#" -gt 0 ] || { usage; dl_die "$DL_PRECOND" "--loop-round needs a value"; }
                   LOOP_ROUND_FILTER="$1" ;;
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

[ "$SMALL_WORKER" -eq 0 ] || [ "$LARGE_WORKER" -eq 0 ] \
  || dl_die "$DL_PRECOND" "--small and --large are mutually exclusive"

if [ -n "$GOAL_FILTER" ] && ! [[ "$GOAL_FILTER" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  dl_die "$DL_PRECOND" "--goal must be a lowercase slug"
fi
if [ -n "$LOOP_ID_FILTER" ] && ! [[ "$LOOP_ID_FILTER" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  dl_die "$DL_PRECOND" "--loop-id must be a UUID"
fi
if [ -n "$LOOP_ROUND_FILTER" ] && ! [[ "$LOOP_ROUND_FILTER" =~ ^[1-9][0-9]*$ ]]; then
  dl_die "$DL_PRECOND" "--loop-round must be a positive integer"
fi
if [ -n "${AGENT_PID:-}" ] \
  && { ! [[ "$AGENT_PID" =~ ^[0-9]+$ ]] || [ "$AGENT_PID" -le 1 ]; }; then
  dl_die "$DL_PRECOND" \
    "AGENT_PID must be an inherited numeric Linux PID greater than 1; never assign it an agent identifier"
fi

dl_require task jq flock git
dl_resolve_repo_identity

# shellcheck disable=SC2016  # jq variables, not shell expansions.
identity_jq=' 
  def note($p):
    [(.annotations // [])[]?.description
     | select(startswith($p + ":"))
     | sub("^" + $p + ":\\s*"; "")] | last // "";
  (.project // "") == $project
  and note("repo-id") == $repo_id
  and (note("goal") | test("^[a-z0-9][a-z0-9_-]*$"))
  and (note("loop-id") | ascii_downcase
       | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
  and (note("loop-round") | test("^[1-9][0-9]*$"))
  and ([.annotations[]?.description
        | select(startswith("acceptance:"))
        | sub("^acceptance:\\s*"; "")
        | select(test("\\S"))] | length) > 0
  and ($goal == "" or note("goal") == $goal)
  and ($loop_id == "" or (note("loop-id") | ascii_downcase) == $loop_id)
  and ($loop_round == "" or note("loop-round") == $loop_round)
  and (if $large == "1" then
         ((.tags // []) | index("LARGE")) != null
       elif $small == "1" then
         ((.tags // []) | index("SMALL")) != null
         and ((.tags // []) | index("LARGE")) == null
       else
         ((.tags // []) | index("SMALL")) == null
         and ((.tags // []) | index("LARGE")) == null
       end)
'

task_has_expected_identity() {
  local uuid="$1"
  dl_task_export "$uuid" | jq -e --arg project "$DL_REPO_PROJECT" \
    --arg repo_id "$DL_REPO_ID" --arg goal "$GOAL_FILTER" \
    --arg loop_id "$LOOP_ID_FILTER" --arg loop_round "$LOOP_ROUND_FILTER" \
    --arg large "$LARGE_WORKER" --arg small "$SMALL_WORKER" \
    ".[0] | ${identity_jq}" >/dev/null 2>&1
}

# dl_lock <name> — acquire an exclusive flock on fd 9 (released on process exit).
dl_lock() {
  local name="$1" timeout="${2:-10}" lf
  mkdir -p "$DEV_LOOP_STATE_DIR/locks"
  lf="$DEV_LOOP_STATE_DIR/locks/${name}.lock"
  exec 9>"$lf"
  flock -w "$timeout" 9 \
    || dl_die "$DL_PRECOND" "could not acquire lock '$name' within ${timeout}s (another claim in progress)"
}

# The controller-owned Linux worker PID doubles as a stable claim nonce across
# repeated claims and separates concurrent agents sharing one owner. Never
# synthesize AGENT_PID for this purpose. Without it, use a per-call random
# nonce; this still serves as the claim CAS token but cannot identify a later
# call as the same agent.
AGENT_NONCE="${AGENT_PID:-}"

# claim_one <uuid> — attempt to claim. Echoes uuid on success.
# Returns: 0 claimed, 10 owned-by-another / lost, 20 absent or not pending.
claim_one() {
  local uuid="$1" status assignee start owner age now epoch stolen_from="" stolen_age="" claim_value readback held_nonce same_agent
  dl_task_exists "$uuid" || { dl_err "no such task: $uuid"; return "$DL_PRECOND"; }

  status="$(dl_task_field "$uuid" '.status // ""')"
  if [ "$status" != "pending" ]; then
    dl_err "task $uuid is '$status', not pending — cannot claim"
    return "$DL_PRECOND"
  fi

  if ! task_has_expected_identity "$uuid"; then
    dl_err "task $uuid is not valid work for ${DL_REPO_ID} or does not match the requested identity/worker queue"
    return "$DL_PRECOND"
  fi

  assignee="$(dl_task_field "$uuid" '.assignee // ""')"
  start="$(dl_task_field "$uuid" '.start // ""')"
  owner="$(owner_base "$assignee")"

  if [ "$(dl_task_export "$uuid" +READY status:pending | jq 'length')" != "1" ]; then
    dl_err "task $uuid is pending but not ready — dependencies or scheduling still block it"
    return "$DL_PRECOND"
  fi

  # A matching owner with a different agent nonce is a concurrent agent sharing
  # our owner id, not an earlier call from this agent. Treat it as foreign so
  # the ordinary owned-by-another rules below apply — including --steal-after,
  # which is how a restarted agent recovers its predecessor's abandoned task.
  held_nonce="${assignee#*#}"
  [ "$held_nonce" != "$assignee" ] || held_nonce=""
  same_agent=1
  if [ -n "$AGENT_NONCE" ] && [ -n "$held_nonce" ] && [ "$held_nonce" != "$AGENT_NONCE" ]; then
    same_agent=0
    dl_warn "task $uuid is held by a concurrent agent sharing owner '$owner' (holder nonce $held_nonce, ours $AGENT_NONCE)"
  fi

  # Already ours → idempotent re-claim (ensure it is started).
  if [ -n "$owner" ] && [ "$owner" = "$DEV_LOOP_OWNER" ] && [ "$same_agent" -eq 1 ]; then
    if [ -z "$start" ]; then dl_do dl_task "$uuid" start; fi
    dl_log "re-claimed (already owned by you): $uuid"
    dl_set_task_title "$uuid"
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
          stolen_from="$owner"
          stolen_age="$age"
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

  # Write our owner plus a nonce, read it back, and confirm the exact value.
  # Display/ownership checks elsewhere strip "#..." via owner_base.
  if [ -n "$AGENT_NONCE" ]; then
    claim_value="${DEV_LOOP_OWNER}#${AGENT_NONCE}"
  else
    claim_value="${DEV_LOOP_OWNER}#$$-${RANDOM}${RANDOM}"
  fi
  dl_do dl_task "$uuid" modify assignee:"$claim_value"
  if [ -z "$DL_DRY_RUN" ]; then
    readback="$(dl_task_field "$uuid" '.assignee // ""')"
    if [ "$readback" != "$claim_value" ]; then
      dl_err "lost race for $uuid (now owned by '$(owner_base "$readback")')"
      return "$DL_LOST"
    fi
  fi
  if [ -z "$start" ]; then
    dl_do dl_task "$uuid" start
  else
    # Stealing an already-active task: `start` would exit 1 and print "already
    # started." to stdout, corrupting the uuid this script contracts to emit.
    # Reset the timestamp instead so staleness measures the new owner's tenure.
    dl_do dl_task "$uuid" modify start:now
  fi
  if [ -n "$stolen_from" ]; then
    dl_anno_event "$uuid" "stolen from $stolen_from after ${stolen_age}s idle"
  fi
  dl_anno_event "$uuid" "claimed"
  dl_log "claimed: $uuid"
  dl_set_task_title "$uuid"
  printf '%s\n' "$uuid"
  return "$DL_OK"
}

# Small randomized jitter to de-synchronize concurrent starts.
sleep "0.$(printf '%03d' $((RANDOM % 250)))" 2>/dev/null || true

if [ -n "$UUID" ]; then
  dl_lock "select"
  rc=0; claim_one "$UUID" || rc=$?
  exit "$rc"
fi

# Auto-pick: serialize selection+claim across this host with one lock.
dl_lock "select"

# READY, not active, unassigned — highest urgency first.
mapfile -t candidates < <(
  dl_task_export +READY -ACTIVE status:pending \
    | jq -r --arg project "$DL_REPO_PROJECT" --arg repo_id "$DL_REPO_ID" \
      --arg goal "$GOAL_FILTER" --arg loop_id "$LOOP_ID_FILTER" \
      --arg loop_round "$LOOP_ROUND_FILTER" --arg large "$LARGE_WORKER" \
      --arg small "$SMALL_WORKER" "
             [ .[] | select((.assignee // \"\") == \"\")
               | select(${identity_jq}) ]
             | sort_by(.urgency // 0) | reverse | .[].uuid" 2>/dev/null
)

for c in "${candidates[@]:-}"; do
  [ -n "$c" ] || continue
  rc=0; claim_one "$c" || rc=$?
  [ "$rc" -eq "$DL_OK" ] && exit "$DL_OK"          # got one
  [ "$rc" -eq "$DL_LOST" ] && continue             # competing owner: try next
  exit "$rc"                                        # unexpected
done

# Optional: reclaim a stale active task if stealing is permitted.
if [ -n "$STEAL_SECS" ]; then
  mapfile -t actives < <(
    dl_task_export +ACTIVE status:pending \
      | jq -r --arg project "$DL_REPO_PROJECT" --arg repo_id "$DL_REPO_ID" \
        --arg goal "$GOAL_FILTER" --arg loop_id "$LOOP_ID_FILTER" \
        --arg loop_round "$LOOP_ROUND_FILTER" --arg large "$LARGE_WORKER" \
        --arg small "$SMALL_WORKER" \
        "[.[] | select(${identity_jq})]
         | sort_by(.urgency // 0) | reverse | .[].uuid" 2>/dev/null
  )
  for c in "${actives[@]:-}"; do
    [ -n "$c" ] || continue
    rc=0; claim_one "$c" || rc=$?
    [ "$rc" -eq "$DL_OK" ] && exit "$DL_OK"
    [ "$rc" -eq "$DL_LOST" ] && continue
    exit "$rc"
  done
fi

dl_log "no claimable tasks"
exit "$DL_OK"
