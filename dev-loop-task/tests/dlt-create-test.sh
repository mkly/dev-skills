#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREATE="$ROOT/scripts/dlt-create.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dlt-create-test.XXXXXX")"
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
mkdir -p "$TASKDATA"
printf '%s\n' \
  'uda.assignee.type=string' \
  'uda.assignee.label=Assignee' \
  >"$TASKRC"

task_json() {
  task rc.context=none rc.json.array=on rc.verbose=nothing "$1" export
}

dependency="$($CREATE \
  --project demo \
  --description 'implement parser' \
  --acceptance 'focused parser checks pass' \
  2>"$TMP/dependency.err")"
assert_uuid "$dependency"
grep -F 'Taskwarrior sync is not configured; continuing' "$TMP/dependency.err" >/dev/null \
  || fail "creation did not tolerate an unconfigured Taskwarrior sync"

created_json="$($CREATE --json \
  --project demo \
  --description 'integrate parser with command' \
  --acceptance 'command consumes parser output' \
  --acceptance 'end-to-end: input reaches the command result' \
  --depends "$dependency" \
  --depends "${dependency:0:8}" \
  --input "review/dl-${dependency:0:8}-implement-parser" \
  --review-of "abcd1234 review/original" \
  --loop-round 2 \
  --annotation 'source: regression test' \
  2>"$TMP/created.err")"

created="$(printf '%s' "$created_json" | jq -r .uuid)"
assert_uuid "$created"
expected_branch="$(
  bash -c '. "$1"; printf "review/%s\n" "$(dl_slug "$2" "$3")"' \
    _ "$ROOT/../dev-loop/scripts/dl-common.sh" "$created" 'integrate parser with command'
)"
printf '%s' "$created_json" | jq -e \
  --arg expected_branch "$expected_branch" '
    .created == true
    and .review_branch == $expected_branch
    and .project == "demo"
    and .description == "integrate parser with command"
  ' >/dev/null || fail "unexpected JSON result: $created_json"

task_json "$created" | jq -e --arg dependency "$dependency" '
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
    "input: review/dl-" + ($dependency[0:8]) + "-implement-parser",
    "loop-round: 2",
    "review-of: abcd1234 review/original",
    "source: regression test"
  ] | sort)
' >/dev/null || fail "created task metadata did not match"

before="$(task rc.context=none rc.verbose=nothing status:pending count)"
dry_json="$($CREATE --json --dry-run \
  --project demo --description 'dry run task' --acceptance 'would pass' \
  2>"$TMP/dry.err")"
after="$(task rc.context=none rc.verbose=nothing status:pending count)"
[ "$before" = "$after" ] || fail "dry run changed task count"
printf '%s' "$dry_json" | jq -e '.created == false' >/dev/null \
  || fail "dry-run JSON was not marked uncreated"

set +e
$CREATE --project demo --description 'missing acceptance' \
  >"$TMP/invalid.out" 2>"$TMP/invalid.err"
invalid_rc=$?
$CREATE --project demo --description 'bad dependency' --acceptance 'never imported' \
  --depends does-not-exist >"$TMP/bad-dep.out" 2>"$TMP/bad-dep.err"
bad_dep_rc=$?
set -e
[ "$invalid_rc" -eq 20 ] || fail "missing acceptance exited $invalid_rc"
[ "$bad_dep_rc" -eq 20 ] || fail "bad dependency exited $bad_dep_rc"
[ ! -s "$TMP/invalid.out" ] || fail "invalid creation wrote stdout"
[ ! -s "$TMP/bad-dep.out" ] || fail "bad dependency wrote stdout"

# Concurrent creators must each receive the UUID of their own imported task.
concurrent=8
for n in $(seq 1 "$concurrent"); do
  "$CREATE" --project concurrent --description "task $n" --acceptance "task $n exists" \
    >"$TMP/concurrent-$n.out" 2>"$TMP/concurrent-$n.err" &
done
wait

for n in $(seq 1 "$concurrent"); do
  uuid="$(<"$TMP/concurrent-$n.out")"
  assert_uuid "$uuid"
  task_json "$uuid" | jq -e --arg description "task $n" \
    'length == 1 and .[0].description == $description' >/dev/null \
    || fail "concurrent creator $n received another task's UUID"
done

unique="$(sort -u "$TMP"/concurrent-*.out | wc -l | tr -d ' ')"
[ "$unique" -eq "$concurrent" ] || fail "concurrent UUIDs were not unique"
count="$(task rc.context=none rc.verbose=nothing project:concurrent status:pending count)"
[ "$count" -eq "$concurrent" ] || fail "expected $concurrent concurrent tasks, found $count"

printf 'ok: dlt-create atomic task creation tests\n'
