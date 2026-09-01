#!/usr/bin/env bash

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_error() {
  expected="$1"
  shift
  set +e
  "$ROOT/loop" "$@" >"$TMP/error.out" 2>"$TMP/error.err"
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "expected exit 2, got $status: $*"
  grep -Fq -- "$expected" "$TMP/error.err" || \
    fail "missing error '$expected': $*"
}

assert_error '--model requires a value' --agent codex --model
assert_error '--effort requires a value' --agent codex --effort --small
assert_error '--standard, --small, --large, and --plan are mutually exclusive' \
  --agent codex --model gpt-test --small --large
assert_error '--standard, --small, --large, and --plan are mutually exclusive' \
  --agent codex --model gpt-test --standard --plan
assert_error 'unknown argument: --no-small' --agent codex --no-small

help="$($ROOT/loop --help)"
printf '%s\n' "$help" | grep -Fq -- '[--model <model>] [--effort <effort>]' || \
  fail 'help omits model and effort options'

mkdir "$TMP/bin"
cat >"$TMP/bin/task" <<'EOF'
#!/usr/bin/env bash
printf '1\n'
EOF
cat >"$TMP/bin/jq" <<'EOF'
#!/usr/bin/env bash
cat
EOF
cat >"$TMP/bin/capture-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CAPTURE"
EOF
chmod +x "$TMP/bin/"*
ln -s capture-agent "$TMP/bin/codex"
ln -s capture-agent "$TMP/bin/claude"
ln -s capture-agent "$TMP/bin/agy"

run_and_capture() {
  selected_agent="$1"
  shift
  timeout 1s env CAPTURE="$TMP/$selected_agent.args" PATH="$TMP/bin:$PATH" \
    "$ROOT/loop" --agent "$selected_agent" "$@" >/dev/null 2>&1 || true
}

run_and_capture codex --model gpt-test --effort high
grep -Fxq -- '--model' "$TMP/codex.args" || fail 'codex model flag not forwarded'
grep -Fxq -- 'gpt-test' "$TMP/codex.args" || fail 'codex model value not forwarded'
grep -Fxq -- '--config' "$TMP/codex.args" || fail 'codex effort config not forwarded'
grep -Fxq -- 'model_reasoning_effort=high' "$TMP/codex.args" || \
  fail 'codex effort value not forwarded'

for selected_agent in claude agy; do
  run_and_capture "$selected_agent" --model model-test --effort medium
  grep -Fxq -- '--model' "$TMP/$selected_agent.args" || \
    fail "$selected_agent model flag not forwarded"
  grep -Fxq -- 'model-test' "$TMP/$selected_agent.args" || \
    fail "$selected_agent model value not forwarded"
  grep -Fxq -- '--effort' "$TMP/$selected_agent.args" || \
    fail "$selected_agent effort flag not forwarded"
  grep -Fxq -- 'medium' "$TMP/$selected_agent.args" || \
    fail "$selected_agent effort value not forwarded"
done

# A task another worker holds mid-implementation is neither claimable (it is
# +ACTIVE and assigned) nor review-ready (no branch=/summary: yet). The default
# route must not count it, or the poll relaunches an agent that can do nothing
# with it every 5 seconds.
mkdir "$TMP/held"
cat >"$TMP/held/task" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    -ACTIVE) printf '[]\n'; exit 0 ;;
  esac
done
printf '[{"uuid":"11111111-1111-1111-1111-111111111111","status":"pending",'
printf '"assignee":"someone@host/worker-beef#4242","start":"20260808T000000Z",'
printf '"annotations":[{"description":"goal: thing"}]}]\n'
EOF
cat >"$TMP/held/capture-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CAPTURE"
EOF
chmod +x "$TMP/held/"*
ln -s capture-agent "$TMP/held/codex"

timeout 1s env CAPTURE="$TMP/held.args" PATH="$TMP/held:$PATH" \
  "$ROOT/loop" --agent codex >"$TMP/held.out" 2>&1 || true

[ ! -e "$TMP/held.args" ] || \
  fail 'default route launched an agent for a task held by another worker'
grep -Fq 'No pending standard-queue tasks' "$TMP/held.out" || \
  fail 'default route did not report an empty queue for a held task'

# A finished review branch whose summary was recorded as `summary=` instead of
# `summary: ` is invisible to every reader of the review-ready predicate. The
# poll must still report it, or the queue looks merely empty while a completed
# task sits unreviewable.
mkdir "$TMP/misfiled"
cat >"$TMP/misfiled/task" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    -ACTIVE) printf '[]\n'; exit 0 ;;
  esac
done
printf '[{"uuid":"22222222-2222-2222-2222-222222222222","status":"pending",'
printf '"start":"20260901T000000Z","annotations":['
printf '{"description":"branch=review/dl-22222222-thing"},'
printf '{"description":"summary=did the thing"}]}]\n'
EOF
cat >"$TMP/misfiled/capture-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CAPTURE"
EOF
chmod +x "$TMP/misfiled/"*
ln -s capture-agent "$TMP/misfiled/claude"

timeout 1s env CAPTURE="$TMP/misfiled.args" PATH="$TMP/misfiled:$PATH" \
  "$ROOT/loop" --agent claude --complete-task >"$TMP/misfiled.out" 2>&1 || true

[ ! -e "$TMP/misfiled.args" ] || \
  fail 'complete route launched an agent for a task with a misfiled summary'
grep -Fq 'recorded summary= instead' "$TMP/misfiled.out" || \
  fail 'complete route did not report the misfiled summary'

# The same fixture with a well-formed note is review-ready and must launch.
sed 's/summary=did the thing/summary: did the thing/' \
  "$TMP/misfiled/task" >"$TMP/misfiled/task.ok"
mv "$TMP/misfiled/task.ok" "$TMP/misfiled/task"
chmod +x "$TMP/misfiled/task"
timeout 1s env CAPTURE="$TMP/wellformed.args" PATH="$TMP/misfiled:$PATH" \
  "$ROOT/loop" --agent claude --complete-task >"$TMP/wellformed.out" 2>&1 || true
[ -e "$TMP/wellformed.args" ] || \
  fail 'complete route ignored a review-ready task with a summary: note'

printf 'loop-test: ok\n'
