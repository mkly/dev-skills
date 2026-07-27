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

if [ "${1:-}" = export ]; then
  jq -n --arg base "$MOCK_BASE" '[{
    uuid: "12345678-1234-1234-1234-123456789abc",
    description: "fixture task",
    project: "demo.merge",
    status: "pending",
    annotations: [
      {description: ("base=" + $base)},
      {description: "branch=review/fixture"},
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

printf 'ok: dlc-merge clean integration tests\n'
