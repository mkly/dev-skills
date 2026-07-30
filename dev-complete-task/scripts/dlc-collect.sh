#!/usr/bin/env bash
# dlc-collect.sh — enumerate the available local review branches and the tasks
# that produced them.
#
#   dlc-collect.sh                                      # every branch
#   dlc-collect.sh --from-task <task-ref>              # producer's exact loop
#
# Git is ground truth: the candidate set is refs/heads/review/* plus every
# branch= annotation value that still resolves to a local branch. Each branch
# is reverse-mapped to its producing task across all statuses for legacy
# compatibility. Read-only. Emits a JSON array on stdout, one object per branch:
#
#   { branch, merged, ahead, superseded, superseded_by, base, task }
#     - merged: branch tip is an ancestor of HEAD (landed; just clean up)
#     - ahead:  commit count HEAD..branch
#     - superseded: another (non-deleted) task records this branch as its
#       input: — a fix is stacked on top; don't merge or review it on its own
#     - superseded_by: that task's short uuid ("" when not superseded)
#     - base:   task's base= annotation if it still resolves, else
#               merge-base HEAD..branch, else "" (the diff base)
#     - task:   {uuid, short, description, project, repo_id, goal, loop_id,
#                loop_round, status, end, base, commits, input, summary,
#                acceptance, reviewer, review_started} or null when no task
#                records the branch
#
# Exit: 0 ok (no branches → 0 + "[]"), 20 precondition/usage.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dlc-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dlc-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dlc-collect.sh [--from-task <task-ref>]

  --from-task <task-ref>  derive repository, goal, and loop identity from one
                          producer task and the current GitHub origin

Prints a JSON array of available review branches + producing-task context.
Exit: 0 ok, 20 precondition/usage.
EOF
}

SOURCE_TASK=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from-task)
      shift
      [ "$#" -gt 0 ] || { usage; dlc_die "$DLC_PRECOND" "--from-task needs a value"; }
      [ -z "$SOURCE_TASK" ] || dlc_die "$DLC_PRECOND" "--from-task may be supplied only once"
      SOURCE_TASK="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; dlc_die "$DLC_PRECOND" "unknown flag: $1" ;;
    *) usage; dlc_die "$DLC_PRECOND" "unexpected argument: $1" ;;
  esac
  shift
done

dlc_require task jq git
dlc_in_git_repo

