#!/usr/bin/env bash
# dlc-test.sh — run a check (tests/build/lint) against a
# review branch inside an isolated Crabbox/Incus box — the same sandbox model
# dev-implement-task uses for build/test, never the host.
#
#   dlc-test.sh <branch> [--compact] [--keep-box] [--no-sync] [--dry-run] -- <cmd...>
#
# This helper deliberately never mutates or reuses the producer's implementation
# box. Its lease is keyed on the BRANCH itself via a deterministic slug —
# never on a Taskwarrior uuid, no claim, no task write. Checks the branch out
# into a dedicated worktree OUTSIDE the repo (reused across calls for the same
# branch), warms (or reuses) a short-lived Crabbox lease from that worktree,
# runs the given command in the box, and forwards its exit code VERBATIM.
# Stops the box afterward unless --keep-box.
#
# Read-only w.r.t. the repo's current checkout: never touches HEAD or the
# worktree the agent is reviewing from.
#
# Exit: 0 ok (forwarded from <cmd> once it runs), 20 precondition/usage,
# 30 branch missing locally. Once <cmd> actually runs, ITS exit code is
# forwarded as-is, even if it happens to collide with 20/30.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dlc-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dlc-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dlc-test.sh <branch> [--compact] [--keep-box] [--no-sync] [--dry-run] -- <cmd...>

  --compact    compact command output with in-box `rtk test`; run unfiltered
               with a warning when RTK is unavailable in the box
  --keep-box   don't stop the box after this run (reuse it for another call)
  --no-sync    skip the worktree upload this run (fast re-run, no local changes)
  --dry-run    log the crabbox invocation instead of running it

Runs <cmd...> inside a Crabbox/Incus box checked out at <branch>'s tip. Forwards
<cmd>'s exit code verbatim. Never edits, merges, or pushes anything.
Exit: 0 ok, 20 precondition/usage, 30 branch not present locally.
EOF
}

BRANCH=""; KEEP_BOX=0; NO_SYNC=0; DRY=0; COMPACT=0; CMD=(); seen_sep=0
while [ "$#" -gt 0 ]; do
  if [ "$seen_sep" -eq 1 ]; then CMD+=("$1"); shift; continue; fi
  case "$1" in
    --)          seen_sep=1 ;;
    --compact)   COMPACT=1 ;;
    --keep-box)  KEEP_BOX=1 ;;
    --no-sync)   NO_SYNC=1 ;;
    --dry-run)   DRY=1 ;;
    -h|--help)   usage; exit 0 ;;
    -*)          usage; dlc_die "$DLC_PRECOND" "unknown flag: $1" ;;
    *)           [ -z "$BRANCH" ] || { usage; dlc_die "$DLC_PRECOND" "unexpected extra argument: $1"; }
                 BRANCH="$1" ;;
  esac
  shift
done
[ -n "$BRANCH" ] || { usage; dlc_die "$DLC_PRECOND" "review branch name required"; }
[ "${#CMD[@]}" -gt 0 ] || { usage; dlc_die "$DLC_PRECOND" "no command given (expected '<branch> -- <cmd>')"; }

dlc_require git jq crabbox
dlc_in_git_repo
git rev-parse --verify --quiet "refs/heads/${BRANCH}" >/dev/null \
  || dlc_die "$DLC_MISSING" "review branch '${BRANCH}' is not present locally"

slug="$(dlc_slug_for_branch "$BRANCH")"
wt="$(dlc_worktree_dir_for "$slug")"
label="dev-complete-task/${BRANCH}"

# box_alive <handle> — true if crabbox can see a live lease by that id/slug.
box_alive() {
  [ -n "$1" ] || return 1
  crabbox status -provider "$CRABBOX_PROVIDER" -id "$1" -json >/dev/null 2>&1
}

