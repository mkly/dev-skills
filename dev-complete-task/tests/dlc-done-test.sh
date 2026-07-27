#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DONE="$ROOT/scripts/dlc-done.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dlc-done-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/config"
printf 'pending\n' >"$TMP/status"
: >"$TMP/task.log"

cat >"$TMP/bin/task" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

while [ "$#" -gt 0 ] && [[ "$1" == rc.* ]]; do shift; done
uuid="${1:-}"
cmd="${2:-}"

case "$cmd" in
  export)
    status="$(cat "$MOCK_STATUS")"
    jq -n --arg uuid "$uuid" --arg status "$status" --arg owner "$DEV_LOOP_OWNER" '
      [{uuid: $uuid, status: $status, assignee: ($owner + "#test"),
        description: "fixture task",
        annotations: [{description: "branch=review/fixture"},
                      {description: ("commits=base.." + env.MOCK_HEAD + " (n=1)")}]}]'
    ;;
  annotate)
    printf 'annotate\t%s\n' "${3:-}" >>"$MOCK_TASK_LOG"
    ;;
  done)
    printf 'completed\n' >"$MOCK_STATUS"
    printf 'done\n' >>"$MOCK_TASK_LOG"
    ;;
  *)
    printf 'unexpected mock task invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF

cat >"$TMP/bin/crabbox" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/task" "$TMP/bin/crabbox"

export PATH="$TMP/bin:$PATH"
export MOCK_STATUS="$TMP/status"
export MOCK_TASK_LOG="$TMP/task.log"
export DEV_LOOP_OWNER="fixture-owner"
export DEV_LOOP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/config"

mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.name fixture
git -C "$TMP/repo" config user.email fixture@example.test
printf 'fixture\n' >"$TMP/repo/fixture.txt"
git -C "$TMP/repo" add fixture.txt
git -C "$TMP/repo" commit -qm fixture
MOCK_HEAD="$(git -C "$TMP/repo" rev-parse HEAD)"
export MOCK_HEAD
cd "$TMP/repo"

uuid="12345678-1234-1234-1234-123456789abc"

set +e
"$DONE" "$uuid" >"$TMP/missing.out" 2>"$TMP/missing.err"
rc=$?
set -e
[ "$rc" -eq 20 ] || fail "missing outcome returned $rc, expected 20"
[ ! -s "$TMP/task.log" ] || fail "missing outcome mutated the task"

set +e
"$DONE" "$uuid" --outcome invalid >"$TMP/invalid.out" 2>"$TMP/invalid.err"
rc=$?
set -e
[ "$rc" -eq 20 ] || fail "invalid outcome returned $rc, expected 20"
[ ! -s "$TMP/task.log" ] || fail "invalid outcome mutated the task"

"$DONE" "$uuid" --outcome merged >"$TMP/merged.out" 2>"$TMP/merged.err"
[ "$(cat "$TMP/status")" = completed ] || fail "task was not completed"
grep -Fq 'completed outcome=merged' "$TMP/task.log" \
  || fail "merged outcome annotation was not recorded"
grep -Fxq 'done' "$TMP/task.log" || fail "task done was not invoked"

printf 'pending\n' >"$TMP/status"
: >"$TMP/task.log"
git branch review/fixture HEAD
"$DONE" "$uuid" --outcome stacked >"$TMP/stacked.out" 2>"$TMP/stacked.err"
grep -Fq 'completed outcome=stacked' "$TMP/task.log" \
  || fail "stacked outcome annotation was not recorded"
git show-ref --verify --quiet refs/heads/review/fixture \
  || fail "stacked outcome removed the preserved branch"

printf 'pending\n' >"$TMP/status"
: >"$TMP/task.log"
git branch -D review/fixture >/dev/null
set +e
"$DONE" "$uuid" --outcome superseded >"$TMP/missing-branch.out" 2>"$TMP/missing-branch.err"
rc=$?
set -e
[ "$rc" -eq 20 ] || fail "missing preserved branch returned $rc, expected 20"
[ ! -s "$TMP/task.log" ] || fail "missing preserved branch mutated the task"

printf 'ok: dlc-done outcome and finalization tests\n'