PROJECT_FILTER=""
REPO_ID_FILTER=""
GOAL_FILTER=""
LOOP_ID_FILTER=""
if [ -n "$SOURCE_TASK" ]; then
  dlc_resolve_repo_identity
  source_json="$(dlc_task_export "$SOURCE_TASK")" \
    || dlc_die "$DLC_PRECOND" "failed to export identity source task: $SOURCE_TASK"
  [ "$(printf '%s' "$source_json" | jq 'length')" = 1 ] \
    || dlc_die "$DLC_PRECOND" "identity source '$SOURCE_TASK' must resolve to exactly one task"
  source_identity="$(printf '%s' "$source_json" | jq -c "$DLC_JQ_DEFS"'
    .[0] | {project: (.project // ""), repo_id: note("repo-id"),
      goal: note("goal"), loop_id: (note("loop-id") | ascii_downcase)}')"
  PROJECT_FILTER="$(printf '%s' "$source_identity" | jq -r .project)"
  REPO_ID_FILTER="$(printf '%s' "$source_identity" | jq -r .repo_id)"
  GOAL_FILTER="$(printf '%s' "$source_identity" | jq -r .goal)"
  LOOP_ID_FILTER="$(printf '%s' "$source_identity" | jq -r .loop_id)"
  [ "$PROJECT_FILTER" = "$DLC_REPO_PROJECT" ] && [ "$REPO_ID_FILTER" = "$DLC_REPO_ID" ] \
    || dlc_die "$DLC_PRECOND" "identity source does not match the current GitHub origin '$DLC_REPO_ID'"
  [[ "$GOAL_FILTER" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    || dlc_die "$DLC_PRECOND" "identity source has no valid goal annotation"
  [[ "$LOOP_ID_FILTER" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || dlc_die "$DLC_PRECOND" "identity source has no valid loop-id annotation"
fi

# branch -> producing-task context, across ALL task statuses (last wins).
# shellcheck disable=SC2119
raw="$(dlc_task_export)"
[ -n "$raw" ] || raw='[]'
by_branch="$(printf '%s' "$raw" | jq "$DLC_JQ_DEFS"'
  [ .[] | select(kv("branch") != "")
    | { branch: kv("branch"),
        uuid, short: .uuid[0:8], description,
        project: (.project // ""), status, end: (.end // ""),
        base: kv("base"), commits: kv("commits"),
        repo_id: note("repo-id"), goal: note("goal"),
        loop_id: note("loop-id"), loop_round: note("loop-round"),
        input: note("input"),
        summary: notes("summary"), acceptance: notes("acceptance"),
        reviewer: kv("reviewer"), review_started: kv("review-start") } ]
  | INDEX(.branch)')"

# input-branch -> consuming task: a branch named by another task's latest
# "input:" annotation is superseded (its fix/successor builds on top of it).
by_input="$(printf '%s' "$raw" | jq "$DLC_JQ_DEFS"'
  [ .[] | select(.status != "deleted")
    | { b: ((.annotations // []) | map(.description)
            | map(select(startswith("input:"))) | last // ""
            | sub("^input:\\s*"; "")),
        short: .uuid[0:8], project: (.project // ""),
        repo_id: note("repo-id"), goal: note("goal"),
        loop_id: (note("loop-id") | ascii_downcase) }
    | select(.b != "") ]')"

declare -A SEEN
entries=()
add_branch() {
  local b="$1" merged=false ahead task base sup
  [ -n "$b" ] || return 0
  [ -n "${SEEN[$b]:-}" ] && return 0
  SEEN["$b"]=1
  # Only AVAILABLE branches: skip recorded names that no longer exist locally.
  git show-ref --verify --quiet "refs/heads/${b}" || return 0
  git merge-base --is-ancestor "$b" HEAD >/dev/null 2>&1 && merged=true
  ahead="$(git rev-list --count "HEAD..${b}" 2>/dev/null || echo 0)"
  task="$(printf '%s' "$by_branch" | jq --arg b "$b" '.[$b] // null')"
  base="$(printf '%s' "$task" | jq -r '.base // ""')"
  if [ -z "$base" ] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
    base="$(git merge-base HEAD "$b" 2>/dev/null || echo '')"
  fi
  sup="$(printf '%s' "$by_input" | jq --arg b "$b" --argjson producer "$task" '
    [ .[] | select(.b == $b)
      | select($producer == null or
          (.project == $producer.project
           and .repo_id == $producer.repo_id
           and .goal == $producer.goal
           and .loop_id == ($producer.loop_id | ascii_downcase))) ]
    | last // null')"
  entries+=("$(jq -n --arg branch "$b" --argjson merged "$merged" \
      --argjson ahead "$ahead" --arg base "$base" --argjson task "$task" \
      --argjson sup "$sup" \
      '{branch: $branch, merged: $merged, ahead: $ahead,
        superseded: ($sup != null), superseded_by: ($sup.short // ""),
        base: $base, task: $task}')")
}

while IFS= read -r b; do add_branch "$b"; done \
  < <(git for-each-ref --format='%(refname:short)' refs/heads/review 2>/dev/null || true)
while IFS= read -r b; do add_branch "$b"; done \
  < <(printf '%s' "$by_branch" | jq -r 'keys[]')

if [ "${#entries[@]}" -gt 0 ]; then
  out="$(printf '%s\n' "${entries[@]}" | jq -s \
    --arg project "$PROJECT_FILTER" --arg repo_id "$REPO_ID_FILTER" \
    --arg goal "$GOAL_FILTER" --arg loop_id "$LOOP_ID_FILTER" '
    map(select(
      ($project == "" or (.task != null and .task.project == $project))
      and ($repo_id == "" or (.task != null and .task.repo_id == $repo_id))
      and ($goal == "" or (.task != null and .task.goal == $goal))
      and ($loop_id == "" or
        (.task != null and (.task.loop_id | ascii_downcase) == $loop_id))
    ))
    | sort_by(.branch)')"
else
  out='[]'
fi

n="$(printf '%s' "$out" | jq 'length')"
unmerged="$(printf '%s' "$out" | jq '[.[] | select(.merged | not)] | length')"
orphans="$(printf '%s' "$out" | jq '[.[] | select(.task == null)] | length')"
superseded="$(printf '%s' "$out" | jq '[.[] | select(.superseded)] | length')"
dlc_log "found ${n} review branch(es): ${unmerged} unmerged, ${orphans} orphan, ${superseded} superseded"
printf '%s\n' "$out"
