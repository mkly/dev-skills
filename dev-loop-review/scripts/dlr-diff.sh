#!/usr/bin/env bash
# dlr-diff.sh — show one completed task's review diff (base..review-branch).
#
#   dlr-diff.sh <uuid> [--stat-only] [-- <extra git diff flags>]
#
# Resolves the task's base=<sha> and branch=<name> annotations (recorded by
# dev-loop) and prints, to stdout for the agent to read:
#   1. git log --oneline base..branch   (the commits this task produced)
#   2. git diff --stat base..branch     (files touched)
#   3. git diff base..branch            (full patch; omitted with --stat-only)
#
# Read-only. Exit: 0 ok, 20 precondition/usage, 30 review branch/base missing
# locally (e.g. branch deleted after merge, or base pruned).
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dlr-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dlr-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dlr-diff.sh <uuid> [--stat-only] [-- <extra git diff flags>]

  --stat-only   print log + diffstat only (skip the full patch)
  -- <flags>    pass extra flags through to `git diff` (e.g. -M -w)

Exit: 0 ok, 20 precondition/usage, 30 review branch or base not present locally.
EOF
}

UUID=""; STAT_ONLY=0; EXTRA=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stat-only) STAT_ONLY=1 ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; dlr_die "$DLR_PRECOND" "unknown flag: $1" ;;
    *)  [ -z "$UUID" ] || { usage; dlr_die "$DLR_PRECOND" "unexpected extra argument: $1"; }
        UUID="$1" ;;
  esac
  shift
done
[ -n "$UUID" ] || { usage; dlr_die "$DLR_PRECOND" "task uuid required"; }

dlr_require task jq git
dlr_in_git_repo

json="$(dlr_task_export "$UUID")"
[ "$(printf '%s' "$json" | jq 'length')" = "1" ] || dlr_die "$DLR_PRECOND" "no such task: $UUID"

base="$(printf '%s'  "$json" | dlr_anno_kv base)"
branch="$(printf '%s' "$json" | dlr_anno_kv branch)"

[ -n "$branch" ] || dlr_die "$DLR_MISSING" "task $UUID has no branch= annotation (no review branch was produced — nothing to diff)"
git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null \
  || dlr_die "$DLR_MISSING" "review branch '${branch}' is not present locally (deleted after merge, or never fetched)"
[ -n "$base" ] || dlr_die "$DLR_MISSING" "task $UUID has no base= annotation; cannot compute the review diff"
git cat-file -e "${base}^{commit}" 2>/dev/null \
  || dlr_die "$DLR_MISSING" "base commit ${base:0:12} is not present locally (pruned/rebased); re-fetch or recreate the review branch"

range="${base}..${branch}"
dlr_log "diff for $UUID: $range"
printf '### commits (%s)\n'   "$range";        git --no-pager log --oneline "$range"
printf '\n### files changed\n';                git --no-pager diff --stat "${EXTRA[@]}" "$range"
if [ "$STAT_ONLY" -ne 1 ]; then
  printf '\n### patch\n';                       git --no-pager diff "${EXTRA[@]}" "$range"
fi