# ensure_worktree <path> <branch> — make sure a worktree at <path> is checked
# out exactly at <branch>'s tip; recreate if stale, absent, or pruned.
ensure_worktree() {
  local path="$1" branch="$2" cur_head branch_head
  branch_head="$(git rev-parse "refs/heads/${branch}")"
  if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    cur_head="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
    if [ "$cur_head" = "$branch_head" ]; then
      dlc_log "reusing test worktree for ${branch}: $path"
      return 0
    fi
    dlc_log "test worktree at $path is stale (not at ${branch}'s tip); recreating"
    if [ "$DRY" -eq 0 ]; then
      git worktree remove --force "$path" >/dev/null 2>&1 || rm -rf "$path"
    fi
  fi
  if [ "$DRY" -eq 1 ]; then
    dlc_log "DRY-RUN: git worktree add $path $branch"
    return 0
  fi
  git worktree prune >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$path")"
  git worktree add "$path" "$branch" >&2 \
    || dlc_die "$DLC_PRECOND" "could not create worktree at $path for branch $branch (checked out elsewhere?)"
}

ensure_worktree "$wt" "$BRANCH"

# Warm (or reuse) the branch-keyed lease. No task/annotation involved — the
# slug is deterministic, so a live box is found by id alone.
if box_alive "$slug"; then
  handle="$slug"
  dlc_log "reusing live box for ${BRANCH}: $handle"
else
  mapfile -t incus_flags < <(dlc_crabbox_incus_flags)
  if [ "$DRY" -eq 1 ]; then
    dlc_log "DRY-RUN: crabbox warmup -provider $CRABBOX_PROVIDER ${incus_flags[*]:-} -slug $slug -ttl $DLC_TEST_TTL"
    handle="$slug"
  else
    warmout="$(mktemp "${TMPDIR:-/tmp}/dlc-warm.XXXXXX")"
    trap 'rm -f "$warmout"' EXIT
    dlc_log "warming box for ${BRANCH} (slug=$slug ttl=$DLC_TEST_TTL)"
    # Warm from the test worktree so crabbox's repoRoot matches where `crabbox
    # run` below will cd, matching dev-implement-task's dl-box.sh model.
    if ! ( cd "$wt" && crabbox warmup -provider "$CRABBOX_PROVIDER" \
          ${incus_flags[@]+"${incus_flags[@]}"} \
          -slug "$slug" -ttl "$DLC_TEST_TTL" ) >"$warmout" 2>&1; then
      cat "$warmout" >&2
      dlc_die "$DLC_PRECOND" "crabbox warmup failed (see output above)"
    fi
    cat "$warmout" >&2
    handle=""
    cand="$(grep -oE 'cbx_[A-Za-z0-9_-]+' "$warmout" | head -n1 || true)"
    if [ -n "$cand" ] && box_alive "$cand"; then handle="$cand"; fi
    if [ -z "$handle" ] && box_alive "$slug"; then handle="$slug"; fi
    [ -n "$handle" ] || dlc_die "$DLC_PRECOND" "could not resolve a live box handle after warmup"
  fi
fi

payload=("${CMD[@]}")
if [ "$COMPACT" -eq 1 ]; then
  payload=(sh -c 'if command -v rtk >/dev/null 2>&1; then exec rtk test "$@"; fi; printf "%s\n" "dev-complete-task: WARN: --compact requested but rtk is unavailable in box; running unfiltered" >&2; exec "$@"' dev-complete-task-compact "${CMD[@]}")
fi

run=(crabbox run -provider "$CRABBOX_PROVIDER" -id "$handle" -keep -keep-on-failure -label "$label")
[ "$NO_SYNC" -eq 1 ] && run+=(-no-sync)
run+=(--)
run+=("${payload[@]}")

rc=0
if [ "$DRY" -eq 1 ]; then
  dlc_log "DRY-RUN: (cd $wt && ${run[*]})"
else
  dlc_log "run on $handle (upload=$([ "$NO_SYNC" -eq 1 ] && echo skip || echo yes), compact=$([ "$COMPACT" -eq 1 ] && echo requested || echo no)): ${CMD[*]}"
  ( cd "$wt" && "${run[@]}" ) || rc=$?
fi

if [ "$KEEP_BOX" -eq 0 ] && [ "$DRY" -eq 0 ]; then
  crabbox stop -provider "$CRABBOX_PROVIDER" -id "$handle" >/dev/null 2>&1 \
    || dlc_warn "could not stop box $handle (may already be gone)"
fi

exit "$rc"
