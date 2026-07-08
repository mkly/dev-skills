#!/usr/bin/env bash
# dlr-merge.sh — merge a CLEAN review branch into the current branch, then
# delete it.
#
#   dlr-merge.sh <branch> [--dry-run]
#
# For branches the review judged clean (no fix tasks needed). Local only —
# never pushes. Behavior:
#   * dirty worktree or detached HEAD              → exit 20, do nothing
#   * branch already merged (ancestor of HEAD)     → skip merge, just delete
#   * merge conflicts                              → abort merge, keep branch,
#                                                    exit 30 (file a fix task)
#   * success                                      → git branch -d <branch>,
#                                                    annotate producing task
# The merge commit keeps git's default message (no attribution trailers).
# stdout: the resulting HEAD sha.
#
# Exit: 0 ok, 20 precondition/usage, 30 branch missing locally / merge conflict.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dlr-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dlr-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dlr-merge.sh <branch> [--dry-run]

  --dry-run   report what would happen; change nothing

Merges the review branch into the current branch and deletes it (safe -d).
Exit: 0 ok, 20 precondition/usage, 30 branch missing / merge conflict.
EOF
}

BRANCH=""; DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
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

cur="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ -n "$cur" ] || dlr_die "$DLR_PRECOND" "detached HEAD; check out the branch to merge into first"
[ "$cur" != "$BRANCH" ] || dlr_die "$DLR_PRECOND" "'$BRANCH' is the current branch; check out the target branch first"
git rev-parse --verify --quiet "refs/heads/${BRANCH}" >/dev/null \
  || dlr_die "$DLR_MISSING" "review branch '${BRANCH}' is not present locally"
[ -z "$(git status --porcelain --untracked-files=no)" ] \
  || dlr_die "$DLR_PRECOND" "worktree is dirty; commit or stash before merging review branches"

already_merged=0
git merge-base --is-ancestor "$BRANCH" HEAD >/dev/null 2>&1 && already_merged=1

if [ "$DRY" -eq 1 ]; then
  if [ "$already_merged" -eq 1 ]; then
    dlr_log "DRY-RUN: '$BRANCH' already merged into '$cur'; would delete it"
  else
    dlr_log "DRY-RUN: would merge '$BRANCH' into '$cur' ($(git rev-list --count "HEAD..${BRANCH}") commit(s)), then delete it"
  fi
  git rev-parse HEAD
  exit 0
fi

if [ "$already_merged" -eq 1 ]; then
  dlr_log "'$BRANCH' is already merged into '$cur'; deleting only"
else
  if ! git merge --no-edit "$BRANCH" >&2; then
    git merge --abort >/dev/null 2>&1 || true
    dlr_die "$DLR_MISSING" "merge of '$BRANCH' into '$cur' conflicts; merge aborted, branch kept — file a fix task with input: $BRANCH"
  fi
  dlr_log "merged '$BRANCH' into '$cur'"
fi

# A dlr-test.sh (or other) worktree may still have $BRANCH checked out;
# git branch -d refuses to delete a branch checked out elsewhere, so remove
# any such worktree first.
while IFS= read -r wt_path; do
  [ -n "$wt_path" ] || continue
  git worktree remove --force "$wt_path" >&2 \
    || dlr_warn "could not remove worktree at $wt_path (still holding '$BRANCH'?)"
done < <(git worktree list --porcelain \
  | awk -v b="refs/heads/${BRANCH}" '/^worktree /{p=$2} /^branch /{if ($2==b) print p}')
git worktree prune >/dev/null 2>&1 || true

git branch -d "$BRANCH" >&2
dlr_log "deleted review branch '$BRANCH'"

# Audit trail on the producing task (best-effort; the task is usually completed).
uuid="$(dlr_task_for_branch "$BRANCH" | jq -r '.uuid // ""')"
if [ -n "$uuid" ]; then
  if task rc.confirmation=no rc.verbose=nothing "$uuid" annotate \
       "dev-loop-review: merged $BRANCH into $cur ($(git rev-parse --short=12 HEAD)); branch deleted" \
       >/dev/null 2>&1; then
    dlr_log "annotated producing task ${uuid:0:8}"
  else
    dlr_warn "could not annotate producing task ${uuid:0:8} (continuing)"
  fi
else
  dlr_warn "no task records branch '$BRANCH' (orphan); nothing to annotate"
fi

git rev-parse HEAD
