#!/usr/bin/env bash
# dlr-collect.sh — enumerate the available local review branches and the tasks
# that produced them.
#
#   dlr-collect.sh                  # every available review branch
#   dlr-collect.sh <repo>.<goal>    # only branches produced by that exact project
#
# Git is ground truth: the candidate set is refs/heads/review/* plus every
# branch= annotation value that still resolves to a local branch. Each branch
# is reverse-mapped to its producing task (any status — the producer is usually
# completed). Read-only. Emits a JSON array on stdout, one object per branch:
#
#   { branch, merged, ahead, superseded, superseded_by, base, task }
#     - merged: branch tip is an ancestor of HEAD (landed; just clean up)
#     - ahead:  commit count HEAD..branch
#     - superseded: another (non-deleted) task records this branch as its
#       input: — a fix is stacked on top; don't merge or review it on its own
#     - superseded_by: that task's short uuid ("" when not superseded)
#     - base:   task's base= annotation if it still resolves, else
#               merge-base HEAD..branch, else "" (the diff base)
#     - task:   {uuid, short, description, project, status, end, base, commits,
#                summary, acceptance} or null when no task records the branch
#
# Exit: 0 ok (no branches → 0 + "[]"), 20 precondition/usage.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dlr-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dlr-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dlr-collect.sh [<repo>.<goal>]

  <repo>.<goal>  only branches whose producing task exactly matches this project

Prints a JSON array of available review branches + producing-task context.
Exit: 0 ok, 20 precondition/usage.
EOF
}

SLUG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) usage; dlr_die "$DLR_PRECOND" "unknown flag: $1" ;;
    *)  [ -z "$SLUG" ] || { usage; dlr_die "$DLR_PRECOND" "unexpected extra argument: $1"; }
        SLUG="$1" ;;
  esac
  shift
done

dlr_require task jq git
dlr_in_git_repo

# branch -> producing-task context, across ALL task statuses (last wins).
# shellcheck disable=SC2119
raw="$(dlr_task_export)"
[ -n "$raw" ] || raw='[]'
by_branch="$(printf '%s' "$raw" | jq "$DLR_JQ_DEFS"'
  [ .[] | select(kv("branch") != "")
    | { branch: kv("branch"),
        uuid, short: .uuid[0:8], description,
        project: (.project // ""), status, end: (.end // ""),
        base: kv("base"), commits: kv("commits"),
        summary: notes("summary"), acceptance: notes("acceptance") } ]
  | INDEX(.branch)')"

# input-branch -> consuming task: a branch named by another task's latest
# "input:" annotation is superseded (its fix/successor builds on top of it).
by_input="$(printf '%s' "$raw" | jq '
  [ .[] | select(.status != "deleted")
    | { b: ((.annotations // []) | map(.description)
            | map(select(startswith("input:"))) | last // ""
            | sub("^input:\\s*"; "")),
        short: .uuid[0:8] }
    | select(.b != "") ]
  | INDEX(.b)')"

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
  sup="$(printf '%s' "$by_input" | jq --arg b "$b" '.[$b] // null')"
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
  out="$(printf '%s\n' "${entries[@]}" | jq -s --arg slug "$SLUG" '
    ( if $slug == "" then .
      else map(select(.task != null and .task.project == $slug)) end )
    | sort_by(.branch)')"
else
  out='[]'
fi

n="$(printf '%s' "$out" | jq 'length')"
unmerged="$(printf '%s' "$out" | jq '[.[] | select(.merged | not)] | length')"
orphans="$(printf '%s' "$out" | jq '[.[] | select(.task == null)] | length')"
superseded="$(printf '%s' "$out" | jq '[.[] | select(.superseded)] | length')"
dlr_log "found ${n} review branch(es): ${unmerged} unmerged, ${orphans} orphan, ${superseded} superseded"
printf '%s\n' "$out"
