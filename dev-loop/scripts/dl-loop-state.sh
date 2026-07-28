#!/usr/bin/env bash
# Read-only repository/goal state for the dev-loop controller.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPLEMENT_DIR="$(cd "$SCRIPT_DIR/../../dev-implement-task/scripts" && pwd)"
COMPLETE_DIR="$(cd "$SCRIPT_DIR/../../dev-complete-task/scripts" && pwd)"

# shellcheck source=../../dev-implement-task/scripts/dl-common.sh
# Sibling path is resolved from this script.
# shellcheck disable=SC1091
. "$IMPLEMENT_DIR/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-loop-state.sh --goal <slug> [--loop-id <uuid>]

Derives repository identity, selects the sole active loop for the goal, and
prints compact JSON describing actionable tasks and review branches. When no
active loop exists, returns state=new with a freshly proposed loop ID.

Read-only. Exit: 0 success, 20 usage/precondition/contradictory active loops.
EOF
}

GOAL=""
LOOP_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --goal)
      shift
      [ "$#" -gt 0 ] || { usage; dl_die "$DL_PRECOND" "--goal needs a value"; }
      GOAL="$1"
      ;;
    --loop-id)
      shift
      [ "$#" -gt 0 ] || { usage; dl_die "$DL_PRECOND" "--loop-id needs a value"; }
      LOOP_ID="${1,,}"
      ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; dl_die "$DL_PRECOND" "unknown flag: $1" ;;
    *) usage; dl_die "$DL_PRECOND" "unexpected argument: $1" ;;
  esac
  shift
done

