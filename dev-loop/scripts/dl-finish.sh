#!/usr/bin/env bash
# Best-effort persistent-worker notification followed by optional termination.
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  printf 'Usage: dl-finish.sh <event> [task-or-loop-id]\n' >&2
  exit 0
fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  printf 'Usage: dl-finish.sh <event> [task-or-loop-id]\n' >&2
  exit 20
fi

event="$1"
ref="${2:-}"
case "$event" in
  tasks-created|task-implemented|task-escalated|task-returned|task-completed|goal-completed|worker-idle) ;;
  *) printf 'dev-loop: unknown finish event: %s\n' "$event" >&2; exit 20 ;;
esac
# The poll loop cannot tell a finished run from an agent that simply stopped
# talking: both are just an exited process. Recording the event here is what
# lets `loop` back off and eventually stop, instead of launching a fresh worker
# — and a fresh box — every 30 seconds against work already in flight. Absence
# of the variable is valid; nothing else depends on the marker.
if [ -n "${DEV_LOOP_FINISH_MARKER:-}" ]; then
  { printf '%s %s\n' "$event" "$ref" >"$DEV_LOOP_FINISH_MARKER"; } 2>/dev/null || true
fi

if [ -n "${AGENT_NOTIFY:-}" ]; then
  "$AGENT_NOTIFY" "$event" "$ref" || true
fi
if [ -n "${AGENT_PID:-}" ]; then
  [[ "$AGENT_PID" =~ ^[0-9]+$ ]] && [ "$AGENT_PID" -gt 1 ] \
    || { printf 'dev-loop: invalid AGENT_PID: %s\n' "$AGENT_PID" >&2; exit 20; }
  kill -TERM "$AGENT_PID"
fi
