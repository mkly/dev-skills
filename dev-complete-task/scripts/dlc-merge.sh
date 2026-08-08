#!/usr/bin/env bash
# dlc-merge.sh — merge a CLEAN review branch into the current branch, then
# delete it.
#
#   dlc-merge.sh <branch> [--dry-run]
#   dlc-merge.sh <branch> --continue
#   dlc-merge.sh <branch> --abort
#
# For branches the review judged clean (no fix tasks needed). Local only —
# never pushes. Behavior:
#   * dirty worktree or detached HEAD              → exit 20, do nothing
#   * branch already merged (ancestor of HEAD)     → skip merge, just delete
#   * merge conflicts                              → keep the merge IN PROGRESS,
#                                                    list the conflicted paths,
#                                                    exit 40 (resolve them, then
#                                                    re-run with --continue)
#   * success                                      → git branch -d <branch>,
#                                                    annotate producing task
# A conflict is not a review finding: the reviewer resolves it in the
# integration checkout, stages the resolution, and re-runs with --continue,
# which commits the merge and finishes the normal cleanup. --abort backs the
# merge out and keeps the branch when the conflict cannot be resolved here.
# The merge commit keeps git's default message (no attribution trailers), with a
# resolution note appended when the reviewer resolved conflicts.
# stdout: the resulting HEAD sha.
#
# Exit: 0 ok, 20 precondition/usage, 30 branch missing locally, 40 conflict
# awaiting resolution.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dlc-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dlc-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dlc-merge.sh <branch> [--dry-run]
       dlc-merge.sh <branch> --continue
       dlc-merge.sh <branch> --abort

  --dry-run    report what would happen; change nothing
  --continue   commit a conflicted merge the reviewer has resolved and staged,
               then delete the branch as usual
  --abort      abort the in-progress merge of <branch> and keep the branch

Merges the review branch into the current branch and deletes it (safe -d).
On conflict the merge is LEFT IN PROGRESS (exit 40) so the reviewer can resolve
it; resolve, `git add` the files, then re-run with --continue.
Exit: 0 ok, 20 precondition/usage, 30 branch missing, 40 conflict to resolve.
EOF
}

BRANCH=""; DRY=0; CONTINUE=0; ABORT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --continue) CONTINUE=1 ;;
    --abort) ABORT=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; dlc_die "$DLC_PRECOND" "unknown flag: $1" ;;
    *)  [ -z "$BRANCH" ] || { usage; dlc_die "$DLC_PRECOND" "unexpected extra argument: $1"; }
        BRANCH="$1" ;;
  esac
  shift
done
[ -n "$BRANCH" ] || { usage; dlc_die "$DLC_PRECOND" "review branch name required"; }
[ $((DRY + CONTINUE + ABORT)) -le 1 ] \
  || { usage; dlc_die "$DLC_PRECOND" "--dry-run, --continue, and --abort are mutually exclusive"; }

dlc_require task jq git
dlc_in_git_repo

cur="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ -n "$cur" ] || dlc_die "$DLC_PRECOND" "detached HEAD; check out the branch to merge into first"
[ "$cur" != "$BRANCH" ] || dlc_die "$DLC_PRECOND" "'$BRANCH' is the current branch; check out the target branch first"
git rev-parse --verify --quiet "refs/heads/${BRANCH}" >/dev/null \
  || dlc_die "$DLC_MISSING" "review branch '${BRANCH}' is not present locally"

git_dir="$(git rev-parse --git-dir)"
merge_head=""
[ -f "${git_dir}/MERGE_HEAD" ] && merge_head="$(git rev-parse --verify --quiet MERGE_HEAD || true)"

if [ "$CONTINUE" -eq 0 ] && [ "$ABORT" -eq 0 ]; then
  # A merge already in progress means a previous run stopped on a conflict; the
  # dirty-worktree check below would only report it as an unrelated precondition.
  [ -z "$merge_head" ] \
    || dlc_die "$DLC_PRECOND" "a merge is already in progress in '$cur'; resolve it and re-run with --continue, or back it out with --abort"
  [ -z "$(git status --porcelain --untracked-files=no)" ] \
    || dlc_die "$DLC_PRECOND" "worktree is dirty; commit or stash before merging review branches"
fi

task_json="$(dlc_task_for_branch "$BRANCH")"
[ "$task_json" != "null" ] \
  || dlc_die "$DLC_PRECOND" "review branch '$BRANCH' has no producing task; it cannot be merged without a reviewer claim"
uuid="$(printf '%s' "$task_json" | jq -r '.uuid // ""')"
dlc_require_reviewer "$uuid"

# conflicted_paths — currently unmerged index entries, one per line
# (repo-root-relative, so they read the same from any subdirectory).
conflicted_paths() { git diff --name-only --diff-filter=U; }

# leftover_markers — staged files still carrying conflict markers. Only the
# side markers are matched; a bare `=======` line is ordinary text in plenty of
# files.
leftover_markers() {
  local top f
  top="$(git rev-parse --show-toplevel)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$top/$f" ] || continue
    grep -qE '^(<<<<<<< |>>>>>>> )' -- "$top/$f" && printf '%s\n' "$f"
  done < <(git diff --cached --name-only --diff-filter=ACMR)
  return 0
}

