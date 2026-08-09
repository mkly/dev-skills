#!/usr/bin/env bash
# dl-box.sh — warm (or reuse) one Incus box lease for a task, and
# create the per-task git worktree the agent edits in.
#
#   dl-box.sh <uuid> [--base <ref>] [--force] [--dry-run]
#
# If the task already records a live box (box=<handle> annotation, confirmed via
# `crabbox status`), that handle is reused. Otherwise a new lease is warmed with
# a deterministic friendly slug. The resolved handle is printed to stdout and
# recorded as box=<handle>; the resolved base commit is recorded as base=<sha>
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
Usage: dl-box.sh <uuid> [--base <ref>] [--force] [--dry-run] [-h|--help]

Warm or reuse the Incus box for a claimed task. Prints the box handle on stdout.
Records box=<handle>, base=<resolved sha>, and worktree=<path> as annotations,
and creates a per-task git worktree (branch dl/<slug>) for the agent to edit in.

  --base <ref>  override the first-run diff base (else latest input: annotation,
                else current HEAD)
  --force       bypass owner check
EOF
}

UUID=""; EXPLICIT_BASE=""; FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) shift; [ "$#" -gt 0 ] || { usage; dl_die "$DL_PRECOND" "--base needs a ref"; }
            EXPLICIT_BASE="$1" ;;
    --force) FORCE=1 ;;
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
[ "$FORCE" -eq 1 ] || dl_require_owner "$UUID"

desc="$(dl_task_field "$UUID" '.description // ""')"
project="$(dl_task_field "$UUID" '.project // ""')"
slug="$(dl_slug "$UUID" "$desc")"
label="${project:-dev-implement-task}/${UUID}"

