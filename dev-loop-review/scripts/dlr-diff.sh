#!/usr/bin/env bash
# dlr-diff.sh — show one review branch's diff (base..branch).
#
#   dlr-diff.sh <branch> [--stat-only] [-- <extra git diff flags>]
#
# Resolves the diff base from the producing task's base= annotation when it
# still resolves to a local commit, else falls back to `git merge-base HEAD
# <branch>`. Prints, to stdout for the agent to read:
#   1. git log --oneline base..branch   (the commits this branch carries)
#   2. git diff --stat base..branch     (files touched)
#   3. git diff base..branch            (full patch; omitted with --stat-only)
#
# Read-only. Exit: 0 ok, 20 precondition/usage, 30 branch not present locally
# or no diff base could be determined.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dlr-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dlr-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dlr-diff.sh <branch> [--stat-only] [-- <extra git diff flags>]

  --stat-only   print log + diffstat only (skip the full patch)
  -- <flags>    pass extra flags through to `git diff` (e.g. -M -w)

Exit: 0 ok, 20 precondition/usage, 30 branch missing locally / no diff base.
EOF
}

BRANCH=""; STAT_ONLY=0; EXTRA=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stat-only) STAT_ONLY=1 ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; dlr_die "$DLR_PRECOND" "unknown flag: $1" ;;
    *)  [ -z "$BRANCH" ] || { usage; dlr_die "$DLR_PRECOND" "unexpected extra argument: $1"; }
        BRANCH="$1" ;;
  esac
  shift
done
[ -n "$BRANCH" ] || { usage; dlr_die "$DLR_PRECOND" "review branch name required"; }

dlr_require task jq git
dlr_in_git_repo

git rev-parse --verify --quiet "refs/heads/${BRANCH}" >/dev/null \
  || dlr_die "$DLR_MISSING" "review branch '${BRANCH}' is not present locally"

task_json="$(dlr_task_for_branch "$BRANCH")"
base="$(printf '%s' "$task_json" | jq -r '.base // ""')"
if [ -n "$base" ] && git cat-file -e "${base}^{commit}" 2>/dev/null; then
  dlr_log "diff base from producing task's base= annotation: ${base:0:12}"
else
  [ -n "$base" ] && dlr_warn "recorded base ${base:0:12} is not present locally; falling back to merge-base"
  base="$(git merge-base HEAD "$BRANCH" 2>/dev/null || echo '')"
  [ -n "$base" ] || dlr_die "$DLR_MISSING" "cannot determine a diff base for '${BRANCH}' (no usable base= annotation, no merge-base with HEAD)"
  dlr_log "diff base from merge-base HEAD ${BRANCH}: ${base:0:12}"
fi

if [ "$task_json" != "null" ]; then
  short="$(printf '%s' "$task_json" | jq -r '.uuid[0:8]')"
  desc="$(printf '%s' "$task_json" | jq -r '.description // ""')"
  printf '### produced by task %s — %s\n\n' "$short" "$desc"
else
  printf '### ORPHAN branch — no task records it\n\n'
fi

range="${base}..${BRANCH}"
dlr_log "diff for ${BRANCH}: ${range:0:12}..${BRANCH}"
printf '### commits (%s)\n'   "$range";        git --no-pager log --oneline "$range"
printf '\n### files changed\n';                git --no-pager diff --stat "${EXTRA[@]}" "$range"
if [ "$STAT_ONLY" -ne 1 ]; then
  printf '\n### patch\n';                       git --no-pager diff "${EXTRA[@]}" "$range"
fi
