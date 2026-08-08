#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOOP="$ROOT/loop"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/loop-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/bin"

# Every count is an `export` piped through jq, so the fixture is the task JSON
# and the log records which filter asked for it.
cat >"$TMP/bin/task" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TASK_LOG"
cat "$TASK_EXPORT"
EOF

# Ends the fixture by killing the loop once it has slept SLEEP_MAX times, so a
# case can observe several iterations before the process goes away.
cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SLEEP_LOG"
if [ "$(wc -l <"$SLEEP_LOG")" -ge "${SLEEP_MAX:-1}" ]; then
  kill -TERM "$PPID"
fi
EOF

cat >"$TMP/bin/reset" <<'EOF'
#!/usr/bin/env bash
printf 'reset\n' >>"$RESET_LOG"
EOF

# AGENT_FINISH makes the fake agent call the one thing a real run must end with.
# Leaving it unset is the abandoned-run case: the process exits having written
# no marker, exactly like an agent that ended its turn waiting on a box gate.
for name in codex claude agy; do
  cat >"$TMP/bin/$name" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\t%s\n' "$(basename "$0")" "${AGENT_PID:-}" \
  "${DEV_LOOP_ROUTE:-}" "$*" >>"$AGENT_LOG"
if [ -n "${AGENT_FINISH:-}" ] && [ -n "${DEV_LOOP_FINISH_MARKER:-}" ]; then
  printf 'task-completed fixture\n' >"$DEV_LOOP_FINISH_MARKER"
fi
exit "${AGENT_EXIT:-0}"
EOF
done
chmod +x "$TMP/bin/"*

export PATH="$TMP/bin:$PATH"
export TASK_LOG="$TMP/task.log"
export TASK_EXPORT="$TMP/task-export.json"
export SLEEP_LOG="$TMP/sleep.log"
export RESET_LOG="$TMP/reset.log"
export AGENT_LOG="$TMP/agent.log"
export AGENT_FINISH=1

# One review-ready producer: a recorded branch, a summary, no reviewer lock.
READY_TASK='[{"annotations":[{"description":"branch=review/test"},{"description":"summary: ready"}]}]'

