#!/usr/bin/env bash
# dl-run.sh — Phase 3: run a command inside a task's box.
#
#   dl-run.sh <uuid> [crabbox flags...] -- <cmd...>
#   dl-run.sh <uuid> --compact -- <cmd...>       # compact output with in-box RTK
#   dl-run.sh <uuid> --no-sync  -- <cmd...>      # skip the upload this run
#   dl-run.sh <uuid> -sync-only --               # just sync, run nothing
#
# Sync model: the task's own git WORKTREE (recorded as worktree= by dl-box.sh) is
# the single source of truth. Edit files there with normal tools; the box is a
# build/test sandbox, NOT an editing surface (Crabbox does not forward stdin into
# the box and never syncs .git, so in-box editing is unreliable). This wrapper
# cd's into that worktree and lets Crabbox re-sync it UP on every run by default,
# so every run reflects your latest edits and concurrent tasks never share a tree.
# Sync only ever pushes git-TRACKED files, so box-generated build artifacts
# (untracked) survive; conversely, NEW files you create must be `git add`-ed to
# reach the box. Use --no-sync to skip the upload for a fast re-run when you know
# nothing changed. The in-box command's exit code is forwarded verbatim.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-run.sh <uuid> [--force] [--compact] [--no-sync|--resync] [crabbox run flags...] -- <cmd...>

  --compact    compact command output with in-box `rtk test`; run unfiltered
               with a warning when RTK is unavailable in the box
  --no-sync    skip the upload this run (default is to sync the local tree up)
  --resync     accepted for compatibility; syncing up is already the default
  --force      bypass owner check
  --dry-run    log the crabbox invocation instead of running it

Forwards the in-box command's exit code. Exit 10 if the task is unclaimed or
owned by another owner; exit 20 if the task has no warmed box (run dl-box.sh first).
EOF
}

[ "$#" -ge 1 ] || { usage; dl_die "$DL_PRECOND" "task uuid required"; }
UUID="$1"; shift
case "$UUID" in -h|--help) usage; exit 0 ;; esac

EXTRA=(); CMD=(); seen_sep=0; RESYNC=0; FORCE_NOSYNC=0; FORCE=0; COMPACT=0
while [ "$#" -gt 0 ]; do
  if [ "$seen_sep" -eq 1 ]; then CMD+=("$1"); shift; continue; fi
  case "$1" in
    --)        seen_sep=1 ;;
    --compact) COMPACT=1 ;;
    --resync)  RESYNC=1 ;;
    --no-sync) FORCE_NOSYNC=1 ;;
    --force)   FORCE=1 ;;
    --dry-run) DL_DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         EXTRA+=("$1") ;;
  esac
  shift
done

dl_require jq task crabbox
dl_task_exists "$UUID" || dl_die "$DL_PRECOND" "no such task: $UUID"
[ "$FORCE" -eq 1 ] || dl_require_owner "$UUID"

handle="$(dl_anno_get "$UUID" box)"
[ -n "$handle" ] || dl_die "$DL_PRECOND" "task $UUID has no warmed box; run dl-box.sh $UUID first"

# Sync happens from the task's OWN worktree (the agent edits there), never the
# shared checkout — that is what keeps concurrent tasks isolated. Crabbox picks
# files via `git ls-files` from cwd, so cd into the worktree before running.
wt="$(dl_anno_get "$UUID" worktree)"
[ -n "$wt" ] || dl_die "$DL_PRECOND" "task $UUID has no recorded worktree; run dl-box.sh $UUID first"
[ -d "$wt" ] || dl_die "$DL_PRECOND" "recorded worktree is missing: $wt (re-run dl-box.sh $UUID to recreate it)"
cd "$wt" || dl_die "$DL_PRECOND" "could not enter worktree: $wt"

# Require a command unless this is an explicit sync-only / flags-only invocation.
sync_only=0
for e in ${EXTRA[@]+"${EXTRA[@]}"}; do [ "$e" = "-sync-only" ] && sync_only=1; done
if [ "$FORCE_NOSYNC" -eq 1 ] && [ "$sync_only" -eq 1 ]; then
  dl_die "$DL_PRECOND" "--no-sync cannot be combined with -sync-only"
fi
if [ "$COMPACT" -eq 1 ] && [ "$sync_only" -eq 1 ]; then
  dl_die "$DL_PRECOND" "--compact cannot be combined with -sync-only"
fi
if [ "${#CMD[@]}" -eq 0 ] && [ "$sync_only" -eq 0 ]; then
  usage; dl_die "$DL_PRECOND" "no command given (expected '<uuid> ... -- <cmd>')"
fi

project="$(dl_task_field "$UUID" '.project // ""')"
label="${project:-dev-loop}/${UUID}"

# Sync the local checkout UP by default (local is the source of truth). Only skip
# when explicitly asked via --no-sync. --resync is a no-op alias kept for compat.
nosync=0
[ "$FORCE_NOSYNC" -eq 1 ] && nosync=1
[ "$RESYNC" -eq 1 ] && nosync=0

payload=(${CMD[@]+"${CMD[@]}"})
if [ "$COMPACT" -eq 1 ]; then
  payload=(sh -c 'if command -v rtk >/dev/null 2>&1; then exec rtk test "$@"; fi; printf "%s\n" "dev-loop: WARN: --compact requested but rtk is unavailable in box; running unfiltered" >&2; exec "$@"' dev-loop-compact ${CMD[@]+"${CMD[@]}"})
fi

run=(crabbox run -provider "$CRABBOX_PROVIDER" -id "$handle" -keep -keep-on-failure -label "$label")
[ "$nosync" -eq 1 ] && run+=(-no-sync)
run+=(${EXTRA[@]+"${EXTRA[@]}"})
run+=(--)
run+=(${payload[@]+"${payload[@]}"})

dl_log "run on $handle (upload=$([ "$nosync" -eq 1 ] && echo skip || echo yes), compact=$([ "$COMPACT" -eq 1 ] && echo requested || echo no)): ${CMD[*]:-<flags only>}"
rc=0
dl_do "${run[@]}" || rc=$?
exit "$rc"
