#!/usr/bin/env bash
# dl_task_modify refuses a `task modify` that silently rewrote the description.
#
# Taskwarrior turns an argument it does not recognize as an attribute into
# description text and exits 0, so `modify assignee:` against an rc where the
# assignee UDA is undefined replaces the task title with the literal string
# "assignee:" and reports success. The wrapper reads the description back,
# restores it, and fails loudly instead.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-task-modify-test.XXXXXX")"
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

# An rc with no UDAs at all: the state a worker lands in when dl-setup.sh was
# skipped or TASKRC points at an unrelated profile.
: >"$TASKRC"

# shellcheck source=../scripts/dl-common.sh
# shellcheck disable=SC1091  # ROOT is resolved dynamically from this test file.
. "$ROOT/scripts/dl-common.sh"

title='Add CFP form duplication and lifecycle actions'
dl_task add "$title" >/dev/null
uuid="$(dl_task _get 1.uuid)"

# Baseline: plain `task modify` really does eat the title and exit 0. If
# Taskwarrior ever starts rejecting this, the wrapper is no longer needed and
# this test should be the thing that says so.
rc=0
dl_task "$uuid" modify assignee: >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "expected bare 'task modify assignee:' to exit 0 on an rc without the UDA (got $rc)"
[ "$(dl_task_field "$uuid" '.description // ""')" = "assignee:" ] ||
  fail "expected bare 'task modify assignee:' to clobber the description; Taskwarrior behavior changed"
dl_task "$uuid" modify description:"$title" >/dev/null

# The wrapper refuses the same call, and leaves the title intact.
rc=0
( dl_task_modify "$uuid" assignee: ) >/dev/null 2>"$TMP/clobber.err" || rc=$?
[ "$rc" -eq "$DL_PRECOND" ] || fail "clobbering modify did not fail with exit $DL_PRECOND (got $rc)"
grep -q 'overwrote the task description' "$TMP/clobber.err" ||
  fail "clobber rejection did not explain what happened: $(cat "$TMP/clobber.err")"
[ "$(dl_task_field "$uuid" '.description // ""')" = "$title" ] ||
  fail "clobbered title was not restored (now: $(dl_task_field "$uuid" '.description // ""'))"

# A caller that means to rewrite the title is allowed through unchecked.
dl_task_modify "$uuid" description:"Renamed on purpose" >/dev/null
[ "$(dl_task_field "$uuid" '.description // ""')" = "Renamed on purpose" ] ||
  fail "an explicit description: rewrite was not applied"
dl_task_modify "$uuid" description:"$title" >/dev/null

# With the UDAs registered the same calls are ordinary attribute writes, and
# clearing one leaves the title alone.
printf '%s\n' \
  'uda.assignee.type=string' \
  'uda.assignee.label=Assignee' \
  >"$TASKRC"

dl_task_modify "$uuid" assignee:"owner-a" >/dev/null
[ "$(dl_task_field "$uuid" '.assignee // ""')" = "owner-a" ] || fail "assignee: was not set with the UDA defined"
[ "$(dl_task_field "$uuid" '.description // ""')" = "$title" ] || fail "setting a defined UDA changed the description"

dl_task_modify "$uuid" assignee: >/dev/null
[ -z "$(dl_task_field "$uuid" '.assignee // ""')" ] || fail "assignee: did not clear the UDA"
[ "$(dl_task_field "$uuid" '.description // ""')" = "$title" ] || fail "clearing a defined UDA changed the description"

printf 'ok: dl_task_modify rejects description-clobbering modifies and passes real attribute writes through\n'
