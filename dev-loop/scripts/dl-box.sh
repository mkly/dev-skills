#!/usr/bin/env bash
# dl-box.sh — Phase 3: warm (or reuse) one Incus box lease for a task.
#
#   dl-box.sh <uuid> [--dry-run]
#
# If the task already records a live box (box=<handle> annotation, confirmed via
# `crabbox status`), that handle is reused. Otherwise a new lease is warmed with
# a deterministic friendly slug. The resolved handle is printed to stdout and
# recorded as box=<handle>; the current local HEAD is recorded as base=<sha>
# (the merge-back diff base). One lease per task — never leaks a second.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-box.sh <uuid> [--dry-run] [-h|--help]

Warm or reuse the Incus box for a claimed task. Prints the box handle on stdout.
Records box=<handle> and base=<local HEAD sha> as task annotations.
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

# 1. Reuse an existing live box if one is recorded.
existing="$(dl_anno_get "$UUID" box)"
if [ -n "$existing" ] && box_alive "$existing"; then
  dl_log "reusing live box for $UUID: $existing"
  printf '%s\n' "$existing"
  exit "$DL_OK"
fi
[ -n "$existing" ] && dl_warn "recorded box '$existing' is gone; warming a fresh lease"

# 2. Record the diff base (local HEAD). The local checkout is the source of
#    truth: tracked-file edits sync up to the box on every dl-run.sh and fold
#    into the eventual task commit. NEW files must be `git add`-ed to sync.
base="$(git rev-parse HEAD 2>/dev/null || true)"
[ -n "$base" ] || dl_die "$DL_PRECOND" "repository has no commits; make an initial commit before warming a box"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  dl_warn "working tree is dirty; tracked-file edits sync up to the box and fold into the task commit (run 'git add' for new files so they sync too)"
fi

# 3. Warm a new lease.
mapfile -t incus_flags < <(dl_crabbox_incus_flags)
if [ -n "$DL_DRY_RUN" ]; then
  dl_log "DRY-RUN: crabbox warmup -provider $CRABBOX_PROVIDER ${incus_flags[*]:-} -slug $slug -ttl $DEV_LOOP_TTL"
  handle="$slug"
else
  warmout="$(mktemp "${TMPDIR:-/tmp}/dl-warm.XXXXXX")"
  trap 'rm -f "$warmout"' EXIT
  dl_log "warming box (slug=$slug ttl=$DEV_LOOP_TTL label=$label)"
  if ! crabbox warmup -provider "$CRABBOX_PROVIDER" \
        ${incus_flags[@]+"${incus_flags[@]}"} \
        -slug "$slug" -ttl "$DEV_LOOP_TTL" >"$warmout" 2>&1; then
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
      | jq -r --arg s "$slug" '.[]? | select((.slug // .Slug // .name // "")==$s)
                                     | (.id // .ID // .name // .slug // "")' \
      | head -n1 || true)"
    if [ -n "$cand" ] && box_alive "$cand"; then handle="$cand"; fi
  fi
  [ -n "$handle" ] || dl_die "$DL_PRECOND" "could not resolve a live box handle after warmup"
fi

# 4. Record machine state on the task.
dl_anno_set "$UUID" box "$handle"
dl_anno_set "$UUID" base "$base"
dl_anno_event "$UUID" "box warmed: $handle (base ${base:0:12})"
dl_log "box ready for $UUID: $handle (base ${base:0:12})"
printf '%s\n' "$handle"
