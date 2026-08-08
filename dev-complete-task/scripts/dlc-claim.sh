#!/usr/bin/env bash
# dlc-claim.sh — claim one review-ready producer without touching assignee.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dlc-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dlc-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dlc-claim.sh <task-ref> [--steal-after <dur>]
                    [--standard|--small|--large|--plan]

  <task-ref>      exact pending review-ready producer selected after collection
  --steal-after   take over a reviewer claim older than <dur> (e.g. 4h, 90m)

One worker drains one queue at every stage. The routing flags name the queue
this reviewer serves, mirroring dl-claim.sh; the default comes from
DEV_LOOP_ROUTE and then from --standard. A task tagged for another queue is
refused, so a review is always finished by a worker of the intended size.

Prints the claimed task UUID. Exit: 0 ok, 10 held by another reviewer,
20 invalid/not-review-ready task, wrong queue, or usage failure.
EOF
}

TASK_REF=""; STEAL_SECS=""; ROUTE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --standard|--small|--large|--plan)
      [ -z "$ROUTE" ] || { usage; dlc_die "$DLC_PRECOND" \
        "--standard, --small, --large, and --plan are mutually exclusive"; }
      ROUTE="${1#--}" ;;
    --steal-after)
      shift; [ "$#" -gt 0 ] || { usage; dlc_die "$DLC_PRECOND" "--steal-after needs a value"; }
      STEAL_SECS="$(dlc_dur_to_secs "$1")" ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; dlc_die "$DLC_PRECOND" "unknown flag: $1" ;;
    *) [ -z "$TASK_REF" ] || { usage; dlc_die "$DLC_PRECOND" "unexpected extra argument: $1"; }
       TASK_REF="$1" ;;
  esac
  shift
done
[ -n "$TASK_REF" ] || { usage; dlc_die "$DLC_PRECOND" "task reference required"; }

# An explicit flag wins; otherwise the queue is inherited from the `loop` worker
# that launched this agent, exactly as dl-claim.sh inherits it.
[ -n "$ROUTE" ] || ROUTE="${DEV_LOOP_ROUTE:-standard}"
case "$ROUTE" in
  standard|small|large|plan) ;;
  *) dlc_die "$DLC_PRECOND" \
       "DEV_LOOP_ROUTE must be standard, small, large, or plan (got '$ROUTE')" ;;
esac

dlc_require task jq flock git
dlc_resolve_repo_identity
dlc_review_lock

raw="$(dlc_task_export "$TASK_REF")" \
  || dlc_die "$DLC_PRECOND" "failed to export review task: $TASK_REF"
[ "$(printf '%s' "$raw" | jq 'length')" = 1 ] \
  || dlc_die "$DLC_PRECOND" "task reference '$TASK_REF' must resolve to exactly one task"

