#!/usr/bin/env bash
# dl-setup.sh — idempotent harness setup for dev-implement-task.
#   * ensure the `assignee` UDA exists in taskrc (timestamped backup before edit)
#   * verify required tooling is present
#   * gate on `crabbox doctor` for the active provider
#   * report the effective owner id
set -euo pipefail
IFS=$'\n\t'

orig_owner="${DEV_LOOP_OWNER:-}"
# shellcheck source=dl-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dl-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: dl-setup.sh [--dry-run] [-h|--help]

Idempotent setup: defines the `assignee` UDA, verifies tooling, and runs
`crabbox doctor` for the active provider (CRABBOX_PROVIDER, default incus).
Safe to re-run. Exit 20 on any unmet precondition.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DL_DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; dl_die "$DL_PRECOND" "unknown argument: $1" ;;
  esac
  shift
done

# 1. Required tooling. incus is only needed when it is the active provider.
dl_require git jq flock task crabbox
[ "$CRABBOX_PROVIDER" = "incus" ] && dl_require incus

# 2. assignee UDA (check-before-write; back up taskrc only when changing it).
taskrc_candidates() {
  [ -n "${TASKRC:-}" ] && printf '%s\n' "$TASKRC"
  task diagnostics 2>/dev/null \
    | sed -nE 's/^[[:space:]]*(Config file|Configuration file)[^:]*:[[:space:]]*(.*)$/\2/ip' \
    | sed 's/^"//; s/"$//' || true
  task _show 2>/dev/null \
    | sed -nE 's/^[[:space:]]*(rc\.taskrc|taskrc|config)[[:space:]=:]+(.*)$/\2/ip' \
    | sed 's/^"//; s/"$//' || true
  printf '%s\n' "$HOME/.taskrc"
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/task/taskrc"
}

resolve_taskrc_file() {
  local c fallback=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ -n "$fallback" ] || fallback="$c"
    if [ -f "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done < <(taskrc_candidates)
  printf '%s\n' "$fallback"
}

TASKRC_FILE="$(resolve_taskrc_file)"
current_type="$(task _get rc.uda.assignee.type 2>/dev/null || true)"
if [ "$current_type" = "string" ]; then
  dl_log "assignee UDA already configured"
else
  if [ -f "$TASKRC_FILE" ]; then
    backup="${TASKRC_FILE}.dev-loop-bak-$(date +%Y%m%dT%H%M%S)"
    dl_do cp -p "$TASKRC_FILE" "$backup"
    dl_log "backed up taskrc -> $backup"
  else
    dl_warn "taskrc not found at $TASKRC_FILE; task config will create it"
  fi
  dl_do dl_task config uda.assignee.type string
  dl_do dl_task config uda.assignee.label Assignee
  if [ -z "$DL_DRY_RUN" ] && [ "$(task _get rc.uda.assignee.type 2>/dev/null || true)" != "string" ]; then
    dl_die "$DL_PRECOND" "failed to configure assignee UDA in $TASKRC_FILE"
  fi
  dl_log "configured assignee UDA"
fi

# 3. Provider readiness gate.
if [ -n "$DL_DRY_RUN" ]; then
  dl_log "DRY-RUN: skipping 'crabbox doctor -provider $CRABBOX_PROVIDER'"
elif crabbox doctor -provider "$CRABBOX_PROVIDER" >&2; then
  dl_log "crabbox doctor passed for provider '$CRABBOX_PROVIDER'"
else
  dl_die "$DL_PRECOND" "crabbox doctor failed for provider '$CRABBOX_PROVIDER' — fix the issues above (try: crabbox doctor -provider $CRABBOX_PROVIDER)"
fi

# 4. Owner report.
owner_file="${XDG_CONFIG_HOME:-$HOME/.config}/dev-loop/owner"
if [ ! -f "$owner_file" ]; then
  random_suffix="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  new_owner="$(dl_default_owner)/agent-${random_suffix}"
  dl_do mkdir -p "$(dirname "$owner_file")"
  dl_do sh -c "echo '$new_owner' > '$owner_file'"
  if [ -z "${orig_owner:-}" ]; then
    DEV_LOOP_OWNER="$new_owner"
  fi
fi

dl_log "effective owner: $DEV_LOOP_OWNER"
if [ -n "${orig_owner:-}" ]; then
  dl_log "DEV_LOOP_OWNER explicitly set in environment"
else
  dl_log "DEV_LOOP_OWNER resolved from state file ($owner_file)"
fi

dl_log "setup complete"
