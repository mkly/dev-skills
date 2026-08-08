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

printf 'loop-test: ok\n'
