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
assert_error '--effort is not supported by agent qwen' --agent qwen --effort high
assert_error '--effort is not supported by agent devin' --agent devin --effort high
assert_error '--otel-endpoint requires a value' --agent codex --otel-endpoint
assert_error '--otel-endpoint requires a value' --agent codex --otel-endpoint ''
assert_error '--otel-endpoint requires an HTTP(S) base URL' --agent codex --otel-endpoint 'grpc://localhost:4317'
assert_error '--otel-endpoint requires an HTTP(S) base URL' --agent codex --otel-endpoint 'http://host/"bad'
assert_error '--otel-endpoint requires a base URL' --agent codex --otel-endpoint 'http://localhost:4318/v1/logs'
for selected_agent in agy devin; do
  assert_error "--otel-endpoint is not supported by agent $selected_agent" --agent "$selected_agent" --otel-endpoint http://localhost:4318
done

help="$($ROOT/loop --help)"
printf '%s\n' "$help" | grep -Fq -- '[--model <model>] [--effort <effort>]' || \
  fail 'help omits model and effort options'
printf '%s\n' "$help" | grep -Fq -- '<codex|claude|agy|qwen|devin|copilot>' || \
  fail 'help omits a supported agent'

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
for name in OTEL_RESOURCE_ATTRIBUTES OTEL_SDK_DISABLED OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_LOGS_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL OTEL_LOGS_EXPORTER CLAUDE_CODE_ENABLE_TELEMETRY QWEN_TELEMETRY_ENABLED COPILOT_OTEL_ENABLED COPILOT_OTEL_EXPORTER_TYPE COPILOT_OTEL_FILE_EXPORTER_PATH QWEN_TELEMETRY_OTLP_LOGS_ENDPOINT; do
  printf '%s=%s\n' "$name" "${!name-}" >>"$CAPTURE.env"
done
EOF
cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'rev-parse --is-inside-work-tree') echo true ;;
  'remote get-url origin') echo "${TEST_ORIGIN:-git@github.com:Example/Project-A.git}" ;;
  'rev-parse --path-format=absolute --git-common-dir') echo "$KNOWLEDGE_TEST_ROOT/.git" ;;
  'worktree list --porcelain -z') printf 'worktree %s\0HEAD fixture\0branch refs/heads/main\0\0' "$KNOWLEDGE_TEST_ROOT" ;;
  *) exit 1 ;;
esac
EOF
export KNOWLEDGE_TEST_ROOT="$TMP/project"
mkdir -p "$KNOWLEDGE_TEST_ROOT/.git"
chmod +x "$TMP/bin/"*
ln -s capture-agent "$TMP/bin/codex"
ln -s capture-agent "$TMP/bin/claude"
ln -s capture-agent "$TMP/bin/agy"
ln -s capture-agent "$TMP/bin/qwen"
ln -s capture-agent "$TMP/bin/devin"
ln -s capture-agent "$TMP/bin/copilot"

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

# A parent shell configured for a different project must not enable export or
# override the endpoint. Capture the actual launch environment without an LLM.
export OTEL_EXPORTER_OTLP_ENDPOINT=http://old-project:4318
export OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=http://old-project:4318/v1/logs
export QWEN_TELEMETRY_OTLP_LOGS_ENDPOINT=http://old-project:4318/v1/logs
export COPILOT_OTEL_FILE_EXPORTER_PATH=/tmp/old-project-otel
export CLAUDE_CODE_ENABLE_TELEMETRY=1 QWEN_TELEMETRY_ENABLED=true COPILOT_OTEL_ENABLED=true
for selected_agent in codex claude qwen copilot agy devin; do
  rm -f "$TMP/$selected_agent.args.env"
  run_and_capture "$selected_agent"
  grep -Fxq 'OTEL_SDK_DISABLED=true' "$TMP/$selected_agent.args.env" || fail "$selected_agent default exports enabled"
  grep -Fxq 'OTEL_EXPORTER_OTLP_ENDPOINT=' "$TMP/$selected_agent.args.env" || fail "$selected_agent inherited endpoint"
  grep -Fxq 'CLAUDE_CODE_ENABLE_TELEMETRY=0' "$TMP/$selected_agent.args.env" || fail 'claude telemetry opt-out missing'
  grep -Fxq 'QWEN_TELEMETRY_ENABLED=false' "$TMP/$selected_agent.args.env" || fail 'qwen telemetry opt-out missing'
  grep -Fxq 'COPILOT_OTEL_ENABLED=false' "$TMP/$selected_agent.args.env" || fail 'copilot telemetry opt-out missing'
  grep -Fxq 'COPILOT_OTEL_FILE_EXPORTER_PATH=' "$TMP/$selected_agent.args.env" || fail "$selected_agent inherited file export"
done
for exporter in exporter trace_exporter metrics_exporter; do
  grep -Fxq "otel.$exporter=\"none\"" "$TMP/codex.args" || fail "codex $exporter not disabled"
