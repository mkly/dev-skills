#!/usr/bin/env bash
# dl-box.sh — Phase 3: warm (or reuse) one Incus box lease for a task, and
# create the per-task git worktree the agent edits in.
#
#   dl-box.sh <uuid> [--dry-run]
#
# If the task already records a live box (box=<handle> annotation, confirmed via
# `crabbox status`), that handle is reused. Otherwise a new lease is warmed with
# a deterministic friendly slug. The resolved handle is printed to stdout and
# recorded as box=<handle>; the current local HEAD is recorded as base=<sha>
# (the merge-back diff base). One lease per task — never leaks a second.
#
# It also creates a dedicated git worktree on a scratch branch dl/<slug>, rooted
# at base, OUTSIDE the repo tree, and records it as worktree=<path>. The agent
# edits THERE — never in the shared checkout — so concurrent tasks on one machine
# never share a working tree. One worktree per task; a live one is reused.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-box.sh <uuid> [--dry-run] [-h|--help]

Warm or reuse the Incus box for a claimed task. Prints the box handle on stdout.
Records box=<handle>, base=<local HEAD sha>, and worktree=<path> as annotations,
and creates a per-task git worktree (branch dl/<slug>) for the agent to edit in.
EOF
}

UUID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DL_DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; dl_die "$DL_PRECOND" "unknown flag: $1" ;;
    *)  [ -z "$UUID" ] || { usage; dl_die "$DL_PRECOND" "unexpected extra argument: $1"; }
        UUID="$1" ;;
  esac
  shift
done
[ -n "$UUID" ] || { usage; dl_die "$DL_PRECOND" "task uuid required"; }

dl_require git jq task crabbox
dl_in_git_repo
dl_task_exists "$UUID" || dl_die "$DL_PRECOND" "no such task: $UUID"

desc="$(dl_task_field "$UUID" '.description // ""')"
project="$(dl_task_field "$UUID" '.project // ""')"
slug="$(dl_slug "$UUID" "$desc")"
label="${project:-dev-loop}/${UUID}"

# box_alive <handle> — true if crabbox can see a live lease by that id/slug.
box_alive() {
  [ -n "$1" ] || return 1
  crabbox status -provider "$CRABBOX_PROVIDER" -id "$1" -json >/dev/null 2>&1
}

# ensure_worktree <path> <branch> <base> — make sure a live per-task worktree
# exists at <path> on scratch branch <branch>, rooted at <base>. Reuses a live
# one; recreates after a prune; reuses the branch if it already exists.
ensure_worktree() {
  local wt="$1" wbranch="$2" base="$3"
  if git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    dl_log "reusing worktree for $UUID: $wt"
    return 0
  fi
  if [ -n "$DL_DRY_RUN" ]; then
    dl_log "DRY-RUN: git worktree add ${wbranch} -> $wt (base ${base:0:12})"
    return 0
  fi
  git worktree prune >/dev/null 2>&1 || true   # drop stale registrations first
  mkdir -p "$(dirname "$wt")"
  if git show-ref --verify --quiet "refs/heads/${wbranch}"; then
    git worktree add "$wt" "$wbranch" >&2 \
      || dl_die "$DL_PRECOND" "could not create worktree at $wt on existing branch $wbranch"
  else
    git worktree add -b "$wbranch" "$wt" "$base" >&2 \
      || dl_die "$DL_PRECOND" "could not create worktree at $wt (branch $wbranch, base ${base:0:12})"
  fi
  dl_log "worktree ready for $UUID: $wt (branch $wbranch, base ${base:0:12})"
}

# 1. Resolve the diff base and ensure the per-task worktree. base is the
#    worktree's branch point AND the merge-back diff base; once recorded it is
#    sticky (re-derived from HEAD only on the very first warm). The agent edits
#    in this worktree — the shared checkout's own working tree is never used, so
#    its dirty state is irrelevant to the task.
base="$(dl_anno_get "$UUID" base)"
had_base=1
if [ -z "$base" ]; then
  had_base=0
  base="$(git rev-parse HEAD 2>/dev/null || true)"
  [ -n "$base" ] || dl_die "$DL_PRECOND" "repository has no commits; make an initial commit before warming a box"
