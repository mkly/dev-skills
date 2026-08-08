#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAIM="$ROOT/scripts/dl-claim.sh"
CREATE="$ROOT/../dev-create-tasks/scripts/dct-create.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-claim-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

export TASKRC="$TMP/taskrc"
export TASKDATA="$TMP/taskdata"
export DEV_LOOP_STATE_DIR="$TMP/state"
export DEV_LOOP_TITLE=auto
export DEV_LOOP_WINDOW_ID=4242
mkdir -p "$TASKDATA"
mkdir -p "$TMP/bin"
export TITLE_LOG="$TMP/title.log"
cat >"$TMP/bin/xdotool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TITLE_LOG"
EOF
chmod +x "$TMP/bin/xdotool"
export PATH="$TMP/bin:$PATH"
printf '%s\n' \
  'uda.assignee.type=string' \
  'uda.assignee.label=Assignee' \
  >"$TASKRC"

uuid="$(
  "$CREATE" --goal claim-test \
    --loop-id 11111111-1111-4111-8111-111111111111 \
    --description 'claim exactly once with extra ignored words' \
    --acceptance 'one concurrent owner wins' 2>"$TMP/create.err"
)"

for owner in owner-a owner-b; do
  (
    set +e
    DEV_LOOP_OWNER="$owner" "$CLAIM" "$uuid" \
      >"$TMP/$owner.out" 2>"$TMP/$owner.err"
    printf '%s\n' "$?" >"$TMP/$owner.rc"
  ) &
done
wait

results="$(sort "$TMP"/*.rc)"
[ "$results" = $'0\n10' ] \
  || fail "expected one successful claim and one lost race; got: ${results//$'\n'/,}"

winner="$(cat "$TMP/owner-a.out" "$TMP/owner-b.out")"
[ "$winner" = "$uuid" ] || fail "winner did not print the exact task UUID"
expected_title="set_window --name [${uuid:0:8}] claim exactly once with extra 4242"
[ "$(cat "$TITLE_LOG")" = "$expected_title" ] \
  || fail "claim title was not the short UUID plus five description words"

task rc.context=none rc.json.array=on rc.verbose=nothing "$uuid" export \
  | jq -e '
      length == 1
      and (.[0].assignee | test("^owner-[ab]#"))
      and (.[0].start | type == "string")
  ' >/dev/null \
  || fail "winning owner or active state was not persisted"

blocked="$(
  "$CREATE" --from-task "$uuid" --description 'blocked successor' \
    --acceptance 'producer must finish first' --depends "$uuid" \
    2>"$TMP/blocked-create.err"
)"
set +e
DEV_LOOP_OWNER=owner-c "$CLAIM" "$blocked" \
  >"$TMP/blocked.out" 2>"$TMP/blocked.err"
blocked_rc=$?
DEV_LOOP_OWNER=owner-c "$CLAIM" "$uuid" \
  --loop-id 99999999-9999-4999-8999-999999999999 \
  >"$TMP/wrong-loop.out" 2>"$TMP/wrong-loop.err"
wrong_loop_rc=$?
set -e
[ "$blocked_rc" -eq 20 ] || fail "blocked task claim exited $blocked_rc"
[ "$wrong_loop_rc" -eq 20 ] || fail "wrong-loop claim exited $wrong_loop_rc"
[ ! -s "$TMP/blocked.out" ] || fail "blocked task claim wrote stdout"
[ ! -s "$TMP/wrong-loop.out" ] || fail "wrong-loop claim wrote stdout"

mkdir -p "$TMP/foreign"
git -C "$TMP/foreign" init -q
git -C "$TMP/foreign" remote add origin https://github.com/acme/foreign.git
foreign="$(
  cd "$TMP/foreign"
  "$CREATE" --goal foreign \
    --loop-id 33333333-3333-4333-8333-333333333333 \
    --description 'foreign repository task' --acceptance 'stay isolated' \
    2>"$TMP/foreign-create.err"
)"
set +e
DEV_LOOP_OWNER=owner-c "$CLAIM" "$foreign" \
  >"$TMP/foreign.out" 2>"$TMP/foreign.err"
