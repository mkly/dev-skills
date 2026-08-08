#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAIM="$ROOT/scripts/dlc-claim.sh"
RELEASE="$ROOT/scripts/dlc-release.sh"
DIFF="$ROOT/scripts/dlc-diff.sh"
CREATE="$ROOT/../dev-create-tasks/scripts/dct-create.sh"
STATUS="$ROOT/../dev-implement-task/scripts/dl-status.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dlc-review-claim-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

export TASKRC="$TMP/taskrc"
export TASKDATA="$TMP/taskdata"
export DLC_STATE_DIR="$TMP/review-state"
export DEV_LOOP_STATE_DIR="$TMP/implementation-state"
mkdir -p "$TASKDATA" "$TMP/bin"
printf '%s\n' \
  'uda.assignee.type=string' \
  'uda.assignee.label=Assignee' \
  >"$TASKRC"

cat >"$TMP/bin/crabbox" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) printf '[]\n' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/crabbox"
export PATH="$TMP/bin:$PATH"

mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.name fixture
git -C "$TMP/repo" config user.email fixture@example.test
git -C "$TMP/repo" remote add origin https://github.com/acme/review-lock.git
printf 'base\n' >"$TMP/repo/file.txt"
git -C "$TMP/repo" add file.txt
git -C "$TMP/repo" commit -qm base
base="$(git -C "$TMP/repo" rev-parse HEAD)"
git -C "$TMP/repo" switch -qc review/fixture
printf 'review\n' >>"$TMP/repo/file.txt"
git -C "$TMP/repo" commit -qam review
git -C "$TMP/repo" switch -q master 2>/dev/null \
  || git -C "$TMP/repo" switch -q main

cd "$TMP/repo"
uuid="$(
  "$CREATE" --goal reviewer-lock \
    --loop-id 11111111-1111-4111-8111-111111111111 \
    --description 'reviewer lock fixture task' \
    --acceptance 'only one reviewer may inspect and dispose the branch' \
    2>"$TMP/create.err"
)"
task rc.confirmation=no rc.verbose=nothing "$uuid" annotate "base=$base" >/dev/null
task rc.confirmation=no rc.verbose=nothing "$uuid" annotate 'branch=review/fixture' >/dev/null
task rc.confirmation=no rc.verbose=nothing "$uuid" annotate 'summary: implementation is ready for review' >/dev/null
task rc.confirmation=no rc.verbose=nothing "$uuid" modify assignee:producer#9000 >/dev/null
task rc.confirmation=no rc.verbose=nothing "$uuid" start >/dev/null

for spec in reviewer-a:1001 reviewer-b:1002; do
  owner="${spec%%:*}"; nonce="${spec#*:}"
  (
    set +e
    DEV_LOOP_OWNER="$owner" AGENT_PID="$nonce" "$CLAIM" "$uuid" \
      >"$TMP/$owner.out" 2>"$TMP/$owner.err"
    printf '%s\n' "$?" >"$TMP/$owner.rc"
  ) &
done
wait

results="$(sort "$TMP"/reviewer-*.rc)"
[ "$results" = $'0\n10' ] \
  || fail "expected one reviewer claim and one lost race; got ${results//$'\n'/,}"
