#!/usr/bin/env bash
# dl-merge-back.sh — Phase 4: bring a task's work back as a NEW local branch.
#
#   dl-merge-back.sh <uuid> [<branch>] [--dry-run]
#
# The task's git worktree (recorded as worktree=, rooted at the recorded base) is
# the single source of truth: the agent edits there and the box is a build/test
# sandbox only (it is never edited in, and dl-run.sh only ever syncs the worktree
# UP). So the review branch is a purely LOCAL git operation — no box round-trip:
#
#   Stage the worktree's whole working tree into a throwaway index, write that
#   tree, and re-parent it onto the recorded base via `git commit-tree -p <base>`.
#   The result is a clean one-commit review branch whose `base..branch` diff is
#   exactly the task's changes.
#
# NEVER pushes to a remote. NEVER merges into the current/main branch — it only
# creates a review branch for a human/agent to inspect and merge deliberately.
#
# Exit: 0 ok, 20 precondition (no base/worktree, missing worktree),
#       30 nothing to merge (tree identical to base) / branch collision.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-merge-back.sh <uuid> [<branch>] [--dry-run] [-h|--help]

  <branch>    target local review branch (default: review/<task-slug>)
  --dry-run   log what would happen instead of creating the branch

Creates a NEW local branch from the task worktree's working tree, re-parented
onto the recorded base, as one clean commit. Never pushes to a remote and never
merges into your current branch. Prints the branch name.
Exit: 0 ok, 20 precondition, 30 no-op (identical to base) / branch already exists.
EOF
}

UUID=""; BRANCH=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DL_DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; dl_die "$DL_PRECOND" "unknown flag: $1" ;;
    *)  if   [ -z "$UUID" ];   then UUID="$1"
        elif [ -z "$BRANCH" ]; then BRANCH="$1"
        else usage; dl_die "$DL_PRECOND" "unexpected extra argument: $1"; fi ;;
  esac
  shift
done
[ -n "$UUID" ] || { usage; dl_die "$DL_PRECOND" "task uuid required"; }

dl_require git jq task
dl_in_git_repo
dl_task_exists "$UUID" || dl_die "$DL_PRECOND" "no such task: $UUID"

base="$(dl_anno_get "$UUID" base)"
[ -n "$base" ] || dl_die "$DL_PRECOND" "task $UUID has no recorded base; run dl-box.sh $UUID first"

# Snapshot the task's OWN worktree (where the agent edited), not the shared
# checkout. Branches/objects are shared across all of a repo's worktrees, so the
# review branch we create is still visible from the main checkout.
wt="$(dl_anno_get "$UUID" worktree)"
[ -n "$wt" ] || dl_die "$DL_PRECOND" "task $UUID has no recorded worktree; run dl-box.sh $UUID first"
[ -d "$wt" ] || dl_die "$DL_PRECOND" "recorded worktree is missing: $wt (re-run dl-box.sh $UUID to recreate it)"
cd "$wt" || dl_die "$DL_PRECOND" "could not enter worktree: $wt"

desc="$(dl_task_field "$UUID" '.description // ""')"
slug="$(dl_slug "$UUID" "$desc")"
: "${BRANCH:=review/${slug}}"        # the local review branch we create
msg="${desc:-dev-loop task $UUID}"

# Fail fast on a local branch collision (before doing any work).
current="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo '')"
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  dl_die "$DL_MERGE" "local branch '${BRANCH}' already exists; pass an explicit <branch> name"
fi
[ "$BRANCH" != "$current" ] || dl_die "$DL_MERGE" "refusing to overwrite the current branch '${BRANCH}'; choose another"

# Preserve the local committer identity on the produced commit; fall back to a
# generic dev-loop identity when git has no global user configured.
author_name="$(git config user.name 2>/dev/null || true)";  : "${author_name:=dev-loop}"
author_email="$(git config user.email 2>/dev/null || true)"; : "${author_email:=dev-loop@localhost}"

if [ -n "$DL_DRY_RUN" ]; then
  dl_log "DRY-RUN: would stage worktree $wt, write its tree, re-parent onto ${base:0:12} -> ${BRANCH}"
  printf '%s\n' "$BRANCH"
  exit "$DL_OK"
fi

# Stage the entire working tree into a THROWAWAY index (never touching the task's
# real index), then write that tree. `git add -A` against an empty index records
# every non-ignored file present in the worktree, so gitignored build artifacts
# are excluded and NEW files are included automatically — the snapshot is exactly
# the reviewable source state.
tmp_index="$(mktemp "${TMPDIR:-/tmp}/dl-mb-index.XXXXXX")"
trap 'rm -f "$tmp_index"' EXIT
GIT_INDEX_FILE="$tmp_index" git add -A
snap_tree="$(GIT_INDEX_FILE="$tmp_index" git write-tree)" \
  || dl_die "$DL_PRECOND" "failed to snapshot the worktree tree"
[ -n "$snap_tree" ] || dl_die "$DL_PRECOND" "snapshot produced no tree"

if git cat-file -e "${base}^{commit}" 2>/dev/null; then
  # No real change vs base → nothing to review.
  if git diff --quiet "${base}^{tree}" "$snap_tree" 2>/dev/null; then
    dl_die "$DL_MERGE" "no changes to merge back for $UUID (worktree is identical to base ${base:0:12})"
  fi
  new_commit="$(GIT_AUTHOR_NAME="$author_name"   GIT_AUTHOR_EMAIL="$author_email" \
                GIT_COMMITTER_NAME="$author_name" GIT_COMMITTER_EMAIL="$author_email" \
                git commit-tree "$snap_tree" -p "$base" -m "$msg")" \
    || dl_die "$DL_MERGE" "failed to re-parent the snapshot onto base ${base:0:12}"
else
  dl_warn "recorded base ${base:0:12} is not present locally (pruned?); creating an orphan review commit"
  new_commit="$(GIT_AUTHOR_NAME="$author_name"   GIT_AUTHOR_EMAIL="$author_email" \
                GIT_COMMITTER_NAME="$author_name" GIT_COMMITTER_EMAIL="$author_email" \
                git commit-tree "$snap_tree" -m "$msg")" \
    || dl_die "$DL_MERGE" "failed to create the review commit"
fi

git branch "$BRANCH" "$new_commit" >&2 \
  || dl_die "$DL_MERGE" "failed to create review branch ${BRANCH}"

dl_anno_set "$UUID" branch "$BRANCH"
# Record the commits this task produced so they stay associated with it (the
# branch may later be merged/renamed/deleted; the annotation is the durable link).
head_sha="$(git rev-parse "$BRANCH" 2>/dev/null || echo '')"
ncommits="$(git rev-list --count "${base}..${BRANCH}" 2>/dev/null || echo '?')"
if [ -n "$head_sha" ]; then
  dl_anno_set "$UUID" commits "${base:0:12}..${head_sha:0:12} (n=${ncommits})"
fi
dl_anno_event "$UUID" "merged worktree to local branch ${BRANCH}"
dl_log "review branch ready: ${BRANCH} (NOT merged — review and merge deliberately)"
git --no-pager log --oneline "${base}..${BRANCH}" >&2 || true
git --no-pager diff --stat "${base}..${BRANCH}" >&2 || true
printf '%s\n' "$BRANCH"