foreign_rc=$?
set -e
[ "$foreign_rc" -eq 20 ] || fail "foreign task claim exited $foreign_rc"
[ ! -s "$TMP/foreign.out" ] || fail "foreign task claim wrote stdout"

local_ready="$(
  "$CREATE" --goal claim-test \
    --loop-id 11111111-1111-4111-8111-111111111111 \
    --description 'auto-pick local task' --acceptance 'local identity wins' \
    2>"$TMP/local-ready-create.err"
)"
picked="$(DEV_LOOP_OWNER=owner-c "$CLAIM" --goal claim-test \
  --loop-id 11111111-1111-4111-8111-111111111111 --loop-round 1 \
  2>"$TMP/picked.err")"
[ "$picked" = "$local_ready" ] || fail "scoped auto-pick selected '$picked'"
task rc.confirmation=no rc.verbose=nothing "$picked" modify depends:"$uuid" >/dev/null
set +e
DEV_LOOP_OWNER=owner-c "$CLAIM" "$picked" \
  >"$TMP/owned-blocked.out" 2>"$TMP/owned-blocked.err"
owned_blocked_rc=$?
set -e
[ "$owned_blocked_rc" -eq 20 ] || fail "owned blocked re-claim exited $owned_blocked_rc"
[ ! -s "$TMP/owned-blocked.out" ] || fail "owned blocked re-claim wrote stdout"

empty_acceptance="$(
  "$CREATE" --goal claim-test \
    --loop-id 11111111-1111-4111-8111-111111111111 \
    --description 'malformed acceptance task' \
    --acceptance 'temporary acceptance to remove' \
    2>"$TMP/empty-create.err"
)"
task rc.confirmation=no rc.verbose=nothing "$empty_acceptance" \
  denotate 'acceptance: temporary acceptance to remove' >/dev/null
task rc.confirmation=no rc.verbose=nothing "$empty_acceptance" \
  annotate 'acceptance:' >/dev/null
set +e
DEV_LOOP_OWNER=owner-c "$CLAIM" "$empty_acceptance" \
  >"$TMP/empty.out" 2>"$TMP/empty.err"
empty_rc=$?
set -e
[ "$empty_rc" -eq 20 ] || fail "empty acceptance claim exited $empty_rc"
[ ! -s "$TMP/empty.out" ] || fail "empty acceptance claim wrote stdout"

small_task="$($CREATE --goal small-route \
  --loop-id 55555555-5555-4555-8555-555555555555 \
  --description 'trivial small-model task' \
  --acceptance 'small worker completes it' --small \
  2>"$TMP/small-create.err")"
set +e
DEV_LOOP_OWNER=standard-worker "$CLAIM" "$small_task" \
  >"$TMP/standard-small.out" 2>"$TMP/standard-small.err"
standard_small_rc=$?
DEV_LOOP_OWNER=invalid-worker "$CLAIM" --small --large \
  >"$TMP/mutual.out" 2>"$TMP/mutual.err"
mutual_rc=$?
set -e
[ "$standard_small_rc" -eq 20 ] \
  || fail "standard explicit claim of +SMALL task exited $standard_small_rc"
[ "$mutual_rc" -eq 20 ] || fail "--small --large exited $mutual_rc"

small_pick="$(DEV_LOOP_OWNER=small-worker "$CLAIM" --small \
  --goal small-route --loop-id 55555555-5555-4555-8555-555555555555 \
  --loop-round 1 2>"$TMP/small-route-pick.err")"
[ "$small_pick" = "$small_task" ] || fail "small worker selected '$small_pick'"

# SMALL remains on an escalated task. LARGE takes precedence until the large
# worker removes it, which naturally restores the original small queue.
task rc.confirmation=no rc.verbose=nothing "$small_task" modify +LARGE >/dev/null
task rc.confirmation=no rc.verbose=nothing "$small_task" stop >/dev/null
task rc.confirmation=no rc.verbose=nothing "$small_task" modify assignee: >/dev/null
set +e
DEV_LOOP_OWNER=small-worker "$CLAIM" --small "$small_task" \
  >"$TMP/small-escalated.out" 2>"$TMP/small-escalated.err"
