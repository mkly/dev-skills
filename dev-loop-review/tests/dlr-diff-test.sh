#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dlr-diff-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" \
    || fail "expected '$expected' in $file"
}

assert_matches() {
  local file="$1" pattern="$2"
  grep -Eq -- "$pattern" "$file" \
    || fail "expected pattern '$pattern' in $file"
}

mkdir -p "$TMP/bin" "$TMP/repo"
cat >"$TMP/bin/task" <<'EOF'
#!/usr/bin/env bash
if [ "${MOCK_TASK_MODE:-valid}" = fail ]; then
  printf 'simulated Taskwarrior export failure\n' >&2
  exit 2
fi
printf '%s\n' \
  "[{\"uuid\":\"12345678-1234-1234-1234-123456789abc\",\"description\":\"metadata regression fixture\",\"project\":\"dev-loop-skill\",\"status\":\"completed\",\"annotations\":[{\"description\":\"base=${MOCK_BASE}\"},{\"description\":\"branch=review/fixture\"}]}]"
EOF
chmod +x "$TMP/bin/task"

git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.name test
git -C "$TMP/repo" config user.email test@example.invalid
printf 'base\n' >"$TMP/repo/file.txt"
git -C "$TMP/repo" add file.txt
git -C "$TMP/repo" commit -qm base
base="$(git -C "$TMP/repo" rev-parse HEAD)"
git -C "$TMP/repo" switch -q -c review/fixture
printf 'review\n' >>"$TMP/repo/file.txt"
git -C "$TMP/repo" commit -qam review
git -C "$TMP/repo" switch -q -

(
  cd "$TMP/repo"
  PATH="$TMP/bin:$PATH" MOCK_BASE="$base" \
    "$ROOT/scripts/dlr-diff.sh" review/fixture >"$TMP/valid.out" 2>"$TMP/valid.err"
)
assert_contains "$TMP/valid.out" "### produced by task 12345678 — metadata regression fixture"
assert_contains "$TMP/valid.out" "### commits (${base}..review/fixture)"
assert_matches "$TMP/valid.out" '^[0-9a-f]+ review$'
assert_contains "$TMP/valid.out" "### files changed"
assert_matches "$TMP/valid.out" 'file\.txt +\| +1 +\+'
assert_contains "$TMP/valid.out" "### patch"
assert_contains "$TMP/valid.out" "+review"

set +e
(
  cd "$TMP/repo"
  PATH="$TMP/bin:$PATH" MOCK_TASK_MODE=fail MOCK_BASE="$base" \
    "$ROOT/scripts/dlr-diff.sh" review/fixture >"$TMP/fail.out" 2>"$TMP/fail.err"
)
rc=$?
set -e
[ "$rc" -eq 20 ] || fail "metadata export failure exited $rc, expected 20"
[ ! -s "$TMP/fail.out" ] || fail "metadata export failure wrote unexpected stdout"
assert_contains "$TMP/fail.err" \
  "failed to export Taskwarrior metadata while resolving producing task for branch 'review/fixture' (task exit 2)"

printf 'ok: dlr-diff metadata regression tests\n'
