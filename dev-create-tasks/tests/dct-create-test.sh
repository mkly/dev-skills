#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREATE="$ROOT/scripts/dct-create.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dct-create-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_uuid() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || fail "not a UUID: $1"
}

export TASKRC="$TMP/taskrc"
export TASKDATA="$TMP/taskdata"
mkdir -p "$TASKDATA" "$TMP/repo"
printf '%s\n' \
  'uda.assignee.type=string' \
  'uda.assignee.label=Assignee' \
  >"$TASKRC"

git -C "$TMP/repo" init -q
git -C "$TMP/repo" remote add origin git@github.com:Acme/Demo.git
cd "$TMP/repo"

task_json() {
  task rc.context=none rc.json.array=on rc.verbose=nothing "$1" export
}

PARSER_LOOP="11111111-1111-4111-8111-111111111111"
dependency="$($CREATE \
  --goal parser \
  --loop-id "$PARSER_LOOP" \
  --description 'implement parser' \
  --acceptance 'focused parser checks pass' \
  2>"$TMP/dependency.err")"
assert_uuid "$dependency"
grep -F 'Taskwarrior sync is not configured; continuing' "$TMP/dependency.err" >/dev/null \
  || fail "creation did not tolerate an unconfigured Taskwarrior sync"

created_json="$($CREATE --json \
  --from-task "$dependency" \
  --description 'integrate parser with command' \
  --acceptance 'command consumes parser output' \
  --acceptance 'end-to-end: input reaches the command result' \
  --depends "$dependency" \
  --depends "${dependency:0:8}" \
  --input "review/dl-${dependency:0:8}-implement-parser" \
  --review-of "${dependency:0:8} review/original" \
  --annotation 'source: regression test' \
  2>"$TMP/created.err")"

created="$(printf '%s' "$created_json" | jq -r .uuid)"
assert_uuid "$created"
expected_branch="$(
  bash -c '. "$1"; printf "review/%s\n" "$(dl_slug "$2" "$3")"' \
    _ "$ROOT/../dev-implement-task/scripts/dl-common.sh" "$created" 'integrate parser with command'
)"
printf '%s' "$created_json" | jq -e \
  --arg expected_branch "$expected_branch" \
  --arg loop_id "$PARSER_LOOP" '
    .created == true
    and .review_branch == $expected_branch
    and .project == "demo"
    and .repo_id == "github.com/acme/demo"
    and .goal == "parser"
    and .loop_id == $loop_id
    and .loop_round == 2
    and .description == "integrate parser with command"
  ' >/dev/null || fail "unexpected JSON result: $created_json"