small_escalated_rc=$?
set -e
[ "$small_escalated_rc" -eq 20 ] \
  || fail "small worker claimed SMALL+LARGE task with rc $small_escalated_rc"

large_small_pick="$(DEV_LOOP_OWNER=large-worker "$CLAIM" --large "$small_task" \
  2>"$TMP/large-small-pick.err")"
[ "$large_small_pick" = "$small_task" ] \
  || fail "large worker did not claim SMALL+LARGE task"
task rc.confirmation=no rc.verbose=nothing "$small_task" modify -LARGE >/dev/null
task rc.confirmation=no rc.verbose=nothing "$small_task" stop >/dev/null
task rc.confirmation=no rc.verbose=nothing "$small_task" modify assignee: >/dev/null
returned_small="$(DEV_LOOP_OWNER=small-worker "$CLAIM" --small "$small_task" \
  2>"$TMP/returned-small.err")"
[ "$returned_small" = "$small_task" ] \
  || fail "removing LARGE did not restore the SMALL queue"

# +LARGE is the durable escalation marker: standard workers skip it, large
# workers require it, and removing it returns an untagged task to standard.
escalated="$($CREATE --goal claim-test \
  --loop-id 11111111-1111-4111-8111-111111111111 \
  --description 'escalated implementation' \
  --acceptance 'large worker fixes the issue' \
  2>"$TMP/escalated-create.err")"
task rc.confirmation=no rc.verbose=nothing "$escalated" \
  annotate 'escalation: focused test still fails' >/dev/null
task rc.confirmation=no rc.verbose=nothing "$escalated" \
  annotate 'attempt: updated parser; assertion still fails' >/dev/null
task rc.confirmation=no rc.verbose=nothing "$escalated" modify +LARGE >/dev/null

set +e
DEV_LOOP_OWNER=small-worker "$CLAIM" "$escalated" \
  >"$TMP/small-explicit.out" 2>"$TMP/small-explicit.err"
small_explicit_rc=$?
set -e
[ "$small_explicit_rc" -eq 20 ] \
  || fail "standard explicit claim of +LARGE task exited $small_explicit_rc"
[ ! -s "$TMP/small-explicit.out" ] \
  || fail "standard explicit claim of +LARGE task wrote stdout"

# With only blocked/malformed/+LARGE local tasks and an otherwise-ready foreign
# task, standard auto-pick must return empty.
auto="$(DEV_LOOP_OWNER=owner-c "$CLAIM" 2>"$TMP/auto.err")"
[ -z "$auto" ] || fail "auto-pick selected foreign task $auto"

large_pick="$(DEV_LOOP_OWNER=large-worker "$CLAIM" --large \
  --goal claim-test --loop-id 11111111-1111-4111-8111-111111111111 \
  --loop-round 1 2>"$TMP/large-pick.err")"
