#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DONE="$ROOT/scripts/dlc-done.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dlc-done-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/config"
printf 'pending\n' >"$TMP/status"
: >"$TMP/task.log"

cat >"$TMP/bin/task" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

while [ "$#" -gt 0 ] && [[ "$1" == rc.* ]]; do shift; done
uuid="${1:-}"
cmd="${2:-}"

case "$cmd" in
  export)
    status="$(cat "$MOCK_STATUS")"
    # The successor is a task in its own right: stacked/superseded look it up to
    # confirm the preserved branch has somewhere to land.
    if [ -n "${MOCK_SUCCESSOR:-}" ] && [ "$uuid" = "$MOCK_SUCCESSOR" ]; then
      jq -n --arg uuid "$uuid" --arg status "${MOCK_SUCCESSOR_STATUS:-pending}" \
        '[{uuid: $uuid, status: $status, description: "successor fixture",
           annotations: []}]'
      exit 0
    fi
    jq -n --arg uuid "$uuid" --arg status "$status" \
      --arg succ "${MOCK_SUCCESSOR:-}" \
      --arg owner "${MOCK_ASSIGNEE_OWNER:-$DEV_LOOP_OWNER}" '
      [{uuid: $uuid, status: $status, assignee: ($owner + "#test"),
        description: "fixture task",
        annotations: ([{description: "branch=review/fixture"},
                      {description: "reviewer=fixture-owner#fixture-agent"},
                      {description: ("commits=base.." + env.MOCK_HEAD + " (n=1)")}]
                      + (if $succ == "" then []
                         else [{description: ("successor=" + $succ)}] end))}]'
    ;;
  annotate)
    printf 'annotate\t%s\n' "${3:-}" >>"$MOCK_TASK_LOG"
    ;;
  modify)
    printf 'modify\t%s\n' "${3:-}" >>"$MOCK_TASK_LOG"
    ;;
  done)
    printf 'completed\n' >"$MOCK_STATUS"
    printf 'done\n' >>"$MOCK_TASK_LOG"
    ;;
  *)
    printf 'unexpected mock task invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF

cat >"$TMP/bin/crabbox" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/task" "$TMP/bin/crabbox"

export PATH="$TMP/bin:$PATH"
export MOCK_STATUS="$TMP/status"
export MOCK_TASK_LOG="$TMP/task.log"
export DEV_LOOP_OWNER="fixture-owner"
export AGENT_PID="fixture-agent"
export DEV_LOOP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/config"

mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.name fixture
git -C "$TMP/repo" config user.email fixture@example.test
printf 'fixture\n' >"$TMP/repo/fixture.txt"
git -C "$TMP/repo" add fixture.txt
git -C "$TMP/repo" commit -qm fixture
MOCK_HEAD="$(git -C "$TMP/repo" rev-parse HEAD)"
export MOCK_HEAD
cd "$TMP/repo"

uuid="12345678-1234-1234-1234-123456789abc"

set +e
"$DONE" "$uuid" >"$TMP/missing.out" 2>"$TMP/missing.err"
rc=$?
set -e
[ "$rc" -eq 20 ] || fail "missing outcome returned $rc, expected 20"
[ ! -s "$TMP/task.log" ] || fail "missing outcome mutated the task"

set +e
"$DONE" "$uuid" --outcome invalid >"$TMP/invalid.out" 2>"$TMP/invalid.err"
rc=$?
set -e
[ "$rc" -eq 20 ] || fail "invalid outcome returned $rc, expected 20"
[ ! -s "$TMP/task.log" ] || fail "invalid outcome mutated the task"

set +e
AGENT_PID=foreign-agent "$DONE" "$uuid" --outcome merged \
  >"$TMP/foreign.out" 2>"$TMP/foreign.err"
rc=$?
set -e
[ "$rc" -eq 10 ] || fail "foreign reviewer finalization returned $rc, expected 10"
[ ! -s "$TMP/task.log" ] || fail "foreign reviewer mutated the task"

"$DONE" "$uuid" --outcome merged >"$TMP/merged.out" 2>"$TMP/merged.err"
[ "$(cat "$TMP/status")" = completed ] || fail "task was not completed"
grep -Fq 'completed outcome=merged' "$TMP/task.log" \
  || fail "merged outcome annotation was not recorded"
grep -Fxq 'done' "$TMP/task.log" || fail "task done was not invoked"
grep -Fxq $'annotate\treviewer=' "$TMP/task.log" \
  || fail "merged outcome did not release the reviewer lock"
