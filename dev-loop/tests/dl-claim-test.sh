#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAIM="$ROOT/scripts/dl-claim.sh"
CREATE="$ROOT/../dev-loop-task/scripts/dlt-create.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-claim-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

export TASKRC="$TMP/taskrc"
export TASKDATA="$TMP/taskdata"
export DEV_LOOP_STATE_DIR="$TMP/state"
mkdir -p "$TASKDATA"
printf '%s\n' \
  'uda.assignee.type=string' \
  'uda.assignee.label=Assignee' \
  >"$TASKRC"

uuid="$(
  "$CREATE" --project demo.claim-test --description 'claim exactly once' \
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

task rc.context=none rc.json.array=on rc.verbose=nothing "$uuid" export \
  | jq -e '
      length == 1
      and (.[0].assignee | test("^owner-[ab]#"))
      and (.[0].start | type == "string")
    ' >/dev/null \
  || fail "winning owner or active state was not persisted"

printf 'ok: dl-claim concurrency test\n'
