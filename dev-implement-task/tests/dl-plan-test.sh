#!/usr/bin/env bash
# Plan artifact store: dl_plan_put/get/clear round-trip a markdown file
# through the `plan` UDA (gzip+base64, single line), a task with no plan of
# its own follows one "plan: <producer-uuid>" annotation hop to a producer's,
# and an oversized source file is rejected rather than silently truncated.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-plan-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

export TASKRC="$TMP/taskrc"
export TASKDATA="$TMP/taskdata"
export DEV_LOOP_STATE_DIR="$TMP/state"
export DEV_LOOP_OWNER="owner-a"
mkdir -p "$TASKDATA"
printf '%s\n' \
  'uda.assignee.type=string' \
  'uda.assignee.label=Assignee' \
  'uda.plan.type=string' \
  'uda.plan.label=Plan' \
  >"$TASKRC"

# shellcheck source=../scripts/dl-common.sh
# shellcheck disable=SC1091  # ROOT is resolved dynamically from this test file.
. "$ROOT/scripts/dl-common.sh"

dl_task add "producer task" >/dev/null
producer="$(dl_task _get 1.uuid)"
dl_task add "consumer task" >/dev/null
consumer="$(dl_task _get 2.uuid)"
dl_task add "unrelated task" >/dev/null
neither="$(dl_task _get 3.uuid)"

printf '# Plan\n\nSome *markdown* with unicode: caf\xc3\xa9 and no trailing newline' >"$TMP/plan.md"

dl_plan_put "$producer" "$TMP/plan.md"
dl_plan_get "$producer" >"$TMP/plan.out.md"
diff "$TMP/plan.md" "$TMP/plan.out.md" >/dev/null || fail "round-trip did not reproduce the original markdown byte-for-byte"

# The hop annotation must be written as free-form text via `--`, since a bare
# "plan: <uuid>" token is otherwise parsed as a UDA assignment now that `plan`
# is a registered attribute.
dl_task "$consumer" annotate -- "plan: $producer" >/dev/null
dl_plan_get "$consumer" >"$TMP/hop.out.md"
diff "$TMP/plan.md" "$TMP/hop.out.md" >/dev/null || fail "consumer's hop through its producer's plan did not match"

out="$(dl_plan_get "$neither")"
[ -z "$out" ] || fail "a task with neither a plan nor a hop annotation printed something: '$out'"

dl_plan_clear "$producer"
out="$(dl_plan_get "$producer")"
[ -z "$out" ] || fail "dl_plan_clear did not remove the plan UDA"

big="$TMP/big.md"
head -c 20000 /dev/urandom | base64 >"$big"
rc=0
( dl_plan_put "$producer" "$big" ) >/dev/null 2>"$TMP/big.err" || rc=$?
[ "$rc" -eq "$DL_PRECOND" ] || fail "oversized plan file did not fail with exit $DL_PRECOND (got $rc)"
grep -q 'exceeds 16384 bytes' "$TMP/big.err" || fail "oversized rejection did not name the byte cap"
[ -z "$(dl_task_field "$producer" '.plan // ""')" ] || fail "a rejected oversized plan should not have been stored (truncated)"

printf 'ok: dl_plan_put/get/clear round-trip, hop, and oversized rejection\n'