done
grep -Fxq -- '--no-telemetry' "$TMP/qwen.args" || fail 'qwen not explicitly disabled'
for selected_agent in codex claude qwen copilot; do
  rm -f "$TMP/$selected_agent.args.env"
  export OTEL_RESOURCE_ATTRIBUTES=team=platform,service.namespace=wrong,dev_loop.project=wrong,dev_loop.repository=wrong
  run_and_capture "$selected_agent" --otel-endpoint https://collector.example/project-a/
  grep -Fxq 'OTEL_SDK_DISABLED=false' "$TMP/$selected_agent.args.env" || fail "$selected_agent export disabled"
  grep -Fxq 'OTEL_EXPORTER_OTLP_ENDPOINT=https://collector.example/project-a' "$TMP/$selected_agent.args.env" || fail "$selected_agent wrong endpoint"
  grep -Fxq 'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=https://collector.example/project-a/v1/logs' "$TMP/$selected_agent.args.env" || fail "$selected_agent inherited signal endpoint"
  grep -Fxq 'OTEL_RESOURCE_ATTRIBUTES=team=platform,service.namespace=project-a,dev_loop.project=project-a,dev_loop.repository=github.com/example/project-a' "$TMP/$selected_agent.args.env" || fail "$selected_agent incorrect project identity"
done
grep -Fxq 'otel.exporter={otlp-http={endpoint="https://collector.example/project-a/v1/logs",protocol="binary"}}' "$TMP/codex.args" || fail 'codex log exporter incorrect'
grep -Fxq 'COPILOT_OTEL_EXPORTER_TYPE=otlp-http' "$TMP/copilot.args.env" || fail 'copilot file exporter not overridden'
grep -Fxq -- '--telemetry-outfile' "$TMP/qwen.args" || fail 'qwen file setting not overridden'
unset OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_LOGS_ENDPOINT QWEN_TELEMETRY_OTLP_LOGS_ENDPOINT COPILOT_OTEL_FILE_EXPORTER_PATH
unset CLAUDE_CODE_ENABLE_TELEMETRY QWEN_TELEMETRY_ENABLED COPILOT_OTEL_ENABLED
unset OTEL_RESOURCE_ATTRIBUTES
for TEST_ORIGIN in https://github.com/Other/Project-B.git/ ssh://git@github.com/Other/Project-B.git; do
  export TEST_ORIGIN
  rm -f "$TMP/claude.args.env"
  run_and_capture claude --otel-endpoint http://localhost:4318
  grep -Fxq 'OTEL_RESOURCE_ATTRIBUTES=service.namespace=project-b,dev_loop.project=project-b,dev_loop.repository=github.com/other/project-b' "$TMP/claude.args.env" || fail 'project identity differs by origin format'
done
unset TEST_ORIGIN
PATH="$TMP/bin:$PATH" TEST_ORIGIN=https://gitlab.com/Other/Project.git \
  assert_error 'origin must be a GitHub repository URL' --agent claude --otel-endpoint http://localhost:4318
run_and_capture claude --otel-endpoint 'http://[::1]:4318'
grep -Fxq 'OTEL_EXPORTER_OTLP_ENDPOINT=http://[::1]:4318' "$TMP/claude.args.env" || fail 'IPv6 collector rejected'

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

# qwen is checked apart from the loop above because it takes --model but has no
# effort control at all. Its prompt is delivered interactively, so the worker
# stays resident and only dl-finish.sh's kill ends the run.
run_and_capture qwen --model qwen-test
grep -Fxq -- '--model' "$TMP/qwen.args" || fail 'qwen model flag not forwarded'
grep -Fxq -- 'qwen-test' "$TMP/qwen.args" || fail 'qwen model value not forwarded'
grep -Fxq -- '--yolo' "$TMP/qwen.args" || fail 'qwen was not launched in yolo mode'
grep -Fxq -- '--prompt-interactive' "$TMP/qwen.args" || \
  fail 'qwen prompt was not delivered interactively'
if grep -Fxq -- '--effort' "$TMP/qwen.args"; then
  fail 'qwen was handed an effort flag it cannot honor'
fi

run_and_capture devin --model devin-test
grep -Fxq -- '--model' "$TMP/devin.args" || fail 'devin model flag not forwarded'
grep -Fxq -- 'devin-test' "$TMP/devin.args" || fail 'devin model value not forwarded'
grep -Fxq -- '--permission-mode' "$TMP/devin.args" || \
  fail 'devin permission mode not configured'
grep -Fxq -- 'dangerous' "$TMP/devin.args" || \
  fail 'devin was not launched unattended'
grep -Fxq -- '--respect-workspace-trust' "$TMP/devin.args" || \
  fail 'devin workspace trust was not configured for print mode'
grep -Fxq -- 'false' "$TMP/devin.args" || \
  fail 'devin print mode can still block on workspace trust'
grep -Fxq -- '-p' "$TMP/devin.args" || fail 'devin was not launched in print mode'

run_and_capture copilot --model copilot-test --effort high
grep -Fxq -- '--model' "$TMP/copilot.args" || fail 'copilot model flag not forwarded'
grep -Fxq -- 'copilot-test' "$TMP/copilot.args" || fail 'copilot model value not forwarded'
grep -Fxq -- '--effort' "$TMP/copilot.args" || fail 'copilot effort flag not forwarded'
grep -Fxq -- 'high' "$TMP/copilot.args" || fail 'copilot effort value not forwarded'
grep -Fxq -- '--allow-all' "$TMP/copilot.args" || \
  fail 'copilot was not launched unattended'
grep -Fxq -- '--no-ask-user' "$TMP/copilot.args" || \
  fail 'copilot can still block on an agent question'
grep -Fxq -- '-p' "$TMP/copilot.args" || \
  fail 'copilot was not launched in prompt mode'

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