# adoptable <handle> — true if the lease is live AND has at least 30 minutes
# of absolute TTL left, so an adopted box does not expire mid-task. Leases
# without TTL labels are treated as adoptable (liveness alone).
adoptable() {
  local j remaining
  j="$(crabbox status -provider "$CRABBOX_PROVIDER" -id "$1" -json 2>/dev/null)" || return 1
  remaining="$(printf '%s' "$j" | jq -r '
    ((.labels.created_at // empty | tonumber)
     + (.labels.ttl_secs // empty | tonumber) - now) | floor' 2>/dev/null || true)"
  [ -z "$remaining" ] || [ "$remaining" -ge 1800 ]
}

# input_ref <uuid> — latest "input: <ref>" annotation, or empty.
input_ref() {
  local uuid="$1"
  dl_task_export "$uuid" \
    | jq -r '
        (.[0].annotations // [])
        | map(.description)
        | map(select(startswith("input:")))
        | last // ""
        | sub("^input:[[:space:]]*"; "")
      ' 2>/dev/null
}

# resolve_base_ref <ref> <source> — print commit sha or die with context.
resolve_base_ref() {
  local ref="$1" source="$2" sha
  sha="$(git rev-parse --verify "${ref}^{commit}" 2>/dev/null || true)"
  [ -n "$sha" ] || dl_die "$DL_PRECOND" "cannot resolve ${source} base ref '$ref' to a commit"
  printf '%s\n' "$sha"
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
  if [ -n "$EXPLICIT_BASE" ]; then
    base="$(resolve_base_ref "$EXPLICIT_BASE" "--base")"
  else
    inref="$(input_ref "$UUID")"
    if [ -n "$inref" ]; then
      base="$(resolve_base_ref "$inref" "input:")"
    else
      base="$(git rev-parse HEAD 2>/dev/null || true)"
      [ -n "$base" ] || dl_die "$DL_PRECOND" "repository has no commits; make an initial commit before warming a box"
    fi
  fi
elif [ -n "$EXPLICIT_BASE" ]; then
  dl_warn "task already records base=${base:0:12}; ignoring --base '$EXPLICIT_BASE'"
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

# 2. Reuse an existing live box if one is recorded AND still ours. A task that
#    was released had its box parked for reuse while keeping the box=
#    annotation, so a live lease here may since have been adopted by another
#    pending task. Reusing it on that basis is what puts two live tasks in one
#    box; warm a fresh lease instead and leave theirs alone.
existing="$(dl_anno_get "$UUID" box)"
existing_alive=0
if [ -n "$existing" ] && dl_box_alive "$existing"; then
  existing_alive=1
  holder="$(dl_box_holder "$existing" "$UUID")"
  if [ -n "$holder" ]; then
    dl_warn "recorded box '$existing' now belongs to task ${holder:0:8}; warming a fresh lease"
    existing=""
    existing_alive=0
  fi
fi
if [ "$existing_alive" -eq 1 ]; then
  # A released-then-reclaimed task's box may also be the repo's parked box; take
  # it off the parked file so another task cannot adopt it out from under us.
  parked="$(dl_idle_box_claim)"
  if [ -n "$parked" ] && [ "$parked" != "$existing" ]; then dl_idle_box_park "$parked"; fi
  dl_log "reusing live box for $UUID: $existing (worktree: $wt)"
  printf '%s\n' "$existing"
  exit "$DL_OK"
fi
[ -n "$existing" ] && dl_warn "recorded box '$existing' is gone; warming a fresh lease"

# 3. Adopt the box parked by the previous task, if any. Adoption reclaims the
#    lease for THIS task's worktree and syncs it up — seconds, versus ~a minute
#    for a fresh warmup. Any failure falls through to a fresh warmup.
handle=""
if [ -z "$DL_DRY_RUN" ]; then
  parked="$(dl_idle_box_claim)"
  parked_holder=""
  [ -z "$parked" ] || parked_holder="$(dl_box_holder "$parked" "$UUID")"
  if [ -n "$parked_holder" ]; then
    # Parked but not idle: another pending task still holds this lease, so it
    # was parked in error (a release leaves box= recorded). Adopting it would
    # reclaim the box out from under a live task. Do not adopt it and do not
    # stop it — it is not ours to reap. Leaving it off the parked slot is
    # correct: the holder finds it via its own box= annotation, not the slot.
    dl_warn "parked box '$parked' is still held by task ${parked_holder:0:8}; warming a fresh lease"
  elif [ -n "$parked" ]; then
    if adoptable "$parked" \
       && ( cd "$wt" && crabbox run -provider "$CRABBOX_PROVIDER" \
              -id "$parked" -keep -reclaim -sync-only ) >&2; then
      handle="$parked"
      dl_log "adopted parked box $parked (skipped warmup)"
    else
      dl_warn "parked box '$parked' is unusable; warming a fresh lease"
      crabbox stop -provider "$CRABBOX_PROVIDER" -id "$parked" >/dev/null 2>&1 || true
    fi
  fi
fi

# 4. Warm a new lease if adoption did not produce one. Incus overrides (image,
# remote, profile, ...) come from CRABBOX_INCUS_* env vars, which crabbox reads
# on every subcommand.
if [ -n "$handle" ]; then
  :
elif [ -n "$DL_DRY_RUN" ]; then
  dl_log "DRY-RUN: crabbox warmup -provider $CRABBOX_PROVIDER -slug $slug -ttl $DEV_LOOP_TTL"
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
        -slug "$slug" -ttl "$DEV_LOOP_TTL" ) >"$warmout" 2>&1; then
    cat "$warmout" >&2
    dl_die "$DL_PRECOND" "crabbox warmup failed (see output above)"
  fi
  cat "$warmout" >&2

  # Resolve an authoritative handle: prefer a cbx_ id from the output, else the
  # requested slug, else a slug match in `crabbox list`. Confirm with `status`.
  handle=""
  cand="$(grep -oE 'cbx_[A-Za-z0-9_-]+' "$warmout" | head -n1 || true)"
  if [ -n "$cand" ] && dl_box_alive "$cand"; then handle="$cand"; fi
  if [ -z "$handle" ] && dl_box_alive "$slug"; then handle="$slug"; fi
  if [ -z "$handle" ]; then
    cand="$(crabbox list -provider "$CRABBOX_PROVIDER" -json 2>/dev/null \
      | jq -r --arg s "$slug" '.[]? | select((.labels.slug // .slug // .Slug // "")==$s)
                                     | (.labels.lease // .lease // (.id|strings) // .ID // .name // "")' \
      | head -n1 || true)"
    if [ -n "$cand" ] && dl_box_alive "$cand"; then handle="$cand"; fi
  fi
  [ -n "$handle" ] || dl_die "$DL_PRECOND" "could not resolve a live box handle after warmup"
fi

# 5. Record machine state on the task (base/worktree already recorded above).
dl_anno_set "$UUID" box "$handle"
dl_anno_event "$UUID" "box ready: $handle (base ${base:0:12}, worktree $wt)"
dl_log "box ready for $UUID: $handle (base ${base:0:12}, worktree $wt)"
printf '%s\n' "$handle"
