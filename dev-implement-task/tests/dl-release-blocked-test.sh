#!/usr/bin/env bash
# Releasing with --blocked-by must take the task out of the claimable queue
# until its blocker completes; without it the same task is handed straight back
# to the next worker.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAIM="$ROOT/scripts/dl-claim.sh"
RELEASE="$ROOT/scripts/dl-release.sh"
CREATE="$ROOT/../dev-create-tasks/scripts/dct-create.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-release-blocked-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

export TASKRC="$TMP/taskrc"
export TASKDATA="$TMP/taskdata"
export DEV_LOOP_STATE_DIR="$TMP/state"
export DEV_LOOP_TITLE=off
export DEV_BOARD_DISABLE=1
mkdir -p "$TASKDATA" "$TMP/bin"
printf '%s\n' \
  'uda.assignee.type=string' \
  'uda.assignee.label=Assignee' \
  >"$TASKRC"

# dl-release.sh requires crabbox; the tasks here never warm a box, so a stub
# that fails loudly if it is ever asked to do work is enough.
cat >"$TMP/bin/crabbox" <<'EOF'
#!/usr/bin/env bash
printf 'stub crabbox called: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP/bin/crabbox"
export PATH="$TMP/bin:$PATH"

tw() { task rc.confirmation=no rc.verbose=nothing "$@"; }

LOOP_ID=44444444-4444-4444-8444-444444444444
mk() {
  "$CREATE" --goal release-blocked --loop-id "$LOOP_ID" \
    --description "$1" --acceptance "$2" 2>>"$TMP/create.err"
}

blocker="$(mk 'produce the shared schema module' 'schema module exists')"
consumer="$(mk 'consume the shared schema module' 'consumer builds against schema')"

# The consumer is claimable until a worker discovers the blocker.
claimed="$(DEV_LOOP_OWNER=owner-a "$CLAIM" "$consumer" 2>"$TMP/claim.err")"
[ "$claimed" = "$consumer" ] || fail "could not claim the consumer task"

# Self-reference, a completed blocker, and a cycle must all be refused before
# anything is released.
set +e
DEV_LOOP_OWNER=owner-a "$RELEASE" "$consumer" --blocked-by "$consumer" \
  >/dev/null 2>"$TMP/self.err"
self_rc=$?
set -e
[ "$self_rc" -eq 20 ] || fail "self-blocking release exited $self_rc, expected 20"
[ "$(tw "$consumer" export | jq -r '.[0].assignee // ""')" != "" ] \
  || fail "a rejected --blocked-by released the claim anyway"

set +e
DEV_LOOP_OWNER=owner-a "$RELEASE" "$consumer" --blocked-by 'no-such-task' \
  >/dev/null 2>"$TMP/missing.err"
missing_rc=$?
set -e
[ "$missing_rc" -eq 20 ] || fail "unresolvable --blocked-by exited $missing_rc, expected 20"

# The real path: release blocked on the producer.
DEV_LOOP_OWNER=owner-a "$RELEASE" "$consumer" --blocked-by "$blocker" \
  >/dev/null 2>"$TMP/release.err"

tw "$consumer" export | jq -e --arg b "$blocker" '
  .[0] as $t
  | (($t.depends // []) | if type == "string" then split(",") else . end
     | index($b)) != null
  and ($t.assignee // "") == ""
  and ([($t.annotations // [])[].description
        | select(startswith("blocked-by="))] | length) == 1
' >/dev/null || fail "release did not record the dependency, annotation, and free the claim"

# The queue must now skip it entirely.
picked="$(DEV_LOOP_OWNER=owner-b "$CLAIM" --goal release-blocked \
  --loop-id "$LOOP_ID" 2>"$TMP/pick-blocked.err")"
[ "$picked" = "$blocker" ] \
  || fail "auto-pick returned '$picked'; expected the blocker, never the blocked consumer"

set +e
DEV_LOOP_OWNER=owner-c "$CLAIM" "$consumer" >/dev/null 2>"$TMP/explicit.err"
explicit_rc=$?
set -e
[ "$explicit_rc" -eq 20 ] || fail "explicit claim of a blocked task exited $explicit_rc, expected 20"

# A blocked task must stay visible in status, or an idle loop is unexplainable.
DEV_LOOP_OWNER=owner-b "$ROOT/scripts/dl-status.sh" >"$TMP/status.out" 2>/dev/null \
  || fail "dl-status.sh failed"
grep -A2 'Blocked tasks:' "$TMP/status.out" \
  | grep -q "${consumer:0:8}.*waiting on ${blocker:0:8}" \
  || fail "dl-status.sh did not report the blocked task and its blocker"

# A cycle in the other direction must be refused, not deadlock both tasks.
set +e
DEV_LOOP_OWNER=owner-b "$RELEASE" "$blocker" --blocked-by "$consumer" \
  >/dev/null 2>"$TMP/cycle.err"
cycle_rc=$?
set -e
[ "$cycle_rc" -eq 20 ] || fail "cyclic --blocked-by exited $cycle_rc, expected 20"
grep -q 'cycle' "$TMP/cycle.err" || fail "cycle refusal did not explain itself"

# Completing the blocker releases the consumer back into the queue.
tw "$blocker" done >/dev/null
back="$(DEV_LOOP_OWNER=owner-d "$CLAIM" --goal release-blocked \
  --loop-id "$LOOP_ID" 2>"$TMP/pick-after.err")"
[ "$back" = "$consumer" ] \
  || fail "consumer did not become claimable after its blocker completed (got '$back')"

printf 'ok: dl-release.sh --blocked-by keeps blocked tasks out of the queue\n'
