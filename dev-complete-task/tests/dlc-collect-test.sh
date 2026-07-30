#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECT="$ROOT/scripts/dlc-collect.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dlc-collect-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP/bin" "$TMP/repo"
cat >"$TMP/bin/task" <<'EOF'
#!/usr/bin/env bash
payload="[
  {\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"description\":\"first loop\",\"project\":\"demo\",\"status\":\"pending\",\"annotations\":[
    {\"description\":\"branch=review/one\"},
    {\"description\":\"repo-id: github.com/acme/demo\"},
    {\"description\":\"goal: first\"},
    {\"description\":\"review-start=20260730T120000Z\"},
    {\"description\":\"reviewer=reviewer-a#100\"},
    {\"description\":\"loop-id: 11111111-1111-4111-8111-111111111111\"},
    {\"description\":\"loop-round: 1\"}]},
  {\"uuid\":\"22222222-2222-4222-8222-222222222222\",\"description\":\"second loop\",\"project\":\"demo\",\"status\":\"pending\",\"annotations\":[
    {\"description\":\"branch=review/two\"},
    {\"description\":\"repo-id: github.com/acme/demo\"},
    {\"description\":\"goal: second\"},
    {\"description\":\"loop-id: 22222222-2222-4222-8222-222222222222\"},
    {\"description\":\"loop-round: 1\"},
    {\"description\":\"input: review/one\"}]}
]"
case " $* " in
  *" 11111111-1111-4111-8111-111111111111 "*)
    printf '%s\n' "$payload" | jq '[.[] | select(.uuid == "11111111-1111-4111-8111-111111111111")]'
    ;;
  *) printf '%s\n' "$payload" ;;
esac
EOF
chmod +x "$TMP/bin/task"

git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.name fixture
git -C "$TMP/repo" config user.email fixture@example.test
git -C "$TMP/repo" remote add origin https://github.com/Acme/Demo.git
printf 'base\n' >"$TMP/repo/file.txt"
git -C "$TMP/repo" add file.txt
git -C "$TMP/repo" commit -qm base
for branch in one two orphan; do
  git -C "$TMP/repo" branch "review/$branch"
done

cd "$TMP/repo"
export PATH="$TMP/bin:$PATH"

all="$($COLLECT 2>"$TMP/all.err")"
printf '%s' "$all" | jq -e '
  length == 3 and any(.[]; .branch == "review/orphan" and .task == null)
' >/dev/null || fail "unfiltered collection lost branches or orphans"

scoped="$($COLLECT --from-task 11111111-1111-4111-8111-111111111111 \
  2>"$TMP/scoped.err")"
printf '%s' "$scoped" | jq -e '
  length == 1
  and .[0].branch == "review/one"
  and .[0].superseded == false
  and .[0].task.project == "demo"
  and .[0].task.repo_id == "github.com/acme/demo"
  and .[0].task.goal == "first"
  and .[0].task.loop_id == "11111111-1111-4111-8111-111111111111"
  and .[0].task.loop_round == "1"
  and .[0].task.reviewer == "reviewer-a#100"
  and .[0].task.review_started == "20260730T120000Z"
' >/dev/null || fail "project plus loop-id scoping was incorrect"

set +e
$COLLECT --project demo >"$TMP/invalid.out" 2>"$TMP/invalid.err"
rc=$?
set -e
[ "$rc" -eq 20 ] || fail "caller-supplied project exited $rc"
[ ! -s "$TMP/invalid.out" ] || fail "caller-supplied project wrote stdout"

printf 'ok: dlc-collect producer identity scoping tests\n'
