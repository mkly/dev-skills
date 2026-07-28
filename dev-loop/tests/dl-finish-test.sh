#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINISH="$ROOT/scripts/dl-finish.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-finish-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Write literal positional variables to the fixture.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" "$1" "$2" >"$NOTIFY_OUT"\n' \
  >"$TMP/notify"
chmod +x "$TMP/notify"

NOTIFY_OUT="$TMP/event" AGENT_NOTIFY="$TMP/notify" \
  "$FINISH" task-completed abc
[ "$(<"$TMP/event")" = $'task-completed\tabc' ] \
  || fail "notification payload was incorrect"

set +e
AGENT_PID=invalid "$FINISH" worker-idle >"$TMP/pid.out" 2>"$TMP/pid.err"
pid_rc=$?
set -e
[ "$pid_rc" -eq 20 ] || fail "invalid PID exited $pid_rc"
grep -Fq 'invalid AGENT_PID' "$TMP/pid.err" || fail "invalid PID was not diagnosed"

set +e
"$FINISH" typo >"$TMP/event.out" 2>"$TMP/event.err"
event_rc=$?
set -e
[ "$event_rc" -eq 20 ] || fail "unknown event exited $event_rc"
grep -Fq 'unknown finish event' "$TMP/event.err" \
  || fail "unknown event was not diagnosed"

printf 'PASS: dl-finish\n'
