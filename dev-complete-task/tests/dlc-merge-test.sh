#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE="$ROOT/scripts/dlc-merge.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dlc-merge-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP/bin" "$TMP/repo"
: >"$TMP/task.log"

cat >"$TMP/bin/task" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ] && [[ "$1" == rc.* ]]; do shift; done

if [ "${1:-}" = export ] || [ "${2:-}" = export ]; then
  jq -n --arg base "$MOCK_BASE" '[{
    uuid: "12345678-1234-1234-1234-123456789abc",
    description: "fixture task",
    project: "demo.merge",
    status: "pending",
    annotations: [
      {description: ("base=" + $base)},
      {description: "branch=review/fixture"},
      {description: "reviewer=fixture-owner#fixture-agent"},
      {description: "acceptance: fixture lands"},
      {description: "summary: fixture implementation"}
    ]
  }]'
elif [ "${2:-}" = annotate ]; then
  printf 'annotate\t%s\n' "${3:-}" >>"$MOCK_TASK_LOG"
else
  printf 'unexpected mock task invocation: %s\n' "$*" >&2
  exit 2
fi
EOF
chmod +x "$TMP/bin/task"

git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.name fixture
git -C "$TMP/repo" config user.email fixture@example.test
printf 'base\n' >"$TMP/repo/fixture.txt"
git -C "$TMP/repo" add fixture.txt
git -C "$TMP/repo" commit -qm base
MOCK_BASE="$(git -C "$TMP/repo" rev-parse HEAD)"
export MOCK_BASE
git -C "$TMP/repo" switch -qc review/fixture
printf 'implemented\n' >"$TMP/repo/fixture.txt"
git -C "$TMP/repo" commit -qam implementation
review_head="$(git -C "$TMP/repo" rev-parse HEAD)"
git -C "$TMP/repo" switch -q master 2>/dev/null \
  || git -C "$TMP/repo" switch -q main

export PATH="$TMP/bin:$PATH"
export MOCK_TASK_LOG="$TMP/task.log"
export DEV_LOOP_OWNER=fixture-owner
export AGENT_PID=fixture-agent

cd "$TMP/repo"
result="$($MERGE review/fixture 2>"$TMP/merge.err")"
[ "$result" = "$(git rev-parse HEAD)" ] || fail "stdout did not return integration HEAD"
git merge-base --is-ancestor "$review_head" HEAD \
  || fail "review commit was not integrated"
if git show-ref --verify --quiet refs/heads/review/fixture; then
  fail "merged review branch was not deleted"
fi
grep -Fq 'dev-complete-task: merged review/fixture' "$TMP/task.log" \
  || fail "producer audit annotation was not written"

# --- conflicting branch: merge stays in progress, then --continue finishes it
integration="$(git -C "$TMP/repo" symbolic-ref --short HEAD)"
git -C "$TMP/repo" switch -qc review/fixture "$MOCK_BASE"
printf 'branch side\n' >"$TMP/repo/fixture.txt"
git -C "$TMP/repo" commit -qam 'conflicting implementation'
conflict_head="$(git -C "$TMP/repo" rev-parse HEAD)"
git -C "$TMP/repo" switch -q "$integration"
printf 'integration side\n' >"$TMP/repo/fixture.txt"
git -C "$TMP/repo" commit -qam 'integration moves on'

set +e
$MERGE review/fixture >"$TMP/conflict.out" 2>"$TMP/conflict.err"
rc=$?
set -e
[ "$rc" = 40 ] || fail "conflicting merge exited $rc, expected 40"
grep -Fq 'fixture.txt' "$TMP/conflict.err" || fail "conflicted path was not reported"
[ -f "$TMP/repo/.git/MERGE_HEAD" ] || fail "conflicting merge was not left in progress"
git -C "$TMP/repo" show-ref --verify --quiet refs/heads/review/fixture \
  || fail "branch was deleted despite the conflict"

# unresolved --continue must refuse rather than commit markers
set +e
$MERGE review/fixture --continue >/dev/null 2>"$TMP/continue-early.err"
rc=$?
set -e
[ "$rc" = 40 ] || fail "--continue with unmerged paths exited $rc, expected 40"

# staged conflict markers must still refuse
git -C "$TMP/repo" add fixture.txt
set +e
$MERGE review/fixture --continue >/dev/null 2>"$TMP/continue-markers.err"
rc=$?
set -e
[ "$rc" = 40 ] || fail "--continue with conflict markers exited $rc, expected 40"
grep -Fq 'conflict markers' "$TMP/continue-markers.err" \
  || fail "leftover conflict markers were not diagnosed"

printf 'resolved\n' >"$TMP/repo/fixture.txt"
git -C "$TMP/repo" add fixture.txt
result="$($MERGE review/fixture --continue 2>"$TMP/continue.err")"
[ "$result" = "$(git -C "$TMP/repo" rev-parse HEAD)" ] \
  || fail "--continue did not return integration HEAD"
[ ! -f "$TMP/repo/.git/MERGE_HEAD" ] || fail "resolved merge was not committed"
git -C "$TMP/repo" merge-base --is-ancestor "$conflict_head" HEAD \
  || fail "resolved merge did not integrate the review commit"
[ "$(cat "$TMP/repo/fixture.txt")" = resolved ] || fail "resolution was not preserved"
if git -C "$TMP/repo" show-ref --verify --quiet refs/heads/review/fixture; then
  fail "branch was not deleted after --continue"
fi
grep -Fq 'reviewer-resolved conflicts' "$TMP/task.log" \
  || fail "resolution was not recorded in the producer annotation"

# --- --abort backs a conflicting merge out and keeps the branch
git -C "$TMP/repo" switch -qc review/fixture "$MOCK_BASE"
printf 'other branch side\n' >"$TMP/repo/fixture.txt"
git -C "$TMP/repo" commit -qam 'second conflicting implementation'
git -C "$TMP/repo" switch -q "$integration"
before_abort="$(git -C "$TMP/repo" rev-parse HEAD)"

set +e
$MERGE review/fixture >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 40 ] || fail "second conflicting merge exited $rc, expected 40"

# a second plain run must not stomp the in-progress merge
set +e
$MERGE review/fixture >/dev/null 2>"$TMP/reentry.err"
rc=$?
set -e
[ "$rc" = 20 ] || fail "re-running over an in-progress merge exited $rc, expected 20"
[ -f "$TMP/repo/.git/MERGE_HEAD" ] || fail "re-run disturbed the in-progress merge"

$MERGE review/fixture --abort >/dev/null 2>"$TMP/abort.err"
[ ! -f "$TMP/repo/.git/MERGE_HEAD" ] || fail "--abort did not end the merge"
[ "$(git -C "$TMP/repo" rev-parse HEAD)" = "$before_abort" ] \
  || fail "--abort moved integration HEAD"
git -C "$TMP/repo" show-ref --verify --quiet refs/heads/review/fixture \
  || fail "--abort deleted the review branch"

printf 'ok: dlc-merge clean, conflict-resolution, and abort tests\n'