# finish_merge — shared tail: drop worktrees holding the branch, delete it,
# annotate the producing task, print the resulting HEAD.
finish_merge() {
  local note="$1" wt_path
  # A dlc-test.sh (or other) worktree may still have $BRANCH checked out;
  # git branch -d refuses to delete a branch checked out elsewhere, so remove
  # any such worktree first.
  while IFS= read -r wt_path; do
    [ -n "$wt_path" ] || continue
    git worktree remove --force "$wt_path" >&2 \
      || dlc_warn "could not remove worktree at $wt_path (still holding '$BRANCH'?)"
  done < <(git worktree list --porcelain \
    | awk -v b="refs/heads/${BRANCH}" '/^worktree /{p=$2} /^branch /{if ($2==b) print p}')
  git worktree prune >/dev/null 2>&1 || true

  git branch -d "$BRANCH" >&2
  dlc_log "deleted review branch '$BRANCH'"

  # Audit trail on the producing task before completion finalizes it (best-effort;
  # legacy producers may already be completed).
  if [ -n "$uuid" ]; then
    if task rc.confirmation=no rc.verbose=nothing "$uuid" annotate \
         "dev-complete-task: merged $BRANCH into $cur ($(git rev-parse --short=12 HEAD))${note}; branch deleted" \
         >/dev/null 2>&1; then
      dlc_log "annotated producing task ${uuid:0:8}"
    else
      dlc_warn "could not annotate producing task ${uuid:0:8} (continuing)"
    fi
  else
    dlc_warn "no task records branch '$BRANCH' (orphan); nothing to annotate"
  fi

  git rev-parse HEAD
}

if [ "$ABORT" -eq 1 ]; then
  [ -n "$merge_head" ] \
    || dlc_die "$DLC_PRECOND" "no merge is in progress in '$cur'; nothing to abort"
  [ "$merge_head" = "$(git rev-parse "$BRANCH")" ] \
    || dlc_die "$DLC_PRECOND" "the in-progress merge is not of '$BRANCH' (MERGE_HEAD ${merge_head:0:12}); abort it deliberately with git"
  git merge --abort >&2
  dlc_log "aborted the merge of '$BRANCH' into '$cur'; branch kept"
  git rev-parse HEAD
  exit 0
fi

if [ "$CONTINUE" -eq 1 ]; then
  [ -n "$merge_head" ] \
    || dlc_die "$DLC_PRECOND" "no merge is in progress in '$cur'; run dlc-merge.sh '$BRANCH' first"
  [ "$merge_head" = "$(git rev-parse "$BRANCH")" ] \
    || dlc_die "$DLC_PRECOND" "the in-progress merge is not of '$BRANCH' (MERGE_HEAD ${merge_head:0:12})"
  unresolved="$(conflicted_paths)"
  [ -z "$unresolved" ] \
    || dlc_die "$DLC_CONFLICT" "still unmerged (resolve, then 'git add' each path):
$unresolved"
  markers="$(leftover_markers)"
  [ -z "$markers" ] \
    || dlc_die "$DLC_CONFLICT" "conflict markers remain in the staged resolution:
$markers"
  git commit --no-edit >&2 \
    || dlc_die "$DLC_PRECOND" "could not commit the resolved merge of '$BRANCH' into '$cur'"
  dlc_log "committed the resolved merge of '$BRANCH' into '$cur'"
  finish_merge " with reviewer-resolved conflicts"
  exit 0
fi

already_merged=0
git merge-base --is-ancestor "$BRANCH" HEAD >/dev/null 2>&1 && already_merged=1

if [ "$DRY" -eq 1 ]; then
  if [ "$already_merged" -eq 1 ]; then
    dlc_log "DRY-RUN: '$BRANCH' already merged into '$cur'; would delete it"
  else
    dlc_log "DRY-RUN: would merge '$BRANCH' into '$cur' ($(git rev-list --count "HEAD..${BRANCH}") commit(s)), then delete it"
  fi
  git rev-parse HEAD
  exit 0
fi

if [ "$already_merged" -eq 1 ]; then
  dlc_log "'$BRANCH' is already merged into '$cur'; deleting only"
else
  if ! git merge --no-edit "$BRANCH" >&2; then
    conflicts="$(conflicted_paths)"
    if [ -z "$conflicts" ]; then
      # Failed for some other reason (e.g. refused before starting); leave no
      # half-state behind.
      git merge --abort >/dev/null 2>&1 || true
      dlc_die "$DLC_PRECOND" "merge of '$BRANCH' into '$cur' failed without conflicts; see git output above"
    fi
    dlc_die "$DLC_CONFLICT" "merge of '$BRANCH' into '$cur' conflicts; merge left IN PROGRESS — resolve these paths, 'git add' them, then re-run: dlc-merge.sh '$BRANCH' --continue (or --abort to back out and keep the branch):
$conflicts"
  fi
  dlc_log "merged '$BRANCH' into '$cur'"
fi

finish_merge ""