winner_value="$(task rc.json.array=on rc.verbose=nothing "$uuid" export | jq -r '
  (.[0].annotations // []) | map(.description)
  | map(select(startswith("reviewer="))) | last | sub("^reviewer="; "")
')"
winner_owner="${winner_value%%#*}"
winner_nonce="${winner_value#*#}"
if [ "$winner_owner" = reviewer-a ]; then
  loser_owner=reviewer-b; loser_nonce=1002
else
  loser_owner=reviewer-a; loser_nonce=1001
fi

DEV_LOOP_OWNER="$winner_owner" AGENT_PID="$winner_nonce" \
  "$DIFF" review/fixture --stat-only >"$TMP/diff.out" 2>"$TMP/diff.err" \
  || fail "winning reviewer could not inspect the branch"
set +e
DEV_LOOP_OWNER="$loser_owner" AGENT_PID="$loser_nonce" \
  "$DIFF" review/fixture --stat-only >"$TMP/foreign-diff.out" 2>"$TMP/foreign-diff.err"
foreign_rc=$?
set -e
[ "$foreign_rc" -eq 10 ] || fail "foreign reviewer diff exited $foreign_rc, expected 10"

DEV_LOOP_OWNER="$winner_owner" AGENT_PID="$winner_nonce" "$RELEASE" "$uuid" \
  >"$TMP/release.out" 2>"$TMP/release.err" \
  || fail "winning reviewer could not release its lock"
[ -z "$(task rc.json.array=on rc.verbose=nothing "$uuid" export | jq -r '
  (.[0].annotations // []) | map(.description)
  | map(select(startswith("reviewer="))) | last | sub("^reviewer="; "")
')" ] || fail "reviewer annotation was not cleared"

DEV_LOOP_OWNER="$loser_owner" AGENT_PID="$loser_nonce" "$CLAIM" "$uuid" \
  >"$TMP/reclaim.out" 2>"$TMP/reclaim.err" \
  || fail "released review could not be claimed by the other reviewer"
task rc.confirmation=no rc.verbose=nothing "$uuid" annotate 'review-start=20200101T000000Z' >/dev/null
DEV_LOOP_OWNER=reviewer-c AGENT_PID=1003 "$CLAIM" "$uuid" --steal-after 1h \
  >"$TMP/steal.out" 2>"$TMP/steal.err" \
  || fail "stale reviewer claim could not be taken over"

# Routing holds at the review stage too: the queue that implemented a task is
# the queue that reviews it, so a wrong-sized worker is refused rather than
# quietly disposing of work meant for another model.
DEV_LOOP_OWNER=reviewer-c AGENT_PID=1003 "$RELEASE" "$uuid" >/dev/null 2>&1 \
  || fail "reviewer-c could not release before the routing checks"
task rc.confirmation=no rc.verbose=nothing "$uuid" modify +LARGE >/dev/null

set +e
DEV_LOOP_OWNER=reviewer-d AGENT_PID=1004 "$CLAIM" "$uuid" \
  >"$TMP/standard-route.out" 2>"$TMP/standard-route.err"
standard_route_rc=$?
set -e
[ "$standard_route_rc" -eq 20 ] \
  || fail "standard reviewer claimed a +LARGE task (exit $standard_route_rc)"
grep -Fq 'is not on the standard queue' "$TMP/standard-route.err" \
  || fail "wrong-queue review was not diagnosed"
[ ! -s "$TMP/standard-route.out" ] || fail "refused review still printed a UUID"

set +e
DEV_LOOP_ROUTE=nonsense DEV_LOOP_OWNER=reviewer-d AGENT_PID=1004 \
  "$CLAIM" "$uuid" >/dev/null 2>"$TMP/bad-route.err"
bad_route_rc=$?
set -e
[ "$bad_route_rc" -eq 20 ] || fail "invalid DEV_LOOP_ROUTE exited $bad_route_rc"
grep -Fq 'DEV_LOOP_ROUTE must be standard, small, large, or plan' "$TMP/bad-route.err" \
  || fail "invalid DEV_LOOP_ROUTE was not diagnosed"

set +e
DEV_LOOP_ROUTE=large DEV_LOOP_OWNER=reviewer-d AGENT_PID=1004 \
  "$CLAIM" "$uuid" --standard >/dev/null 2>"$TMP/override.err"
override_rc=$?
set -e
[ "$override_rc" -eq 20 ] \
  || fail "an explicit --standard did not override DEV_LOOP_ROUTE (exit $override_rc)"

DEV_LOOP_ROUTE=large DEV_LOOP_OWNER=reviewer-d AGENT_PID=1004 "$CLAIM" "$uuid" \
  >"$TMP/large-route.out" 2>"$TMP/large-route.err" \
  || fail "the large reviewer could not claim its own escalated task"
task rc.confirmation=no rc.verbose=nothing "$uuid" modify -LARGE >/dev/null
DEV_LOOP_OWNER=reviewer-d AGENT_PID=1004 "$RELEASE" "$uuid" >/dev/null 2>&1 \
  || fail "reviewer-d could not release the routed claim"
DEV_LOOP_OWNER=reviewer-c AGENT_PID=1003 "$CLAIM" "$uuid" >/dev/null 2>&1 \
  || fail "the returned task could not be reclaimed by its original queue"

DEV_LOOP_OWNER=reviewer-c AGENT_PID=1003 "$STATUS" \
  >"$TMP/status.out" 2>"$TMP/status.err"
grep -Fq 'Active reviews:' "$TMP/status.out" \
  || fail "status did not report its reviewer section"
grep -Fq 'reviewer-c#1003' "$TMP/status.out" \
  || fail "status did not report the active reviewer claim"

printf 'ok: separate reviewer claim, release, ownership, and stale takeover tests\n'
