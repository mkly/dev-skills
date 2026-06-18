#!/usr/bin/env bash
# dl-merge-back.sh — Phase 4: bring a box's work back as a NEW local branch.
#
#   dl-merge-back.sh <uuid> [<branch>] [--dry-run]
#
# Crabbox uses `git ls-files` to choose which TRACKED files to rsync into the box
# and NEVER syncs the .git directory — so the box has no git history of its own.
# Merge-back therefore works by snapshot, not by shared history:
#
#   In the box (one crabbox run, so -download fires only on success): make a
#   throwaway repo, stage the whole working tree, and write a git bundle of a
#   single ORPHAN commit (no base prerequisite — it stands alone).
#
#   Locally: download + verify the bundle, import that orphan commit, then
#   RE-PARENT its tree onto the recorded base via `git commit-tree -p <base>`.
#   The result is a clean one-commit review branch whose `base..branch` diff is
#   exactly the task's changes — not a detached full-repo snapshot.
#
# NEVER pushes to a remote. NEVER merges into the current/main branch — it only
# creates a review branch for a human/agent to inspect and merge deliberately.
#
# Exit: 0 ok, 20 precondition (no box/base, in-box failure, run failure),
#       30 nothing to merge / bundle-verify fail / branch collision.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-merge-back.sh <uuid> [<branch>] [--dry-run] [-h|--help]

  <branch>    target local review branch (default: review/<task-slug>)
  --dry-run   log the crabbox invocation instead of running it

Creates a NEW local branch from a snapshot of the box's working tree (via git
bundle), re-parented onto the recorded base. Never pushes to a remote and never
merges into your current branch. Prints the branch name.
Exit: 0 ok, 20 precondition, 30 no-op / verify fail / branch already exists.
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

dl_require git jq task crabbox
dl_in_git_repo
dl_task_exists "$UUID" || dl_die "$DL_PRECOND" "no such task: $UUID"

handle="$(dl_anno_get "$UUID" box)"
[ -n "$handle" ] || dl_die "$DL_PRECOND" "task $UUID has no box; run dl-box.sh $UUID first"
base="$(dl_anno_get "$UUID" base)"
[ -n "$base" ] || dl_die "$DL_PRECOND" "task $UUID has no recorded base; run dl-box.sh $UUID first"

desc="$(dl_task_field "$UUID" '.description // ""')"
slug="$(dl_slug "$UUID" "$desc")"
wbranch="dl/${slug}"                 # the orphan branch built inside the box
: "${BRANCH:=review/${slug}}"        # the local review branch we create
msg="${desc:-dev-loop task $UUID}"

# Fail fast on a local branch collision (before doing any box work).
current="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo '')"
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  dl_die "$DL_MERGE" "local branch '${BRANCH}' already exists; pass an explicit <branch> name"
fi
[ "$BRANCH" != "$current" ] || dl_die "$DL_MERGE" "refusing to overwrite the current branch '${BRANCH}'; choose another"

repo_root="$(git rev-parse --show-toplevel)"
bundle_dir="${repo_root}/${DEV_LOOP_BUNDLE_DIR}"
local_bundle="${bundle_dir}/${slug}.bundle"
box_bundle="/tmp/${slug}.bundle"
import_ref="refs/dev-loop/import/${slug}"

# Preserve the local committer identity on the produced commit; fall back to a
# generic dev-loop identity when git has no global user configured.
author_name="$(git config user.name 2>/dev/null || true)";  : "${author_name:=dev-loop}"
author_email="$(git config user.email 2>/dev/null || true)"; : "${author_email:=dev-loop@localhost}"

# Ensure the download target dir exists and ignores itself (never tracked).
if [ -z "$DL_DRY_RUN" ]; then
  mkdir -p "$bundle_dir"
  [ -f "${bundle_dir}/.gitignore" ] || printf '*\n' > "${bundle_dir}/.gitignore"
  rm -f "$local_bundle"
fi

# In-box script: Crabbox never syncs .git, so build a throwaway repo and snapshot
# the working tree as a single ORPHAN commit, then bundle that one branch (no
# prerequisite). Emits a DL_* sentinel; any non-OK outcome exits non-zero so
# -download does NOT fire. Kept small so the crabbox argv never nears ARG_MAX.
read -r -d '' BOX_SCRIPT <<'BOX' || true
set -u
wbranch="$1"; msg="$2"; bundle="$3"
export GIT_AUTHOR_NAME="$4"  GIT_AUTHOR_EMAIL="$5"
export GIT_COMMITTER_NAME="$4" GIT_COMMITTER_EMAIL="$5"
git config --global --add safe.directory '*' >/dev/null 2>&1 || true
rm -rf .git 2>/dev/null || true                       # never the real repo; only a prior in-box init
git init -q >/dev/null 2>&1 || { echo DL_NOGIT; exit 41; }
git add -A
if git diff --cached --quiet 2>/dev/null; then echo DL_NOOP; exit 43; fi  # empty working tree
git commit -q --no-verify -m "$msg" >/dev/null 2>&1 || { echo DL_COMMIT_FAIL; exit 45; }
git branch -f "$wbranch" HEAD >/dev/null 2>&1 || true
rm -f "$bundle"
git bundle create "$bundle" "$wbranch" >/dev/null 2>&1 || { echo DL_BUNDLE_FAIL; exit 44; }
echo DL_BUNDLE_OK
BOX

