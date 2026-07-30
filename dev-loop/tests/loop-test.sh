#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOOP="$ROOT/loop"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/loop-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/bin"

cat >"$TMP/bin/task" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TASK_LOG"
if [ "${!#}" = export ]; then
  cat "$TASK_EXPORT"
  exit
fi
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
export TASK_EXPORT="$TMP/task-export.json"
export SLEEP_LOG="$TMP/sleep.log"
export RESET_LOG="$TMP/reset.log"
export AGENT_LOG="$TMP/agent.log"

clear_case() {
  : >"$TASK_LOG"
  : >"$SLEEP_LOG"
  : >"$RESET_LOG"
  : >"$AGENT_LOG"
  printf '[]\n' >"$TASK_EXPORT"
}

expect_2() {
  set +e
  "$LOOP" "$@" >"$TMP/validation.out" 2>"$TMP/validation.err"
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
expect_2 --agent codex --implement-task --complete-task
grep -Fq -- 'are mutually exclusive' "$TMP/validation.err" \
  || fail "conflicting stage flags were not diagnosed"
expect_2 --agent codex --small --no-small
grep -Fq -- 'are mutually exclusive' "$TMP/validation.err" \
  || fail "conflicting scope flags were not diagnosed"

clear_case
printf '0\n' >"$TASK_COUNTS"
set +e
"$LOOP" --agent codex >"$TMP/idle.out" 2>"$TMP/idle.err"
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
  mode="$3"
  expected_query="$4"
  expected_stage_prompt="$5"
  shift 5
  clear_case
  printf '1\n' >"$TASK_COUNTS"
  printf '%s\n' '[{"annotations":[{"description":"branch=review/test"},{"description":"summary: ready"}]}]' \
    >"$TASK_EXPORT"

  set +e
  "$LOOP" --agent "$selected" "$@" >"$TMP/$mode-$selected.out" 2>"$TMP/$mode-$selected.err"
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
  grep -Fq "existing goal and loop-id annotations" "$AGENT_LOG" \
    || fail "$selected prompt omitted durable identity reuse"
  grep -Fq "do not derive a new goal from this prompt" "$AGENT_LOG" \
    || fail "$selected prompt allowed a synthetic goal"
  grep -Fq "$expected_stage_prompt" "$AGENT_LOG" \
    || fail "$selected $mode prompt omitted its lifecycle boundary"
  [ "$(<"$TASK_LOG")" = "$expected_query" ] \
    || fail "$selected $mode used the wrong discovery query: $(<"$TASK_LOG")"
  grep -Fq 'Restarting in 5 seconds...' "$TMP/$mode-$selected.out" \
    || fail "$selected exit did not trigger restart polling"
  [ "$(<"$SLEEP_LOG")" = '5' ] || fail "$selected restart did not wait five seconds"
}

check_agent codex '--yolo ' loop \
  'rc.verbose=nothing status:pending count' \
  'Process each existing goal and loop separately'
grep -Fq 'Process pending tasks regardless of whether they have the +SMALL tag.' \
  "$AGENT_LOG" || fail "default prompt did not include non-small work"

check_agent claude '--dangerously-skip-permissions ' implement \
  'rc.verbose=nothing +READY -ACTIVE status:pending count' \
  'Do not review, merge, or complete the task.' --implement-task
grep -Fq '/skills dev-implement-task' "$AGENT_LOG" \
  || fail "implementation-only mode selected the wrong skill"

check_agent agy '--dangerously-skip-permissions --prompt-interactive ' complete \
  'rc.verbose=nothing +ACTIVE status:pending +SMALL export' \
  'Do not claim or implement unrelated pending work.' --complete-task --small
grep -Fq '/skills dev-complete-task' "$AGENT_LOG" \
  || fail "completion-only mode selected the wrong skill"
grep -Fq 'Only discover and process pending tasks tagged +SMALL' "$AGENT_LOG" \
  || fail "--small did not constrain the agent prompt"
grep -Fq 'review-ready pending +SMALL tasks' "$AGENT_LOG" \
  || fail "--small completion prompt described the wrong queue"

check_agent codex '--yolo ' loop \
  'rc.verbose=nothing status:pending -SMALL count' \
  'Process each existing goal and loop separately' --no-small
grep -Fq 'Only discover and process pending tasks that are not tagged +SMALL' "$AGENT_LOG" \
  || fail "--no-small did not constrain the agent prompt"
grep -Fq 'Drain the existing pending tasks without +SMALL' "$AGENT_LOG" \
  || fail "--no-small prompt described the wrong queue"

clear_case
printf '0\n' >"$TASK_COUNTS"
set +e
"$LOOP" --agent codex --implement-task >"$TMP/implement-idle.out" 2>"$TMP/implement-idle.err"
implement_idle_rc=$?
set -e
[ "$implement_idle_rc" -eq 143 ] || fail "implementation idle fixture exited $implement_idle_rc"
grep -Fq 'No claimable all pending tasks.' "$TMP/implement-idle.out" \
  || fail "implementation-only mode did not idle without claimable work"
[ ! -s "$AGENT_LOG" ] || fail "implementation-only mode launched without claimable work"

clear_case
printf '[]\n' >"$TASK_EXPORT"
set +e
"$LOOP" --agent claude --complete-task >"$TMP/complete-idle.out" 2>"$TMP/complete-idle.err"
complete_idle_rc=$?
set -e
[ "$complete_idle_rc" -eq 143 ] || fail "completion idle fixture exited $complete_idle_rc"
grep -Fq 'No review-ready all pending tasks.' "$TMP/complete-idle.out" \
  || fail "completion-only mode did not idle without review-ready work"
[ ! -s "$AGENT_LOG" ] || fail "completion-only mode launched without review-ready work"

[ ! -s "$RESET_LOG" ] \
  || fail "non-interactive runs unexpectedly reset the terminal"

printf 'PASS: loop\n'