clear_case() {
  : >"$TASK_LOG"
  : >"$SLEEP_LOG"
  : >"$RESET_LOG"
  : >"$AGENT_LOG"
  printf '[]\n' >"$TASK_EXPORT"
  unset SLEEP_MAX AGENT_EXIT
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
expect_2 --agent codex --small --large
grep -Fq -- 'are mutually exclusive' "$TMP/validation.err" \
  || fail "conflicting scope flags were not diagnosed"
expect_2 --agent codex --standard --plan
grep -Fq -- 'are mutually exclusive' "$TMP/validation.err" \
  || fail "--standard and --plan were not diagnosed as conflicting"
expect_2 --agent codex --no-small
grep -Fq -- 'unknown argument: --no-small' "$TMP/validation.err" \
  || fail "the removed --no-small flag was silently accepted"

clear_case
set +e
"$LOOP" --agent codex >"$TMP/idle.out" 2>"$TMP/idle.err"
idle_rc=$?
set -e
[ "$idle_rc" -eq 143 ] || fail "idle polling fixture exited $idle_rc"
grep -Fq 'rc.verbose=nothing +READY -ACTIVE status:pending -SMALL -LARGE -PLAN export' "$TASK_LOG" \
  || fail "default poll did not count the standard queue's claimable work"
grep -Fq 'rc.verbose=nothing +ACTIVE status:pending -SMALL -LARGE -PLAN export' "$TASK_LOG" \
  || fail "default poll did not count the standard queue's review-ready work"
grep -Fq 'No pending standard-queue tasks. Checking again in 30 seconds...' "$TMP/idle.out" \
  || fail "idle poll was not reported"
[ ! -s "$AGENT_LOG" ] || fail "an agent launched with no pending task"
[ "$(<"$SLEEP_LOG")" = '30' ] || fail "idle poll did not wait thirty seconds"

check_agent() {
  selected="$1"
  expected_flags="$2"
  mode="$3"
  expected_query="$4"
  expected_stage_prompt="$5"
  shift 5
  clear_case
  printf '%s\n' "$READY_TASK" >"$TASK_EXPORT"

  set +e
  "$LOOP" --agent "$selected" "$@" >"$TMP/$mode-$selected.out" 2>"$TMP/$mode-$selected.err"
  agent_rc=$?
  set -e

  [ "$agent_rc" -eq 143 ] || fail "$selected restart fixture exited $agent_rc"
  IFS=$'\t' read -r invoked pid launched_route arguments <"$AGENT_LOG"
  [ "$invoked" = "$selected" ] || fail "$selected was not launched"
  [[ "$pid" =~ ^[0-9]+$ ]] || fail "$selected did not receive AGENT_PID"
  [ -n "$launched_route" ] || fail "$selected did not inherit DEV_LOOP_ROUTE"
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
  grep -Fq "$expected_query" "$TASK_LOG" \
    || fail "$selected $mode used the wrong discovery query: $(<"$TASK_LOG")"
  grep -Fq 'Restarting in 30 seconds...' "$TMP/$mode-$selected.out" \
    || fail "$selected exit did not trigger restart polling"
  [ "$(<"$SLEEP_LOG")" = '30' ] || fail "$selected restart did not wait thirty seconds"
}

check_agent codex '--yolo ' loop \
  'rc.verbose=nothing +READY -ACTIVE status:pending -SMALL -LARGE -PLAN export' \
  'Process each existing goal and loop separately'
grep -Fq 'Only discover and process pending tasks tagged none of +SMALL, +LARGE, or +PLAN' \
  "$AGENT_LOG" || fail "default prompt did not constrain the agent to the standard queue"
grep -Fq 'Drain the existing pending standard-queue tasks' "$AGENT_LOG" \
  || fail "default prompt described the wrong queue"

# --standard is the explicit spelling of the default, so both must agree.
check_agent codex '--yolo ' standard \
  'rc.verbose=nothing +READY -ACTIVE status:pending -SMALL -LARGE -PLAN export' \
  'Drain the existing pending standard-queue tasks' --standard

check_agent claude '--dangerously-skip-permissions ' implement \
  'rc.verbose=nothing +READY -ACTIVE status:pending -SMALL -LARGE -PLAN export' \
  'Do not review, merge, or complete the task.' --implement-task
grep -Fq 'dev-implement-task skill' "$AGENT_LOG" \
  || fail "implementation-only mode selected the wrong skill"

check_agent agy '--dangerously-skip-permissions --prompt-interactive ' complete \
  'rc.verbose=nothing +ACTIVE status:pending +SMALL -LARGE -PLAN export' \
  'Do not claim or implement unrelated pending work.' --complete-task --small
grep -Fq 'dev-complete-task skill' "$AGENT_LOG" \
  || fail "completion-only mode selected the wrong skill"
grep -Fq 'Only discover and process pending tasks tagged +SMALL and not escalated to +LARGE' \
  "$AGENT_LOG" || fail "--small did not constrain the agent prompt"
grep -Fq 'review-ready pending +SMALL tasks' "$AGENT_LOG" \
  || fail "--small completion prompt described the wrong queue"

# The escalated queue: counted exactly as dl-claim.sh --large claims it, and
# never counted by any other queue.
check_agent codex '--yolo ' large \
  'rc.verbose=nothing +READY -ACTIVE status:pending +LARGE -PLAN export' \
  'Drain the existing pending +LARGE escalated tasks' --large
grep -Fq 'Only discover and process pending tasks tagged +LARGE' "$AGENT_LOG" \
  || fail "--large did not constrain the agent prompt"
grep -Fq 'resume its recorded worktree= and branch= annotations' "$AGENT_LOG" \
  || fail "--large prompt omitted the escalation resume contract"
grep -Fq 'remove the +LARGE tag, release the claim, and sync' "$AGENT_LOG" \
  || fail "--large prompt omitted the escalation return path"

check_agent codex '--yolo ' plan \
  'rc.verbose=nothing +READY -ACTIVE status:pending +PLAN export' \
  'Do not implement, review, or merge any work the plan describes.' --plan

# Every queue binds the claim through the environment the agent inherits, not
# just through the prompt prose it may ignore.
route_of() {
  clear_case
  printf '%s\n' "$READY_TASK" >"$TASK_EXPORT"
  set +e
  "$LOOP" --agent codex "$@" >/dev/null 2>&1
  set -e
  IFS=$'\t' read -r _ _ launched_route _ <"$AGENT_LOG"
  printf '%s' "$launched_route"
}

for expected in standard small large plan; do
  case "$expected" in
    standard) actual="$(route_of)" ;;
    *)        actual="$(route_of "--$expected")" ;;
  esac
  [ "$actual" = "$expected" ] \
    || fail "queue $expected exported DEV_LOOP_ROUTE '$actual'"
done

clear_case
set +e
"$LOOP" --agent codex --implement-task >"$TMP/implement-idle.out" 2>"$TMP/implement-idle.err"
implement_idle_rc=$?
set -e
[ "$implement_idle_rc" -eq 143 ] || fail "implementation idle fixture exited $implement_idle_rc"
grep -Fq 'No claimable pending standard-queue tasks.' "$TMP/implement-idle.out" \
  || fail "implementation-only mode did not idle without claimable work"