[[ "$GOAL" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
  || dl_die "$DL_PRECOND" "--goal must be a lowercase slug"
if [ -n "$LOOP_ID" ]; then
  [[ "$LOOP_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || dl_die "$DL_PRECOND" "--loop-id must be a UUID"
fi

dl_require task jq git
dl_resolve_repo_identity

raw="$(dl_task_export)" \
  || dl_die "$DL_PRECOND" "failed to export Taskwarrior state"
[ -n "$raw" ] || raw='[]'

# shellcheck disable=SC2016
JQ_DEFS='
  def note($p):
    (.annotations // []) | map(.description)
    | map(select(startswith($p + ":"))) | last // ""
    | sub("^" + $p + ":\\s*"; "");
  def notes($p):
    [(.annotations // [])[].description
      | select(startswith($p + ":"))
      | sub("^" + $p + ":\\s*"; "")];
  def kv($k):
    (.annotations // []) | map(.description)
    | map(select(startswith($k + "="))) | last // ""
    | if . == "" then "" else .[($k|length)+1:] end;
'

scoped="$(printf '%s' "$raw" | jq \
  --arg project "$DL_REPO_PROJECT" --arg repo_id "$DL_REPO_ID" --arg goal "$GOAL" \
  "$JQ_DEFS"'
    [.[]
      | select((.project // "") == $project)
      | select(note("repo-id") == $repo_id)
      | select(note("goal") == $goal)]')" \
  || dl_die "$DL_PRECOND" "could not parse Taskwarrior state"

declare -A ACTIVE_LOOPS=()
while IFS= read -r id; do
  [ -n "$id" ] && ACTIVE_LOOPS["$id"]=1
done < <(printf '%s' "$scoped" | jq -r "$JQ_DEFS"'
  .[] | select(.status == "pending") | (note("loop-id") | ascii_downcase)
  | select(test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))')

# A preserved local review branch also makes an otherwise-completed loop
# resumable. Git, rather than an annotation alone, is ground truth.
while IFS=$'\t' read -r id branch; do
  [ -n "$id" ] && [ -n "$branch" ] || continue
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || continue
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    ACTIVE_LOOPS["$id"]=1
  fi
done < <(printf '%s' "$scoped" | jq -r "$JQ_DEFS"'
  .[] | [(note("loop-id") | ascii_downcase), kv("branch")] | @tsv')

if [ -n "$LOOP_ID" ]; then
  for active_id in "${!ACTIVE_LOOPS[@]}"; do
    [ "$active_id" = "$LOOP_ID" ] \
      || dl_die "$DL_PRECOND" "contradictory active loop for goal '$GOAL': $active_id (requested $LOOP_ID)"
  done
else
  case "${#ACTIVE_LOOPS[@]}" in
    0)
      if [ -r /proc/sys/kernel/random/uuid ]; then
        IFS= read -r LOOP_ID </proc/sys/kernel/random/uuid
      elif command -v uuidgen >/dev/null 2>&1; then
        LOOP_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
      else
        dl_die "$DL_PRECOND" "cannot generate a loop UUID"
      fi
      ;;
    1)
      for LOOP_ID in "${!ACTIVE_LOOPS[@]}"; do break; done
      ;;
    *)
      ids="$(printf '%s\n' "${!ACTIVE_LOOPS[@]}" | sort | paste -sd, -)"
      dl_die "$DL_PRECOND" "contradictory active loops for goal '$GOAL': $ids"
      ;;
  esac
fi

selected="$(printf '%s' "$scoped" | jq --arg loop_id "$LOOP_ID" "$JQ_DEFS"'
  [.[] | select((note("loop-id") | ascii_downcase) == $loop_id)]')"

normalized="$(printf '%s' "$selected" | jq "$JQ_DEFS"'
  map({
    uuid, short: .uuid[0:8], description,
    status, start: (.start // ""), assignee: (.assignee // ""),
    loop_round: (note("loop-round") | tonumber? // 0),
    route: (if ((.tags // []) | index("LARGE")) then "large"
            elif ((.tags // []) | index("SMALL")) then "small" else "standard" end),
    depends: (.depends // []), input: note("input"), review_of: note("review-of"),
    acceptance: notes("acceptance"), summary: notes("summary"),
    base: kv("base"), worktree: kv("worktree"), box: kv("box"),
    branch: kv("branch"), commits: kv("commits")
  }) | sort_by(.loop_round, .uuid)')"

task_count="$(printf '%s' "$normalized" | jq 'length')"
current_round="$(printf '%s' "$normalized" | jq '
  ([.[] | select(.status == "pending") | .loop_round | select(. > 0)]) as $pending
  | if ($pending | length) > 0 then ($pending | min)
    else ([.[].loop_round | select(. > 0)] | max // 1) end')"

reviews='[]'
if [ "$task_count" -gt 0 ]; then
  source_uuid="$(printf '%s' "$normalized" | jq -r '.[0].uuid')"
  reviews="$("$COMPLETE_DIR/dlc-collect.sh" --from-task "$source_uuid")" \
    || dl_die "$DL_PRECOND" "could not collect review branches for loop $LOOP_ID"
fi

jq -n \
  --arg project "$DL_REPO_PROJECT" --arg repo_id "$DL_REPO_ID" \
  --arg goal "$GOAL" --arg loop_id "$LOOP_ID" \
  --argjson round "$current_round" --argjson tasks "$normalized" \
  --argjson reviews "$reviews" '
  def current_pending: [$tasks[] | select(.status == "pending" and .loop_round == $round)];
  def implemented: [current_pending[] | select(.branch != "" and (.summary | length) > 0)];
  def active: [current_pending[] | select(.start != "")];
  {
    project: $project, repo_id: $repo_id, goal: $goal, loop_id: $loop_id,
    current_round: $round,
    state: (if ($tasks | length) == 0 then "new"
            elif (implemented | length) > 0 then "review"
            elif (active | length) > 0 then "implementing"
            elif (current_pending | length) > 0 then "claim"
            elif ([$reviews[] | select(.merged | not)] | length) > 0 then "review"
            else "complete" end),
    counts: {
      total: ($tasks | length),
      pending: ([$tasks[] | select(.status == "pending")] | length),
      queued_later: ([$tasks[] | select(.status == "pending" and .loop_round > $round)] | length),
      active: (active | length),
      completed: ([$tasks[] | select(.status == "completed")] | length),
      review_branches: ($reviews | length)
    },
    pending: current_pending,
    queued_later: [$tasks[] | select(.status == "pending" and .loop_round > $round)],
    completed: [$tasks[] | select(.status == "completed")
      | {uuid, short, loop_round, description, branch, summary}],
    review_branches: $reviews
  }'