task_json="$(printf '%s' "$raw" | jq -c "$DLC_JQ_DEFS"'
  .[0] | {uuid, status, project: (.project // ""), tags: (.tags // []),
    repo_id: note("repo-id"), goal: note("goal"),
    loop_id: (note("loop-id") | ascii_downcase),
    branch: kv("branch"), summary: notes("summary"),
    acceptance: notes("acceptance") }')"
uuid="$(printf '%s' "$task_json" | jq -r .uuid)"
[ "$(printf '%s' "$task_json" | jq -r .status)" = pending ] \
  || dlc_die "$DLC_PRECOND" "task $uuid is not pending"
[ "$(printf '%s' "$task_json" | jq -r .project)" = "$DLC_REPO_PROJECT" ] \
  && [ "$(printf '%s' "$task_json" | jq -r .repo_id)" = "$DLC_REPO_ID" ] \
  || dlc_die "$DLC_PRECOND" "task $uuid does not belong to current repository '$DLC_REPO_ID'"
# The routing predicate is the twin of dl-claim.sh's, so a task implemented by
# one queue's worker is reviewed by that same queue's worker.
printf '%s' "$task_json" | jq -e --arg route "$ROUTE" '
  .tags as $t
  | def has($x): ($t | index($x)) != null;
    if $route == "large" then has("LARGE") and (has("PLAN") | not)
    elif $route == "small" then
      has("SMALL") and (has("LARGE") | not) and (has("PLAN") | not)
    elif $route == "plan" then has("PLAN")
    else (has("SMALL") | not) and (has("LARGE") | not) and (has("PLAN") | not)
    end' >/dev/null \
  || dlc_die "$DLC_PRECOND" \
       "task $uuid is not on the $ROUTE queue; a $ROUTE worker must not review it"

goal="$(printf '%s' "$task_json" | jq -r .goal)"
loop_id="$(printf '%s' "$task_json" | jq -r .loop_id)"
[[ "$goal" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
  || dlc_die "$DLC_PRECOND" "task $uuid has no valid goal annotation"
[[ "$loop_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || dlc_die "$DLC_PRECOND" "task $uuid has no valid loop-id annotation"
[ -n "$(printf '%s' "$task_json" | jq -r .acceptance)" ] \
  && [ -n "$(printf '%s' "$task_json" | jq -r .summary)" ] \
  || dlc_die "$DLC_PRECOND" "task $uuid is not review-ready (acceptance or summary missing)"
branch="$(printf '%s' "$task_json" | jq -r .branch)"
if [ -z "$branch" ] || ! git show-ref --verify --quiet "refs/heads/${branch}"; then
  dlc_die "$DLC_PRECOND" "task $uuid is not review-ready (recorded branch missing locally)"
fi
[ "$(dlc_task_export "$uuid" +READY status:pending | jq 'length')" = 1 ] \
  || dlc_die "$DLC_PRECOND" "task $uuid is pending but blocked; it cannot be reviewed yet"

held="$(dlc_anno_get "$uuid" reviewer)"
held_owner="$(dlc_owner_base "$held")"
held_nonce="${held#*#}"; [ "$held_nonce" != "$held" ] || held_nonce=""
same_agent=1
if [ -n "$DLC_REVIEW_NONCE" ] && [ -n "$held_nonce" ] && [ "$held_nonce" != "$DLC_REVIEW_NONCE" ]; then
  same_agent=0
fi
if [ -n "$held_owner" ] && [ "$held_owner" = "$DLC_REVIEW_OWNER" ] && [ "$same_agent" -eq 1 ]; then
  dlc_log "re-claimed review (already owned by you): $uuid"
  printf '%s\n' "$uuid"
  exit "$DLC_OK"
fi

stolen_from=""
if [ -n "$held_owner" ]; then
  if [ -z "$STEAL_SECS" ]; then
    dlc_die "$DLC_LOST" "task $uuid is already being reviewed by '$held_owner'"
  fi
  started="$(dlc_anno_get "$uuid" review-start)"
  epoch="$(dlc_ts_to_epoch "$started")"
  [ -n "$epoch" ] \
    || dlc_die "$DLC_LOST" "task $uuid is reviewed by '$held_owner'; its review-start is missing or invalid"
  age=$(( $(date -u +%s) - epoch ))
  [ "$age" -ge "$STEAL_SECS" ] \
    || dlc_die "$DLC_LOST" "task $uuid is reviewed by '$held_owner' for only ${age}s (< ${STEAL_SECS}s)"
  stolen_from="$held_owner"
  dlc_warn "stealing stale review claim on $uuid from $held_owner after ${age}s"
fi

if [ -n "$DLC_REVIEW_NONCE" ]; then
  claim_value="${DLC_REVIEW_OWNER}#${DLC_REVIEW_NONCE}"
else
  claim_value="${DLC_REVIEW_OWNER}#$$-${RANDOM}${RANDOM}"
fi
dlc_anno_set "$uuid" review-start "$(date -u +%Y%m%dT%H%M%SZ)" >/dev/null
dlc_anno_set "$uuid" reviewer "$claim_value" >/dev/null
readback="$(dlc_anno_get "$uuid" reviewer)"
if [ "$readback" != "$claim_value" ]; then
  dlc_die "$DLC_LOST" "lost reviewer race for $uuid (now held by '$(dlc_owner_base "$readback")')"
fi
if [ -n "$stolen_from" ]; then
  dlc_review_event "$uuid" "review claim stolen from $stolen_from" >/dev/null
else
  dlc_review_event "$uuid" "review claimed" >/dev/null
fi
dlc_log "claimed review: $uuid ($branch)"
printf '%s\n' "$uuid"
