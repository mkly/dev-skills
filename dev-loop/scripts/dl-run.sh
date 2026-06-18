#!/usr/bin/env bash
# dl-run.sh — Phase 3: run a command inside a task's box.
#
#   dl-run.sh <uuid> [crabbox flags...] -- <cmd...>
#   dl-run.sh <uuid> --no-sync  -- <cmd...>     # skip the upload this run
#   dl-run.sh <uuid> -sync-only --              # just sync, run nothing
#
# Sync model: your LOCAL checkout is the single source of truth. Edit files
# locally with normal tools; the box is a build/test sandbox, NOT an editing
# surface (Crabbox does not forward stdin into the box and never syncs .git, so
# in-box editing is unreliable). Crabbox re-syncs the checkout UP on every run by
# default — this wrapper keeps that default so every run reflects your latest
# local edits. Sync only ever pushes git-TRACKED files, so box-generated build
# artifacts (untracked) survive; conversely, NEW files you create locally must be
# `git add`-ed to reach the box. Use --no-sync to skip the upload for a fast
# re-run when you know nothing changed. The in-box command's exit code is
# forwarded verbatim.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-run.sh <uuid> [--no-sync|--resync] [crabbox run flags...] -- <cmd...>

  --no-sync    skip the upload this run (default is to sync the local tree up)
  --resync     accepted for compatibility; syncing up is already the default
  --dry-run    log the crabbox invocation instead of running it

Forwards the in-box command's exit code. Exit 20 if the task has no warmed box
(run dl-box.sh first).
EOF
}

[ "$#" -ge 1 ] || { usage; dl_die "$DL_PRECOND" "task uuid required"; }
UUID="$1"; shift
case "$UUID" in -h|--help) usage; exit 0 ;; esac

EXTRA=(); CMD=(); seen_sep=0; RESYNC=0; FORCE_NOSYNC=0
while [ "$#" -gt 0 ]; do
  if [ "$seen_sep" -eq 1 ]; then CMD+=("$1"); shift; continue; fi
  case "$1" in
    --)        seen_sep=1 ;;
    --resync)  RESYNC=1 ;;
    --no-sync) FORCE_NOSYNC=1 ;;
    --dry-run) DL_DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         EXTRA+=("$1") ;;
  esac
  shift
done

dl_require jq task crabbox
dl_task_exists "$UUID" || dl_die "$DL_PRECOND" "no such task: $UUID"

handle="$(dl_anno_get "$UUID" box)"
[ -n "$handle" ] || dl_die "$DL_PRECOND" "task $UUID has no warmed box; run dl-box.sh $UUID first"

# Require a command unless this is an explicit sync-only / flags-only invocation.
sync_only=0
for e in ${EXTRA[@]+"${EXTRA[@]}"}; do [ "$e" = "-sync-only" ] && sync_only=1; done
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

run=(crabbox run -provider "$CRABBOX_PROVIDER" -id "$handle" -keep -keep-on-failure -label "$label")
[ "$nosync" -eq 1 ] && run+=(-no-sync)
run+=(${EXTRA[@]+"${EXTRA[@]}"})
run+=(--)
run+=(${CMD[@]+"${CMD[@]}"})

dl_log "run on $handle (upload=$([ "$nosync" -eq 1 ] && echo skip || echo yes)): ${CMD[*]:-<flags only>}"
rc=0
dl_do "${run[@]}" || rc=$?
exit "$rc"
