#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/scripts/dl-loop-state.sh"
CREATE="$ROOT/../dev-create-tasks/scripts/dct-create.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-loop-state-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export TASKRC="$TMP/taskrc"
export TASKDATA="$TMP/taskdata"
mkdir -p "$TASKDATA" "$TMP/repo"
printf '%s\n' 'uda.assignee.type=string' 'uda.assignee.label=Assignee' >"$TASKRC"

git -C "$TMP/repo" init -q
git -C "$TMP/repo" remote add origin git@github.com:Acme/Demo.git
git -C "$TMP/repo" config user.name Test
git -C "$TMP/repo" config user.email test@example.invalid
printf 'base\n' >"$TMP/repo/file.txt"
git -C "$TMP/repo" add file.txt
git -C "$TMP/repo" commit -qm base
cd "$TMP/repo"

fresh="$($STATE --goal parser)"
printf '%s' "$fresh" | jq -e '
  .project == "demo" and .repo_id == "github.com/acme/demo"
  and .goal == "parser" and .state == "new" and .current_round == 1
  and .counts.total == 0
  and (.loop_id | test("^[0-9a-f]{8}-[0-9a-f-]{27}$"))
' >/dev/null || fail "unexpected fresh state: $fresh"
loop_one="$(printf '%s' "$fresh" | jq -r .loop_id)"

producer="$($CREATE --goal parser --loop-id "$loop_one" \
  --description 'implement parser' --acceptance 'parser checks pass' \
  2>"$TMP/create.err")"

claimable="$($STATE --goal parser)"
printf '%s' "$claimable" | jq -e --arg loop "$loop_one" --arg uuid "$producer" '
  .loop_id == $loop and .state == "claim" and .current_round == 1
  and .counts.pending == 1 and .pending[0].uuid == $uuid
  and .pending[0].acceptance == ["parser checks pass"]
' >/dev/null || fail "pending task was not reconstructed: $claimable"

review_branch="review/parser-fixture"
git branch "$review_branch"
task rc.confirmation=no rc.verbose=nothing "$producer" start >/dev/null
task rc.confirmation=no rc.verbose=nothing "$producer" annotate \
  "branch=$review_branch" >/dev/null
task rc.confirmation=no rc.verbose=nothing "$producer" annotate \
  'summary: parser implemented' >/dev/null

review="$($STATE --goal parser --loop-id "$loop_one")"
printf '%s' "$review" | jq -e --arg branch "$review_branch" '
  .state == "review" and .counts.active == 1
  and .pending[0].summary == ["parser implemented"]
  and (.review_branches | map(.branch) | index($branch)) != null
' >/dev/null || fail "review-ready state was not reconstructed: $review"

followup="$($CREATE --from-task "$producer" --description 'fix parser review' \
  --acceptance 'review finding is fixed' --depends "$producer" \
  --input "$review_branch" 2>"$TMP/followup.err")"
stacked="$($STATE --goal parser --loop-id "$loop_one")"
printf '%s' "$stacked" | jq -e --arg producer "$producer" --arg followup "$followup" '
  .current_round == 1 and .state == "review" and .counts.pending == 2
  and .counts.queued_later == 1
  and .pending[0].uuid == $producer
  and ([.pending[].uuid] | index($followup)) == null
  and .queued_later[0].uuid == $followup
  and .queued_later[0].acceptance == ["review finding is fixed"]
' >/dev/null || fail "state advanced before the oldest pending round drained: $stacked"

# Escalated and plan work belongs to `loop --large` and `loop --plan`; no other
# queue's dl-claim.sh can accept it, so it must never be reported as claimable.
escalated="$($CREATE --from-task "$producer" --description 'escalated parser fix' \
  --acceptance 'escalated fix passes' 2>"$TMP/escalated.err")"
task rc.confirmation=no rc.verbose=nothing "$escalated" modify +LARGE >/dev/null
plan="$($CREATE --goal parser --loop-id "$loop_one" --plan \
  --description 'decompose parser rewrite' --acceptance 'plan lists tasks' \
  2>"$TMP/plan.err")"

routed="$($STATE --goal parser --loop-id "$loop_one")"
printf '%s' "$routed" | jq -e --arg escalated "$escalated" --arg plan "$plan" '
  ([.pending[].uuid] | index($escalated)) == null
  and ([.pending[].uuid] | index($plan)) == null
  and ([.delegated[].uuid] | index($plan)) != null
  and ([.delegated[], .queued_later[]] | map(select(.uuid == $plan))[0].route) == "plan"
  and ([.delegated[], .queued_later[]] | map(select(.uuid == $escalated))[0].route) == "large"
' >/dev/null || fail "routed work was offered to the wrong queue: $routed"

# The partition is relative to the worker's own queue, not to a fixed set of
# tags: each queue sees its own work as claimable and everything else delegated.
plan_view="$(DEV_LOOP_ROUTE=plan $STATE --goal parser --loop-id "$loop_one")"
printf '%s' "$plan_view" | jq -e --arg plan "$plan" --arg producer "$producer" '
  .route == "plan" and .state == "claim"
  and [.pending[].uuid] == [$plan]
  and ([.delegated[].uuid] | index($producer)) != null
' >/dev/null || fail "the plan queue did not see its own task: $plan_view"

large_view="$($STATE --goal parser --loop-id "$loop_one" --route large)"
printf '%s' "$large_view" | jq -e --arg producer "$producer" '
  .route == "large" and (.pending | length) == 0
  and .state == "delegated"
  and ([.delegated[].uuid] | index($producer)) != null
' >/dev/null || fail "the large queue claimed another queue's work: $large_view"

set +e
DEV_LOOP_ROUTE=nonsense $STATE --goal parser --loop-id "$loop_one" \
  >/dev/null 2>"$TMP/bad-route.err"
bad_route_rc=$?
set -e
[ "$bad_route_rc" -eq 20 ] || fail "invalid DEV_LOOP_ROUTE exited $bad_route_rc"
grep -Fq -e '--route must be standard, small, large, or plan' "$TMP/bad-route.err" \
  || fail "invalid DEV_LOOP_ROUTE was not diagnosed"

# With every claimable task drained, pending routed work must read as awaited
# elsewhere rather than as claimable or complete.
task rc.confirmation=no rc.verbose=nothing "$producer" 'done' >/dev/null
task rc.confirmation=no rc.verbose=nothing "$followup" 'done' >/dev/null
git branch -q -D "$review_branch"
delegated_state="$($STATE --goal parser --loop-id "$loop_one")"
printf '%s' "$delegated_state" | jq -e '
  .state == "delegated" and .counts.delegated >= 1
  and (.pending | length) == 0
  and ([.delegated[].route] | sort | unique | inside(["large", "plan"]))
' >/dev/null || fail "awaited routed work was not reported as delegated: $delegated_state"

loop_two="22222222-2222-4222-8222-222222222222"
$CREATE --goal parser --loop-id "$loop_two" --description 'other parser' \
  --acceptance 'other parser checks pass' >"$TMP/other.uuid" 2>"$TMP/other.err"

set +e
$STATE --goal parser >"$TMP/ambiguous.out" 2>"$TMP/ambiguous.err"
ambiguous_rc=$?
set -e
[ "$ambiguous_rc" -eq 20 ] || fail "ambiguous loops exited $ambiguous_rc"
grep -Fq 'contradictory active loops' "$TMP/ambiguous.err" \
  || fail "ambiguous loops were not diagnosed"

printf 'PASS: dl-loop-state\n'