# Always sync the local checkout UP (it is the source of truth) before snapshot.
run=(crabbox run -provider "$CRABBOX_PROVIDER" -id "$handle" -keep)
run+=(-download "${box_bundle}=${local_bundle}")
run+=(-- bash -c "$BOX_SCRIPT" dl-merge-back "$wbranch" "$msg" "$box_bundle" "$author_name" "$author_email")

if [ -n "$DL_DRY_RUN" ]; then
  dl_log "DRY-RUN: crabbox run -id $handle -download ${box_bundle}=${local_bundle} -- (in-box orphan snapshot + bundle)"
  dl_log "DRY-RUN: would verify ${local_bundle}, import ${wbranch}, re-parent its tree onto ${base:0:12} -> ${BRANCH}"
  printf '%s\n' "$BRANCH"
  exit "$DL_OK"
fi

runout="$(mktemp "${TMPDIR:-/tmp}/dl-mb.XXXXXX")"
trap 'rm -f "$runout"; git update-ref -d "$import_ref" 2>/dev/null || true' EXIT
dl_log "merge-back on $handle: snapshotting box working tree -> ${wbranch}"
rc=0
set +e
"${run[@]}" 2>&1 | tee "$runout"
rc="${PIPESTATUS[0]}"
set -e

# Interpret box outcome (sentinels take precedence over the raw exit code).
if   grep -q '\bDL_NOGIT\b'       "$runout"; then dl_die "$DL_PRECOND" "could not init a scratch repo inside the box (see output above)"
elif grep -q '\bDL_NOOP\b'        "$runout"; then dl_die "$DL_MERGE"   "no changes to merge back for $UUID (box working tree is empty)"
elif grep -q '\bDL_COMMIT_FAIL\b' "$runout"; then dl_die "$DL_PRECOND" "could not commit the box working tree (see output above)"
elif grep -q '\bDL_BUNDLE_FAIL\b' "$runout"; then dl_die "$DL_PRECOND" "git bundle failed inside the box (see output above)"
elif ! grep -q '\bDL_BUNDLE_OK\b' "$runout"; then dl_die "$DL_PRECOND" "merge-back run did not complete in the box (rc=$rc; see output above)"
fi

# -download fired on success: the bundle should now be local.
[ -f "$local_bundle" ] || dl_die "$DL_PRECOND" "expected bundle was not downloaded to $local_bundle"
# The bundle holds an orphan branch with no prerequisites, so verify is a pure
# integrity check (independent of local history).
git bundle verify "$local_bundle" >&2 \
  || dl_die "$DL_MERGE" "git bundle verify failed (bundle is corrupt or truncated)"

# Import the orphan snapshot into a private ref, then re-parent its tree onto the
# recorded base so the review branch is a clean one-commit increment.
git update-ref -d "$import_ref" 2>/dev/null || true
git fetch "$local_bundle" "refs/heads/${wbranch}:${import_ref}" >&2 \
  || dl_die "$DL_MERGE" "failed to import ${wbranch} from bundle"
snap_tree="$(git rev-parse "${import_ref}^{tree}" 2>/dev/null || true)"
[ -n "$snap_tree" ] || dl_die "$DL_MERGE" "imported snapshot has no tree"

if git cat-file -e "${base}^{commit}" 2>/dev/null; then
  # No real change vs base → nothing to review.
  if git diff --quiet "${base}^{tree}" "$snap_tree" 2>/dev/null; then
    dl_die "$DL_MERGE" "no changes to merge back for $UUID (box snapshot is identical to base ${base:0:12})"
  fi
  new_commit="$(GIT_AUTHOR_NAME="$author_name"   GIT_AUTHOR_EMAIL="$author_email" \
                GIT_COMMITTER_NAME="$author_name" GIT_COMMITTER_EMAIL="$author_email" \
                git commit-tree "$snap_tree" -p "$base" -m "$msg")" \
    || dl_die "$DL_MERGE" "failed to re-parent the snapshot onto base ${base:0:12}"
else
  dl_warn "recorded base ${base:0:12} is not present locally (pruned?); importing snapshot as an orphan branch"
  new_commit="$(git rev-parse "$import_ref")"
fi

git branch "$BRANCH" "$new_commit" >&2 \
  || dl_die "$DL_MERGE" "failed to create review branch ${BRANCH}"
git update-ref -d "$import_ref" 2>/dev/null || true

dl_anno_set "$UUID" branch "$BRANCH"
# Record the commits this task produced so they stay associated with it (the
# branch may later be merged/renamed/deleted; the annotation is the durable link).
head_sha="$(git rev-parse "$BRANCH" 2>/dev/null || echo '')"
ncommits="$(git rev-list --count "${base}..${BRANCH}" 2>/dev/null || echo '?')"
if [ -n "$head_sha" ]; then
  dl_anno_set "$UUID" commits "${base:0:12}..${head_sha:0:12} (n=${ncommits})"
fi
dl_anno_event "$UUID" "merged box work to local branch ${BRANCH}"
dl_log "review branch ready: ${BRANCH} (NOT merged — review and merge deliberately)"
git --no-pager log --oneline "${base}..${BRANCH}" >&2 || true
git --no-pager diff --stat "${base}..${BRANCH}" >&2 || true
printf '%s\n' "$BRANCH"