fi

wbranch="dl/${slug}"
wt="$(dl_anno_get "$UUID" worktree)"
had_wt=1
if [ -z "$wt" ]; then had_wt=0; wt="$(dl_worktree_dir_for "$slug")"; fi
ensure_worktree "$wt" "$wbranch" "$base"

# Record base/worktree once (annotations are append-only; avoid duplicates on
# re-runs). dl-run.sh and dl-merge-back.sh read worktree= to know where to sync.
[ "$had_base" -eq 1 ] || dl_anno_set "$UUID" base "$base"
[ "$had_wt" -eq 1 ]   || dl_anno_set "$UUID" worktree "$wt"

# 2. Reuse an existing live box if one is recorded.
existing="$(dl_anno_get "$UUID" box)"
if [ -n "$existing" ] && box_alive "$existing"; then
  dl_log "reusing live box for $UUID: $existing (worktree: $wt)"
  printf '%s\n' "$existing"
  exit "$DL_OK"
fi
[ -n "$existing" ] && dl_warn "recorded box '$existing' is gone; warming a fresh lease"

# 3. Warm a new lease.
mapfile -t incus_flags < <(dl_crabbox_incus_flags)
if [ -n "$DL_DRY_RUN" ]; then
  dl_log "DRY-RUN: crabbox warmup -provider $CRABBOX_PROVIDER ${incus_flags[*]:-} -slug $slug -ttl $DEV_LOOP_TTL"
  handle="$slug"
else
  warmout="$(mktemp "${TMPDIR:-/tmp}/dl-warm.XXXXXX")"
  trap 'rm -f "$warmout"' EXIT
  dl_log "warming box (slug=$slug ttl=$DEV_LOOP_TTL label=$label)"
  # Warm from the task's worktree so crabbox records repoRoot=<worktree>. dl-run.sh
  # cd's into the same worktree before `crabbox run`; if the lease were warmed from
  # the main checkout instead, repoRoot would mismatch and every run would demand
  # `-reclaim`. Warming from the worktree keeps the two in agreement.
  if ! ( cd "$wt" && crabbox warmup -provider "$CRABBOX_PROVIDER" \
        ${incus_flags[@]+"${incus_flags[@]}"} \
        -slug "$slug" -ttl "$DEV_LOOP_TTL" ) >"$warmout" 2>&1; then
    cat "$warmout" >&2
    dl_die "$DL_PRECOND" "crabbox warmup failed (see output above)"
  fi
  cat "$warmout" >&2

  # Resolve an authoritative handle: prefer a cbx_ id from the output, else the
  # requested slug, else a slug match in `crabbox list`. Confirm with `status`.
  handle=""
  cand="$(grep -oE 'cbx_[A-Za-z0-9_-]+' "$warmout" | head -n1 || true)"
  if [ -n "$cand" ] && box_alive "$cand"; then handle="$cand"; fi
  if [ -z "$handle" ] && box_alive "$slug"; then handle="$slug"; fi
  if [ -z "$handle" ]; then
    cand="$(crabbox list -provider "$CRABBOX_PROVIDER" -json 2>/dev/null \
      | jq -r --arg s "$slug" '.[]? | select((.labels.slug // .slug // .Slug // "")==$s)
                                     | (.labels.lease // .lease // (.id|strings) // .ID // .name // "")' \
      | head -n1 || true)"
    if [ -n "$cand" ] && box_alive "$cand"; then handle="$cand"; fi
  fi
  [ -n "$handle" ] || dl_die "$DL_PRECOND" "could not resolve a live box handle after warmup"
fi

# 4. Record machine state on the task (base/worktree already recorded above).
dl_anno_set "$UUID" box "$handle"
dl_anno_event "$UUID" "box warmed: $handle (base ${base:0:12}, worktree $wt)"
dl_log "box ready for $UUID: $handle (base ${base:0:12}, worktree $wt)"
printf '%s\n' "$handle"
