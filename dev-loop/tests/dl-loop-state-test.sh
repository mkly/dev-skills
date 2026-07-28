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