grep -Fxq $'modify\tplan:' "$TMP/task.log" \
  || fail "merged outcome did not clear the plan UDA"

# stacked and superseded keep the review branch alive, so both hand the
# obligation to merge it to a still-pending successor. Without one the producer
# closes and nothing in the queue can ever reach the branch again.
successor="87654321-4321-4321-4321-cba987654321"

printf 'pending\n' >"$TMP/status"
: >"$TMP/task.log"
git branch review/fixture HEAD
set +e
"$DONE" "$uuid" --outcome stacked >"$TMP/no-succ.out" 2>"$TMP/no-succ.err"
rc=$?
set -e
[ "$rc" -eq 20 ] || fail "stacked without a successor returned $rc, expected 20"
[ ! -s "$TMP/task.log" ] || fail "stacked without a successor mutated the task"
grep -Fq 'no successor= annotation' "$TMP/no-succ.err" \
  || fail "the missing successor was not diagnosed"
git show-ref --verify --quiet refs/heads/review/fixture \
  || fail "a refused stacked outcome removed the preserved branch"

# A successor that has already closed is no better than none: dlc-claim.sh only
# claims pending tasks, so the branch would still be stranded.
printf 'pending\n' >"$TMP/status"
: >"$TMP/task.log"
set +e
MOCK_SUCCESSOR="$successor" MOCK_SUCCESSOR_STATUS="completed" \
  "$DONE" "$uuid" --outcome superseded >"$TMP/dead-succ.out" 2>"$TMP/dead-succ.err"
rc=$?
set -e
[ "$rc" -eq 20 ] || fail "superseded with a closed successor returned $rc, expected 20"
[ ! -s "$TMP/task.log" ] || fail "a closed successor still mutated the task"
grep -Fq 'none are still pending' "$TMP/dead-succ.err" \
  || fail "the closed successor was not diagnosed"

# --force is the deliberate escape hatch, and it must say what it is stranding.
printf 'pending\n' >"$TMP/status"
: >"$TMP/task.log"
"$DONE" "$uuid" --outcome stacked --force \
  >"$TMP/forced.out" 2>"$TMP/forced.err" \
  || fail "--force did not bypass the successor guard"
grep -Fq 'will be orphaned' "$TMP/forced.err" \
  || fail "--force did not warn that the branch is stranded"

export MOCK_SUCCESSOR="$successor"

printf 'pending\n' >"$TMP/status"
: >"$TMP/task.log"
"$DONE" "$uuid" --outcome stacked >"$TMP/stacked.out" 2>"$TMP/stacked.err"
grep -Fq 'handed to pending successor' "$TMP/stacked.err" \
  || fail "the successor handoff was not reported"
grep -Fq 'completed outcome=stacked' "$TMP/task.log" \
  || fail "stacked outcome annotation was not recorded"
git show-ref --verify --quiet refs/heads/review/fixture \
  || fail "stacked outcome removed the preserved branch"
grep -Fq $'modify\tplan:' "$TMP/task.log" \
  && fail "stacked outcome should not clear the plan UDA"

printf 'pending\n' >"$TMP/status"
: >"$TMP/task.log"
git branch -D review/fixture >/dev/null
set +e
"$DONE" "$uuid" --outcome superseded >"$TMP/missing-branch.out" 2>"$TMP/missing-branch.err"
rc=$?
set -e
[ "$rc" -eq 20 ] || fail "missing preserved branch returned $rc, expected 20"
[ ! -s "$TMP/task.log" ] || fail "missing preserved branch mutated the task"

# A task implemented by a different worker is completed, not refused: review-ready
# work is claimable by any worker. The implementer is recorded as a handoff.
printf 'pending\n' >"$TMP/status"
: >"$TMP/task.log"
git branch review/fixture HEAD
MOCK_ASSIGNEE_OWNER="other-worker" "$DONE" "$uuid" --outcome stacked \
  >"$TMP/handoff.out" 2>"$TMP/handoff.err" \
  || fail "completion of another worker's task was refused"
grep -Fq 'completion handoff from other-worker' "$TMP/task.log" \
  || fail "handoff annotation was not recorded"
grep -Fq 'completed outcome=stacked' "$TMP/task.log" \
  || fail "handoff completion did not record its outcome"
git branch -D review/fixture >/dev/null

printf 'ok: dlc-done outcome and finalization tests\n'
