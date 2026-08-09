#!/usr/bin/env bash
# dl-release.sh — abandon a claim without completing the task.
#
#   dl-release.sh <uuid> [--blocked-by <task-ref>]... [--stop-box] [--force]
#                        [--dry-run]
#
# Stops the task (clears +ACTIVE), clears the assignee so another owner can
# claim it, and parks its box for the next task unless explicitly stopped.
# Refuses to release a claim owned by a
# different owner unless --force. The task stays pending and re-claimable.
#
# --blocked-by records the real reason a release happened: the task cannot
# proceed until another task lands. Without it, a released task is immediately
# +READY again and the next worker claims it, rediscovers the same blocker, and
# releases it — burning a box warmup and a full agent turn per round. Adding the
# dependency takes the task out of +READY until its blocker is completed, so the
# queue stops handing out work nobody can do.
#
# Exit: 0 ok, 10 owned by another owner (without --force), 20 precondition.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-release.sh <uuid> [--blocked-by <task-ref>]... [--stop-box] [--force]
                            [--dry-run] [-h|--help]

  --blocked-by <ref>  record that <uuid> cannot proceed until <ref> lands.
                      Adds the Taskwarrior dependency, so the released task
                      leaves +READY and no worker re-claims it until the
                      blocker is done. Repeatable; <ref> is a UUID, short
                      UUID, or id of a PENDING task in this repo.
  --stop-box  also stop the task's crabbox lease
  --force     release even if the claim is owned by another owner
  --dry-run   log mutations instead of performing them

Exit: 0 ok, 10 owned by another (use --force), 20 precondition.
EOF
}

UUID=""; STOP_BOX=0; FORCE=0
declare -a BLOCKERS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --blocked-by) shift
        [ "$#" -gt 0 ] || { usage; dl_die "$DL_PRECOND" "--blocked-by needs a task reference"; }
        BLOCKERS+=("$1") ;;
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
UUID="$(dl_task_field "$UUID" '.uuid // ""')"
[ -n "$UUID" ] || dl_die "$DL_PRECOND" "could not resolve task uuid"

assignee="$(dl_task_field "$UUID" '.assignee // ""')"
owner_base="${assignee%%#*}"
if [ -n "$owner_base" ] && [ "$owner_base" != "$DEV_LOOP_OWNER" ] && [ "$FORCE" -ne 1 ]; then
  dl_die "$DL_LOST" "task $UUID is owned by '$owner_base', not you ($DEV_LOOP_OWNER); use --force to release anyway"
fi

# --- blocker dependencies -------------------------------------------------
# Resolve and validate every blocker BEFORE mutating anything: a rejected
# reference must not leave the task half-released, and the whole point of the
# flag is that the release and the dependency land together.

