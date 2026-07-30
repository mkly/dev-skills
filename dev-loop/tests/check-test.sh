#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/check.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/bin"

cat >"$TMP/bin/task" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TASK_LOG"
count="$(head -n 1 "$TASK_COUNTS")"
tail -n +2 "$TASK_COUNTS" >"$TASK_COUNTS.next"
mv "$TASK_COUNTS.next" "$TASK_COUNTS"
printf '%s\n' "$count"
EOF

cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SLEEP_LOG"
kill -TERM "$PPID"
EOF

cat >"$TMP/bin/reset" <<'EOF'
#!/usr/bin/env bash
printf 'reset\n' >>"$RESET_LOG"
EOF

for name in codex claude agy; do
  cat >"$TMP/bin/$name" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$(basename "$0")" "${AGENT_PID:-}" "$*" >>"$AGENT_LOG"
EOF
done
chmod +x "$TMP/bin/"*

export PATH="$TMP/bin:$PATH"
export TASK_LOG="$TMP/task.log"
export TASK_COUNTS="$TMP/task-counts"
export SLEEP_LOG="$TMP/sleep.log"
export RESET_LOG="$TMP/reset.log"
export AGENT_LOG="$TMP/agent.log"

clear_case() {
  : >"$TASK_LOG"
  : >"$SLEEP_LOG"
  : >"$RESET_LOG"
  : >"$AGENT_LOG"
}

expect_2() {
  set +e
  "$CHECK" "$@" >"$TMP/validation.out" 2>"$TMP/validation.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "invalid arguments exited $rc instead of 2: $*"
}

expect_2
grep -Fq -- '--agent is required' "$TMP/validation.err" \
  || fail "missing --agent was not diagnosed"
expect_2 --agent
grep -Fq -- '--agent requires a value' "$TMP/validation.err" \
  || fail "missing --agent value was not diagnosed"
expect_2 --agent nope
grep -Fq -- 'unsupported agent: nope' "$TMP/validation.err" \
  || fail "unsupported agent was not diagnosed"
expect_2 --wat
grep -Fq -- 'unknown argument: --wat' "$TMP/validation.err" \
  || fail "unknown option was not diagnosed"

clear_case
printf '0\n' >"$TASK_COUNTS"
set +e
"$CHECK" --agent codex >"$TMP/idle.out" 2>"$TMP/idle.err"
idle_rc=$?
set -e
[ "$idle_rc" -eq 143 ] || fail "idle polling fixture exited $idle_rc"
[ "$(<"$TASK_LOG")" = 'rc.verbose=nothing status:pending count' ] \
  || fail "default poll did not inspect all pending tasks"
grep -Fq 'No all pending tasks. Checking again in 5 seconds...' "$TMP/idle.out" \
  || fail "idle poll was not reported"
[ ! -s "$AGENT_LOG" ] || fail "an agent launched with no pending task"
[ "$(<"$SLEEP_LOG")" = '5' ] || fail "idle poll did not wait five seconds"

check_agent() {
  selected="$1"
  expected_flags="$2"
  shift 2
  clear_case
  printf '1\n' >"$TASK_COUNTS"

  set +e
  "$CHECK" --agent "$selected" "$@" >"$TMP/$selected.out" 2>"$TMP/$selected.err"
  agent_rc=$?
  set -e

  [ "$agent_rc" -eq 143 ] || fail "$selected restart fixture exited $agent_rc"
  IFS=$'\t' read -r invoked pid arguments <"$AGENT_LOG"
  [ "$invoked" = "$selected" ] || fail "$selected was not launched"
  [[ "$pid" =~ ^[0-9]+$ ]] || fail "$selected did not receive AGENT_PID"
  case "$arguments" in
    "$expected_flags"*) ;;
    *) fail "$selected flags were incorrect: $arguments" ;;
  esac
  grep -Fq "Inspect matching pending Taskwarrior tasks first" "$AGENT_LOG" \
    || fail "$selected prompt omitted Taskwarrior inspection"
  grep -Fq "use each task's existing goal and loop-id annotations" "$AGENT_LOG" \
    || fail "$selected prompt omitted durable identity reuse"
  grep -Fq "do not derive a new goal from this prompt" "$AGENT_LOG" \
    || fail "$selected prompt allowed a synthetic goal"
  grep -Fq "Process each existing goal and loop separately" "$AGENT_LOG" \
    || fail "$selected prompt omitted separate loop handling"
  grep -Fq 'Restarting in 5 seconds...' "$TMP/$selected.out" \
    || fail "$selected exit did not trigger restart polling"
  [ "$(<"$SLEEP_LOG")" = '5' ] || fail "$selected restart did not wait five seconds"
}

check_agent codex '--yolo '
grep -Fq 'Process pending tasks regardless of whether they have the +SMALL tag.' \
  "$AGENT_LOG" || fail "default prompt did not include non-small work"

check_agent claude '--dangerously-skip-permissions '

check_agent agy '--dangerously-skip-permissions --prompt-interactive ' --small
[ "$(<"$TASK_LOG")" = 'rc.verbose=nothing status:pending +SMALL count' ] \
  || fail "--small did not filter the Taskwarrior poll"
grep -Fq 'Only claim and process pending tasks tagged +SMALL' "$AGENT_LOG" \
  || fail "--small did not constrain the agent prompt"
grep -Fq 'Drain the existing pending +SMALL tasks' "$AGENT_LOG" \
  || fail "--small prompt described the wrong queue"

[ ! -s "$RESET_LOG" ] \
  || fail "non-interactive runs unexpectedly reset the terminal"

printf 'PASS: check\n'
