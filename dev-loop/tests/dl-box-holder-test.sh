#!/usr/bin/env bash
# Box ownership: a live lease is not automatically an available one.
#
# The sequence this pins down is the one that put two live tasks in one box:
# task A records a box, is released (which parks the lease for reuse), and task
# B — often another agent, since the parked slot is per repo and not per owner —
# adopts it. Nothing here needs crabbox: the question is who Taskwarrior says
# holds a handle, which is what park/adopt/reuse must consult.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREATE="$ROOT/../dev-loop-task/scripts/dlt-create.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-box-holder-test.XXXXXX")"
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
  >"$TASKRC"

# shellcheck source=../scripts/dl-common.sh
. "$ROOT/scripts/dl-common.sh"

a="$("$CREATE" --project demo.box-holder --description 'holds a box' \
  --acceptance 'ownership is checked' 2>"$TMP/a.err")"
b="$("$CREATE" --project demo.box-holder --description 'wants a box' \
  --acceptance 'ownership is checked' 2>"$TMP/b.err")"

[ -z "$(dl_box_holder cbx_one)" ] || fail "an unheld handle reported a holder"

dl_anno_set "$a" box cbx_one
holder="$(dl_box_holder cbx_one)"
[ "$holder" = "$a" ] || fail "expected task A to hold cbx_one; got '${holder:0:8}'"

# The caller must be able to exclude itself, or every task would look contended
# with its own box.
[ -z "$(dl_box_holder cbx_one "$a")" ] \
  || fail "a task's own box counted as held by someone else"

# What dl-release.sh now does when it parks: the task keeps no claim on a lease
# it gave away, so a later re-claim warms fresh instead of reusing a box that
# has since been adopted.
dl_anno_set "$a" box ""
[ -z "$(dl_box_holder cbx_one)" ] \
  || fail "a cleared box= still reported a holder"

# A completed holder is not a live one; its lease is genuinely reusable.
dl_anno_set "$b" box cbx_two
[ "$(dl_box_holder cbx_two)" = "$b" ] || fail "expected task B to hold cbx_two"
task rc.confirmation=no rc.verbose=nothing "$b" done >/dev/null 2>&1
[ -z "$(dl_box_holder cbx_two)" ] \
  || fail "a completed task still counted as holding its box"

printf 'ok: dl_box_holder ownership test\n'
