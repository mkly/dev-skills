#!/usr/bin/env bash
# dlr-collect.sh — enumerate completed dev-loop tasks and their review artifacts.
#
#   dlr-collect.sh <project-slug> [--since <dur>]
#   dlr-collect.sh --since <dur>            # all projects, time-windowed
#
# Emits a JSON array (one object per task) on stdout for the agent to drive the
# review from. Read-only: never mutates tasks, branches, or the repo.
#
# Each object: { uuid, short, description, project, end, base, branch, commits,
#                summary, acceptance, reviewable }
#   - base/branch/commits come from dev-loop's key=value annotations (last wins)
#   - summary/acceptance gather all "summary:"/"acceptance:" notes (newline-joined)
#   - reviewable is true when a review branch was recorded (something to diff)
#
# Scoping (per the skill's per-goal default):
#   * with a <project-slug>: every completed task in that project
#   * --since only (no slug): every completed task across projects that carries
#     dev-loop annotations (branch=/commits=), so unrelated tasks are excluded
#
# Exit: 0 ok (empty match → 0 + "[]"), 20 precondition/usage.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dlr-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dlr-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dlr-collect.sh <project-slug> [--since <dur>]
       dlr-collect.sh --since <dur>
       dlr-collect.sh                       (defaults to --since $DLR_SINCE)

  <project-slug>  dev-loop goal slug (Taskwarrior project) to review
  --since <dur>   only tasks completed within <dur> (e.g. 90m, 2h, 7d, 1w)

Prints a JSON array of completed tasks + review artifacts on stdout.
Exit: 0 ok, 20 precondition/usage.
EOF
}

SLUG=""; SINCE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since) shift; [ "$#" -gt 0 ] || { usage; dlr_die "$DLR_PRECOND" "--since needs a duration"; }; SINCE="$1" ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; dlr_die "$DLR_PRECOND" "unknown flag: $1" ;;
    *)  [ -z "$SLUG" ] || { usage; dlr_die "$DLR_PRECOND" "unexpected extra argument: $1"; }
        SLUG="$1" ;;
  esac
  shift
done

dlr_require task jq

# Build the Taskwarrior filter. A slug scopes to the goal; --since windows by
# completion time. With neither, fall back to the default window so a bare call
# still does something useful.
filter=(status:completed)
require_dl=false
if [ -n "$SLUG" ]; then
  filter+=("project:$SLUG")
else
  : "${SINCE:=$DLR_SINCE}"
  require_dl=true
  dlr_warn "no project slug given; reviewing dev-loop tasks completed in the last $SINCE across all projects"
fi
[ -n "$SINCE" ] && filter+=("end.after:now-${SINCE}")

raw="$(dlr_task_export "${filter[@]}")"
[ -n "$raw" ] || raw='[]'

out="$(printf '%s' "$raw" | jq --argjson require_dl "$require_dl" '
  def kv($k):
    (.annotations // []) | map(.description)
    | map(select(startswith($k + "=")))
    | last // ""
    | if . == "" then "" else .[($k|length)+1:] end;
  def notes($p):
    [ (.annotations // []) | map(.description)
      | map(select(startswith($p + ":"))) | .[]
      | sub("^" + $p + ":\\s*"; "") ] | join("\n");
  # A task is dev-loop-managed if it carries any dev-loop event annotation
  # (e.g. "dev-loop: claimed …", written by dl_anno_event) or any of the
  # key=value state markers — even tasks that never produced a review branch.
  def managed:
    (.annotations // []) | map(.description) | any(
      startswith("dev-loop:") or startswith("box=") or startswith("base=")
      or startswith("branch=") or startswith("commits="));
  map(({ managed: managed } + {
    uuid, short: (.uuid[0:8]), description,
    project: (.project // ""), end: (.end // ""),
    base: kv("base"), branch: kv("branch"), commits: kv("commits"),
    summary: notes("summary"), acceptance: notes("acceptance")
  }) | . + { reviewable: (.branch != "") })
  | ( if $require_dl then map(select(.managed)) else . end )
  | map(del(.managed))
  | sort_by(.end)
')"

n="$(printf '%s' "$out" | jq 'length')"
reviewable="$(printf '%s' "$out" | jq '[.[] | select(.reviewable)] | length')"
dlr_log "matched ${n} completed task(s), ${reviewable} with a review branch"
printf '%s\n' "$out"