# dl_depends_of <uuid> — print each dependency uuid of <uuid>, one per line.
# Taskwarrior 3 exports `depends` as an array; older data may carry a
# comma-separated string, so accept both.
dl_depends_of() {
  dl_task_export "$1" | jq -r '
    (.[0].depends // [])
    | if type == "string" then (split(",") | map(select(length > 0))) else . end
    | .[] | ascii_downcase
  ' 2>/dev/null
}

# dl_depends_reaches <from> <target> — true if <target> is <from> itself or is
# reachable through <from>'s transitive dependencies. Adding a dependency that
# reaches back to the releasing task would deadlock both tasks out of +READY
# forever, with no worker able to complete either one.
dl_depends_reaches() {
  local from="$1" target="$2"
  local -a queue=("$from")
  local -A seen=()
  local node dep
  while [ "${#queue[@]}" -gt 0 ]; do
    node="${queue[0]}"; queue=("${queue[@]:1}")
    [ -z "${seen[$node]:-}" ] || continue
    seen[$node]=1
    [ "$node" != "$target" ] || return 0
    while read -r dep; do
      [ -n "$dep" ] || continue
      queue+=("$dep")
    done < <(dl_depends_of "$node")
  done
  return 1
}

declare -a RESOLVED_BLOCKERS=()
if [ "${#BLOCKERS[@]}" -gt 0 ]; then
  # Compare against the released task's own identity rather than the current
  # checkout: release is legitimate from anywhere, and both tasks must simply
  # belong to the same repository.
  task_project="$(dl_task_field "$UUID" '.project // ""')"
  task_repo_id="$(dl_task_export "$UUID" | jq -r '
    [(.[0].annotations // [])[].description
     | select(startswith("repo-id:")) | sub("^repo-id:\\s*"; "")] | last // ""
  ' 2>/dev/null)"

  declare -A seen_blockers=()
  for ref in "${BLOCKERS[@]}"; do
    exported="$(dl_task_export "$ref" 2>/dev/null || true)"
    [ "$(printf '%s' "$exported" | jq 'length' 2>/dev/null || echo 0)" = "1" ] \
      || dl_die "$DL_PRECOND" "--blocked-by '$ref' does not resolve to exactly one task"
    blocker="$(printf '%s' "$exported" | jq -r '.[0].uuid // empty')"
    blocker="${blocker,,}"
    [[ "$blocker" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
      || dl_die "$DL_PRECOND" "--blocked-by '$ref' has no valid UUID"
    [ "$blocker" != "${UUID,,}" ] \
      || dl_die "$DL_PRECOND" "a task cannot be blocked by itself: $ref"

    blocker_status="$(printf '%s' "$exported" | jq -r '.[0].status // ""')"
    # A completed or deleted blocker is not a blocker; recording it would clear
    # itself instantly and hide the real reason for the release.
    [ "$blocker_status" = "pending" ] || [ "$blocker_status" = "waiting" ] \
      || dl_die "$DL_PRECOND" "--blocked-by '$ref' is '$blocker_status', not pending — it cannot be blocking you"

    printf '%s' "$exported" | jq -e --arg project "$task_project" \
      --arg repo_id "$task_repo_id" '
        def note($p):
          [(.[0].annotations // [])[].description
           | select(startswith($p + ":")) | sub("^" + $p + ":\\s*"; "")] | last // "";
        (.[0].project // "") == $project
        and ($repo_id == "" or note("repo-id") == $repo_id)
      ' >/dev/null 2>&1 \
      || dl_die "$DL_PRECOND" "--blocked-by '$ref' belongs to another project or repository"

    if dl_depends_reaches "$blocker" "${UUID,,}"; then
      dl_die "$DL_PRECOND" \
        "--blocked-by '$ref' would create a dependency cycle back to $UUID; both tasks would leave +READY permanently"
    fi

    if [ -z "${seen_blockers[$blocker]:-}" ]; then
      seen_blockers[$blocker]=1
      RESOLVED_BLOCKERS+=("$blocker")
    fi
  done
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
      # Giving the lease away and keeping box= recorded is what lets a later
      # re-claim of this task reuse a box another task has since adopted. The
      # task keeps no claim on a box it just parked; a re-claim warms fresh.
      dl_idle_box_park "$handle"
      dl_anno_set "$UUID" box ""
      dl_log "parked box $handle for the next task (idle timeout will reap it)"
    fi
  else
    dl_warn "could not park box $handle (it is no longer live)"
  fi
fi

# Record the blockers before clearing the claim: between the two writes the
# task is still owned, so no other worker can claim it in its ready-but-blocked
# window.
if [ "${#RESOLVED_BLOCKERS[@]}" -gt 0 ]; then
  declare -a merged_depends=()
  declare -A merged_seen=()
  while read -r existing; do
    [ -n "$existing" ] || continue
    if [ -z "${merged_seen[$existing]:-}" ]; then
      merged_seen[$existing]=1
      merged_depends+=("$existing")
    fi
  done < <(dl_depends_of "$UUID")
  for blocker in "${RESOLVED_BLOCKERS[@]}"; do
    if [ -z "${merged_seen[$blocker]:-}" ]; then
      merged_seen[$blocker]=1
      merged_depends+=("$blocker")
    fi
    # One annotation per blocker: `depends` alone says what blocks the task but
    # not that a worker hit it, when, or who. The next claimer reads the trail.
    dl_anno_set "$UUID" blocked-by "$blocker"
  done
  depends_list="$(IFS=,; printf '%s' "${merged_depends[*]}")"
  dl_do dl_task "$UUID" modify depends:"$depends_list"
  dl_anno_event "$UUID" "blocked by ${#RESOLVED_BLOCKERS[@]} task(s): ${RESOLVED_BLOCKERS[*]}"
  dl_log "recorded dependency; $UUID leaves +READY until its blockers complete"
fi

# Stop the task and clear the assignee so the slot frees up.
dl_do dl_task "$UUID" stop || true
dl_do dl_task_modify "$UUID" assignee:
dl_anno_event "$UUID" "released claim"
dl_log "released: $UUID"

if [ "${#RESOLVED_BLOCKERS[@]}" -gt 0 ] && [ -z "$DL_DRY_RUN" ]; then
  if [ "$(dl_task_export "$UUID" +READY status:pending | jq 'length' 2>/dev/null || echo 0)" != "0" ]; then
    dl_warn "$UUID is still +READY after recording its blockers — check 'task $UUID export' before another worker re-claims it"
  fi
fi