[ ! -s "$AGENT_LOG" ] || fail "implementation-only mode launched without claimable work"

clear_case
set +e
"$LOOP" --agent claude --complete-task >"$TMP/complete-idle.out" 2>"$TMP/complete-idle.err"
complete_idle_rc=$?
set -e
[ "$complete_idle_rc" -eq 143 ] || fail "completion idle fixture exited $complete_idle_rc"
grep -Fq 'No review-ready pending standard-queue tasks.' "$TMP/complete-idle.out" \
  || fail "completion-only mode did not idle without review-ready work"
[ ! -s "$AGENT_LOG" ] || fail "completion-only mode launched without review-ready work"

# A producer whose reviewer lock is held is not review-ready for anyone: with no
# default steal window, dlc-claim.sh exits 10 for every worker this loop would
# launch. Counting it kept the queue permanently non-empty and relaunched a
# fresh worker, and a fresh box, every thirty seconds.
clear_case
printf '%s\n' '[{"annotations":[
  {"description":"branch=review/test"},
  {"description":"summary: ready"},
  {"description":"reviewer=someone@host/worker-1#4242"}
]}]' >"$TASK_EXPORT"
set +e
"$LOOP" --agent claude --complete-task >"$TMP/held.out" 2>"$TMP/held.err"
held_rc=$?
set -e
[ "$held_rc" -eq 143 ] || fail "held-review fixture exited $held_rc"
[ ! -s "$AGENT_LOG" ] || fail "a worker launched against a task another reviewer holds"
grep -Fq 'No review-ready pending standard-queue tasks.' "$TMP/held.out" \
  || fail "a held reviewer claim was still counted as review-ready"

# dlc-release.sh releases by appending an empty reviewer=, and annotations
# accumulate. The last one is the lock, so a released task is claimable again.
clear_case
printf '%s\n' '[{"annotations":[
  {"description":"branch=review/test"},
  {"description":"summary: ready"},
  {"description":"reviewer=someone@host/worker-1#4242"},
  {"description":"reviewer="}
]}]' >"$TASK_EXPORT"
set +e
"$LOOP" --agent claude --complete-task >"$TMP/released.out" 2>"$TMP/released.err"
released_rc=$?
set -e
[ "$released_rc" -eq 143 ] || fail "released-review fixture exited $released_rc"
[ -s "$AGENT_LOG" ] || fail "a released reviewer claim was treated as still held"

# An agent that exits without dl-finish.sh abandoned its run: its claim,
# worktree, and box are still live. The loop must back off rather than launch a
# replacement into the same queue at the usual interval.
clear_case
unset AGENT_FINISH
export SLEEP_MAX=10
printf '%s\n' "$READY_TASK" >"$TASK_EXPORT"
set +e
"$LOOP" --agent claude --complete-task >"$TMP/abandoned.out" 2>"$TMP/abandoned.err"
abandoned_rc=$?
set -e
export AGENT_FINISH=1
unset SLEEP_MAX

[ "$abandoned_rc" -eq 1 ] \
  || fail "repeated abandoned runs exited $abandoned_rc instead of 1"
[ "$(grep -c . "$AGENT_LOG")" -eq 3 ] \
  || fail "abandoned runs launched $(grep -c . "$AGENT_LOG") agents instead of stopping at 3"
[ "$(tr '\n' ' ' <"$SLEEP_LOG")" = '60 120 ' ] \
  || fail "abandoned runs did not back off: $(tr '\n' ' ' <"$SLEEP_LOG")"
grep -Fq 'ended without dl-finish.sh' "$TMP/abandoned.err" \
  || fail "an abandoned run was not diagnosed"
grep -Fq 'still held' "$TMP/abandoned.err" \
  || fail "the abandoned run's orphaned resources were not reported"
grep -Fq 'stopping rather than leasing more' "$TMP/abandoned.err" \
  || fail "the loop did not report why it stopped"

# A run that does reach dl-finish.sh resets the backoff, so one abandoned run in
# a long drain does not shorten the worker's life.
clear_case
printf '%s\n' "$READY_TASK" >"$TASK_EXPORT"
set +e
"$LOOP" --agent claude --complete-task >"$TMP/finished.out" 2>"$TMP/finished.err"
finished_rc=$?
set -e
[ "$finished_rc" -eq 143 ] || fail "finished-run fixture exited $finished_rc"
grep -Fq 'loop: run finished (task-completed fixture)' "$TMP/finished.out" \
  || fail "a completed run was not recognised as finished"
[ "$(<"$SLEEP_LOG")" = '30' ] || fail "a finished run did not use the normal interval"

[ ! -s "$RESET_LOG" ] \
  || fail "non-interactive runs unexpectedly reset the terminal"

printf 'PASS: loop\n'