[ "$large_pick" = "$escalated" ] || fail "large worker selected '$large_pick'"
task rc.context=none rc.json.array=on rc.verbose=nothing "$escalated" export \
  | jq -e '
      length == 1
      and ((.[0].tags // []) | index("LARGE")) != null
      and (.[0].assignee | startswith("large-worker#"))
    ' >/dev/null || fail "large worker claim did not preserve routing state"

task rc.confirmation=no rc.verbose=nothing "$escalated" \
  annotate 'escalation-result: fixed parser and focused test passes' >/dev/null
task rc.confirmation=no rc.verbose=nothing "$escalated" modify -LARGE >/dev/null
task rc.confirmation=no rc.verbose=nothing "$escalated" stop >/dev/null
task rc.confirmation=no rc.verbose=nothing "$escalated" modify assignee: >/dev/null

small_pick="$(DEV_LOOP_OWNER=small-worker "$CLAIM" \
  --goal claim-test --loop-id 11111111-1111-4111-8111-111111111111 \
  --loop-round 1 2>"$TMP/small-pick.err")"
[ "$small_pick" = "$escalated" ] \
  || fail "ordinary worker did not pick returned task; got '$small_pick'"

# AGENT_PID is a controller-owned Linux PID, not a free-form claim nonce. Reject
# fabricated identifiers before they can claim or start a task.
pid_guard="$(
  "$CREATE" --goal claim-test \
    --loop-id 11111111-1111-4111-8111-111111111111 \
    --description 'reject fabricated agent pid' \
    --acceptance 'invalid pid cannot mutate the task' \
    2>"$TMP/pid-guard-create.err"
)"
set +e
DEV_LOOP_OWNER=pid-worker AGENT_PID=agent-label "$CLAIM" "$pid_guard" \
  >"$TMP/pid-guard.out" 2>"$TMP/pid-guard.err"
pid_guard_rc=$?
set -e
[ "$pid_guard_rc" -eq 20 ] || fail "invalid AGENT_PID exited $pid_guard_rc"
[ ! -s "$TMP/pid-guard.out" ] || fail "invalid AGENT_PID wrote stdout"
grep -Fq 'AGENT_PID must be an inherited numeric Linux PID' \
  "$TMP/pid-guard.err" || fail "invalid AGENT_PID was not diagnosed"
task rc.context=none rc.json.array=on rc.verbose=nothing "$pid_guard" export \
  | jq -e '
      length == 1
      and ((.[0].assignee // "") == "")
      and ((.[0].start // "") == "")
    ' >/dev/null || fail "invalid AGENT_PID mutated the task"

# Two concurrent agents sharing one DEV_LOOP_OWNER must still be told apart by
# their AGENT_PID nonce, or the second walks into the first's live task.
shared="$(
  "$CREATE" --goal claim-test \
    --loop-id 11111111-1111-4111-8111-111111111111 \
    --description 'shared owner task' --acceptance 'nonce separates agents' \
    2>"$TMP/shared-create.err"
)"
DEV_LOOP_OWNER=shared-owner AGENT_PID=4001 "$CLAIM" "$shared" \
  >"$TMP/shared-first.out" 2>"$TMP/shared-first.err" \
  || fail "first agent could not claim shared-owner task"

set +e
DEV_LOOP_OWNER=shared-owner AGENT_PID=4002 "$CLAIM" "$shared" \
  >"$TMP/shared-second.out" 2>"$TMP/shared-second.err"
shared_rc=$?
set -e
[ "$shared_rc" -eq 10 ] \
  || fail "concurrent agent sharing an owner exited $shared_rc, expected 10"
[ ! -s "$TMP/shared-second.out" ] \
  || fail "concurrent agent sharing an owner wrote stdout"
task rc.context=none rc.json.array=on rc.verbose=nothing "$shared" export \
  | jq -e '.[0].assignee == "shared-owner#4001"' >/dev/null \
  || fail "concurrent agent overwrote the original claim"

# A restarted agent (same owner, new pid) still recovers a stale claim via
# --steal-after rather than being permanently locked out.
stolen="$(DEV_LOOP_OWNER=shared-owner AGENT_PID=4002 "$CLAIM" "$shared" \
  --steal-after 0s 2>"$TMP/shared-steal.err")"
[ "$stolen" = "$shared" ] || fail "restarted agent could not steal a stale claim"
task rc.context=none rc.json.array=on rc.verbose=nothing "$shared" export \
  | jq -e '.[0].assignee == "shared-owner#4002"' >/dev/null \
  || fail "steal did not record the new agent nonce"
task rc.confirmation=no rc.verbose=nothing "$shared" \
  modify assignee:shared-owner#4001 >/dev/null

# The original agent re-claiming its own task stays idempotent.
reclaimed="$(DEV_LOOP_OWNER=shared-owner AGENT_PID=4001 "$CLAIM" "$shared" \
  2>"$TMP/shared-reclaim.err")"
[ "$reclaimed" = "$shared" ] || fail "owning agent could not re-claim its task"

printf 'ok: dl-claim concurrency test\n'