task_json "$created" | jq -e --arg dependency "$dependency" --arg loop_id "$PARSER_LOOP" '
  length == 1
  and .[0].status == "pending"
  and .[0].project == "demo"
  and .[0].description == "integrate parser with command"
  and (.[0].start? == null)
  and ((.[0].assignee // "") == "")
  and .[0].depends == [$dependency]
  and ([.[0].annotations[].description] | sort) == ([
    "acceptance: command consumes parser output",
    "acceptance: end-to-end: input reaches the command result",
    "goal: parser",
    "input: review/dl-" + ($dependency[0:8]) + "-implement-parser",
    "loop-id: " + $loop_id,
    "loop-round: 2",
    "repo-id: github.com/acme/demo",
    "review-of: " + ($dependency[0:8]) + " review/original",
    "source: regression test"
  ] | sort)
' >/dev/null || fail "created task metadata did not match"

# plan: is reserved like the other identity annotations: dl_plan_get's
# producer hop depends on it never being overridable from task creation.
set +e
plan_reject_err="$(
  $CREATE --goal parser --loop-id "$PARSER_LOOP" \
    --description 'reject reserved plan annotation' \
    --acceptance 'must not import' \
    --annotation 'plan: some-producer-uuid' 2>&1 1>"$TMP/plan-reject.out"
)"
plan_reject_rc=$?
set -e
[ "$plan_reject_rc" -eq 20 ] || fail "reserved plan: annotation exited $plan_reject_rc"
[ ! -s "$TMP/plan-reject.out" ] || fail "reserved plan: annotation wrote stdout"
printf '%s' "$plan_reject_err" | grep -Fq "identity annotations are reserved" \
  || fail "reserved plan: annotation was not diagnosed: $plan_reject_err"

before="$(task rc.context=none rc.verbose=nothing status:pending count)"
dry_json="$($CREATE --json --dry-run \
  --goal dry-run --loop-id 22222222-2222-4222-8222-222222222222 \
  --description 'dry run task' --acceptance 'would pass' \
  2>"$TMP/dry.err")"
after="$(task rc.context=none rc.verbose=nothing status:pending count)"
[ "$before" = "$after" ] || fail "dry run changed task count"
printf '%s' "$dry_json" | jq -e '
  .created == false and .project == "demo"
  and .repo_id == "github.com/acme/demo" and .goal == "dry-run"
  and .loop_round == 1
' >/dev/null || fail "dry-run JSON identity was incorrect"

other_loop_task="$($CREATE \
  --goal other --loop-id 88888888-8888-4888-8888-888888888888 \
  --description 'other loop task' --acceptance 'other loop remains isolated' \
  --small \
  2>"$TMP/other-loop.err")"
assert_uuid "$other_loop_task"
task_json "$other_loop_task" | jq -e '
  length == 1 and .[0].tags == ["SMALL"]
' >/dev/null || fail "--small did not persist the SMALL tag"

set +e
$CREATE --goal invalid --loop-id 33333333-3333-4333-8333-333333333333 \
  --description 'missing acceptance' >"$TMP/invalid.out" 2>"$TMP/invalid.err"
invalid_rc=$?
$CREATE --goal invalid --loop-id 33333333-3333-4333-8333-333333333333 \
  --description 'bad dependency' --acceptance 'never imported' \
  --depends does-not-exist >"$TMP/bad-dep.out" 2>"$TMP/bad-dep.err"
bad_dep_rc=$?
$CREATE --project invented --description invalid --acceptance invalid \
  >"$TMP/project.out" 2>"$TMP/project.err"
project_rc=$?
$CREATE --goal parser --loop-id "$PARSER_LOOP" \
  --description 'cross-loop dependency' --acceptance 'must not import' \
  --depends "$other_loop_task" >"$TMP/cross-loop.out" 2>"$TMP/cross-loop.err"
cross_loop_rc=$?
set -e
[ "$invalid_rc" -eq 20 ] || fail "missing acceptance exited $invalid_rc"
[ "$bad_dep_rc" -eq 20 ] || fail "bad dependency exited $bad_dep_rc"
[ "$project_rc" -eq 20 ] || fail "arbitrary project option exited $project_rc"
[ "$cross_loop_rc" -eq 20 ] || fail "cross-loop dependency exited $cross_loop_rc"
[ ! -s "$TMP/invalid.out" ] || fail "invalid creation wrote stdout"
[ ! -s "$TMP/bad-dep.out" ] || fail "bad dependency wrote stdout"
[ ! -s "$TMP/project.out" ] || fail "arbitrary project option wrote stdout"
[ ! -s "$TMP/cross-loop.out" ] || fail "cross-loop dependency wrote stdout"
grep -Fq "does not share the task's repository, goal, and loop identity" \
  "$TMP/cross-loop.err" || fail "cross-loop dependency was not diagnosed"

# Repository identity is a hard autonomous precondition. Do not fall back to
# the checkout directory or accept a non-GitHub remote.
mkdir -p "$TMP/no-origin" "$TMP/non-github"
git -C "$TMP/no-origin" init -q
git -C "$TMP/non-github" init -q
git -C "$TMP/non-github" remote add origin https://gitlab.com/acme/demo.git
set +e
(
  cd "$TMP/no-origin"
  "$CREATE" --dry-run --goal invalid \
    --loop-id 66666666-6666-4666-8666-666666666666 \
    --description invalid --acceptance invalid
) >"$TMP/no-origin.out" 2>"$TMP/no-origin.err"
no_origin_rc=$?
(
  cd "$TMP/non-github"
  "$CREATE" --dry-run --goal invalid \
    --loop-id 77777777-7777-4777-8777-777777777777 \
    --description invalid --acceptance invalid
) >"$TMP/non-github.out" 2>"$TMP/non-github.err"
non_github_rc=$?
set -e
[ "$no_origin_rc" -eq 20 ] || fail "missing origin exited $no_origin_rc"
[ "$non_github_rc" -eq 20 ] || fail "non-GitHub origin exited $non_github_rc"
[ ! -s "$TMP/no-origin.out" ] || fail "missing origin wrote stdout"
[ ! -s "$TMP/non-github.out" ] || fail "non-GitHub origin wrote stdout"
grep -Fq 'target repository has no origin remote' "$TMP/no-origin.err" \
  || fail "missing origin was not diagnosed"
grep -Fq 'origin must be a GitHub repository URL' "$TMP/non-github.err" \
  || fail "non-GitHub origin was not diagnosed"

# Concurrent creators must each receive their own UUID while sharing one
# repository project and one controller loop identity.
CONCURRENT_LOOP="44444444-4444-4444-8444-444444444444"
concurrent=8
for n in $(seq 1 "$concurrent"); do
  "$CREATE" --goal concurrent --loop-id "$CONCURRENT_LOOP" \
    --description "task $n" --acceptance "task $n exists" \
    >"$TMP/concurrent-$n.out" 2>"$TMP/concurrent-$n.err" &
done
wait

for n in $(seq 1 "$concurrent"); do
  uuid="$(<"$TMP/concurrent-$n.out")"
  assert_uuid "$uuid"
  task_json "$uuid" | jq -e --arg description "task $n" \
    'length == 1 and .[0].project == "demo" and .[0].description == $description' >/dev/null \
    || fail "concurrent creator $n received another task's UUID"
done

unique="$(sort -u "$TMP"/concurrent-*.out | wc -l | tr -d ' ')"
[ "$unique" -eq "$concurrent" ] || fail "concurrent UUIDs were not unique"
all="$(task rc.context=none rc.json.array=on rc.verbose=nothing export)"
count="$(printf '%s' "$all" | jq --arg loop "$CONCURRENT_LOOP" '
  [.[] | select(.project == "demo")
   | select(any(.annotations[]?.description; . == ("loop-id: " + $loop)))] | length')"
[ "$count" -eq "$concurrent" ] || fail "expected $concurrent concurrent tasks, found $count"
repo_count="$(printf '%s' "$all" | jq '[.[] | select(.project == "demo")] | length')"
expected_repo_count=$((concurrent + 3))
[ "$repo_count" -eq "$expected_repo_count" ] \
  || fail "repository project did not group all $expected_repo_count tasks"

# The basename is autonomous, but a known same-name project associated with a
# different GitHub owner must not be silently mixed, even when all prior tasks
# for that repository are already completed.
export TASKDATA="$TMP/collision-taskdata"
mkdir -p "$TASKDATA"
historical="$($CREATE --goal historical \
  --loop-id 99999999-9999-4999-8999-999999999999 \
  --description 'completed repository marker' \
  --acceptance 'repository identity remains durable' \
  2>"$TMP/historical.err")"
# shellcheck disable=SC1010  # 'done' is the Taskwarrior subcommand.
task rc.confirmation=no rc.verbose=nothing "$historical" done >/dev/null
mkdir -p "$TMP/collision"
git -C "$TMP/collision" init -q
git -C "$TMP/collision" remote add origin https://github.com/other/demo.git
set +e
(
  cd "$TMP/collision"
  "$CREATE" --goal collision --loop-id 55555555-5555-4555-8555-555555555555 \
    --description collision --acceptance 'must not import'
) >"$TMP/collision.out" 2>"$TMP/collision.err"
collision_rc=$?
set -e
[ "$collision_rc" -eq 20 ] || fail "repository collision exited $collision_rc"
[ ! -s "$TMP/collision.out" ] || fail "repository collision wrote stdout"
grep -Fq "project 'demo' is already associated with another GitHub repository" "$TMP/collision.err" \
  || fail "repository collision was not diagnosed"

printf 'ok: dct-create repository identity and atomic creation tests\n'
