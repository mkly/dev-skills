#!/usr/bin/env bash
# Local lifecycle works without provider tools; remote routes remain explicit.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMPL="$ROOT/dev-implement-task/scripts"
COMPLETE="$ROOT/dev-complete-task/scripts"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-local-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_rc() {
  local expected="$1" rc=0; shift
  "$@" >"$TMP/command.out" 2>"$TMP/command.err" || rc=$?
  [ "$rc" -eq "$expected" ] || fail "expected exit $expected, got $rc: $(cat "$TMP/command.err")"
}

mkdir -p "$TMP/bin" "$TMP/taskdata" "$TMP/config" "$TMP/repo"
ln -s "$(command -v task)" "$TMP/bin/task"
for tool in bash sh env git jq flock dirname basename mktemp mkdir rm cp mv cat \
  sed grep head tail sort cut cksum date hostname id od tr sleep python3 awk wc \
  touch cmp true tee chmod; do
  ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
done
export PATH="$TMP/bin"
export TASKRC="$TMP/taskrc" TASKDATA="$TMP/taskdata" XDG_CONFIG_HOME="$TMP/config"
export DEV_LOOP_STATE_DIR="$TMP/state" DLC_STATE_DIR="$TMP/review-state"
export DEV_LOOP_OWNER=local-test DEV_LOOP_TITLE=off DEV_BOARD_DISABLE=1
export CRABBOX_PROVIDER="" DEV_LOOP_BOX_SCOPE=""
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset AGENT_PID AGENT_NOTIFY DL_DRY_RUN DEV_LOOP_ROUTE
: >"$TASKRC"
tw() { task rc.confirmation=no rc.verbose=nothing "$@"; }
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.name test
git -C "$TMP/repo" config user.email test@example.invalid
git -C "$TMP/repo" remote add origin https://github.com/example-org/local-test.git
printf 'base\n' >"$TMP/repo/file.txt"
git -C "$TMP/repo" add file.txt
git -C "$TMP/repo" commit -qm base
cd "$TMP/repo"

new_task() {
  "$ROOT/dev-create-tasks/scripts/dct-create.sh" --goal execution \
    --loop-id 11111111-1111-4111-8111-111111111111 \
    --description "$1" --acceptance 'commands run in the selected environment' 2>>"$TMP/create.err"
}

[ -z "$(command -v crabbox || true)" ] || fail "fixture unexpectedly has Crabbox"
[ -z "$(command -v incus || true)" ] || fail "fixture unexpectedly has Incus"
"$IMPL/dl-setup.sh" >"$TMP/setup.out" 2>"$TMP/setup.err"
uuid="$(new_task 'local work')"
"$IMPL/dl-claim.sh" "$uuid" >"$TMP/claim.out" 2>"$TMP/claim.err"
wt="$("$IMPL/dl-box.sh" "$uuid" 2>"$TMP/box.err")"
[ -d "$wt" ] && [ "$wt" != "$PWD" ] || fail "local task did not get a separate worktree"
tw "$uuid" export | jq -e --arg wt "$wt" '
  [.[0].annotations[].description] as $a
  | ($a | index("executor=local")) != null
    and ($a | index("worktree=" + $wt)) != null
    and ([$a[] | select(startswith("box="))] | length) == 0
' >/dev/null || fail "local preparation recorded a remote lease"

printf 'local untracked input\n' >"$wt/untracked.txt"
expect_rc 7 "$IMPL/dl-run.sh" "$uuid" -- sh -c \
  'printf "%s\n%s\n%s\n" "$PWD" "$1" "$2"; cat untracked.txt; exit 7' \
  fixture 'two words' 'literal;$()'
printf '%s\n' "$wt" 'two words' 'literal;$()' 'local untracked input' >"$TMP/expected"
cmp -s "$TMP/expected" "$TMP/command.out" || fail "local command changed cwd, argv, or file visibility"

cat >"$TMP/bin/rtk" <<'EOF'
#!/usr/bin/env bash
[ "$1" = test ] || exit 91
shift
exec sh -c "$*"
EOF
chmod +x "$TMP/bin/rtk"
expect_rc 7 "$IMPL/dl-run.sh" "$uuid" --compact -- sh -c 'printf "<%s>\n" "$1"; exit 7' fixture 'two words'
[ "$(cat "$TMP/command.out")" = '<two words>' ] || fail "local compact mode changed argv"
expect_rc 0 "$IMPL/dl-run.sh" "$uuid" -sync-only --
expect_rc 20 "$IMPL/dl-run.sh" "$uuid" -allow-env TOKEN -- true
expect_rc 0 "$IMPL/dl-run.sh" "$uuid" --dry-run -- sh -c 'touch should-not-exist'
[ ! -e "$wt/should-not-exist" ] || fail "dry-run executed the local command"
"$IMPL/dl-status.sh" >"$TMP/status.out"
grep -Fq 'Live leases: skipped (local execution)' "$TMP/status.out" || fail "local status queried providers"

"$IMPL/dl-release.sh" "$uuid" --stop-box >"$TMP/release.out" 2>"$TMP/release.err"
"$IMPL/dl-claim.sh" "$uuid" >"$TMP/reclaim.out" 2>"$TMP/reclaim.err"
[ "$("$IMPL/dl-box.sh" "$uuid" 2>"$TMP/rebox.err")" = "$wt" ] || fail "local re-claim replaced the worktree"
printf 'changed\n' >"$wt/file.txt"
rm "$wt/untracked.txt"
branch="$("$IMPL/dl-merge-back.sh" "$uuid" --summary 'local execution checked' 2>"$TMP/snapshot.err")"
"$COMPLETE/dlc-claim.sh" "$uuid" >"$TMP/reviewer.out" 2>"$TMP/reviewer.err"
expect_rc 9 "$COMPLETE/dlc-test.sh" "$branch" --compact -- sh -c \
  'test "$(cat file.txt)" = changed || exit 90; printf "%s\n" "$PWD"; exit 9'
review_wt="$(cat "$TMP/command.out")"
[ "$review_wt" != "$wt" ] && [ "$review_wt" != "$PWD" ] || fail "review shared an implementation checkout"
"$COMPLETE/dlc-test.sh" "$branch" --dry-run -- sh -c 'touch should-not-exist' >"$TMP/review-dry.out" 2>"$TMP/review-dry.err"
[ ! -e "$review_wt/should-not-exist" ] || fail "review dry-run executed a command"
"$COMPLETE/dlc-merge.sh" "$branch" >"$TMP/merge.out" 2>"$TMP/merge.err"
"$COMPLETE/dlc-done.sh" "$uuid" --outcome merged --stop-box >"$TMP/done.out" 2>"$TMP/done.err"
[ ! -d "$wt" ] || fail "local completion left the implementation worktree"
[ ! -d "$review_wt" ] || fail "merge left the verification worktree"
[ "$(tw "$uuid" export | jq -r '.[0].status')" = completed ] || fail "local completion left the task pending"

# Having provider tools installed must not enable them implicitly.
export MOCK_CRABBOX_LOG="$TMP/crabbox.log" MOCK_CRABBOX_STATE="$TMP/crabbox.state"
cat >"$TMP/bin/crabbox" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
provider=""
slug=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -provider) provider="$2"; shift 2 ;;
    -slug) slug="$2"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$cmd" "$provider" >>"$MOCK_CRABBOX_LOG"
[ "$provider" = sprites ] || exit 81
case "$cmd" in
  doctor) exit 0 ;;
  warmup) printf '%s\n' "$slug" >"$MOCK_CRABBOX_STATE"; printf 'leased cbx_mock\n' ;;
  status) test -f "$MOCK_CRABBOX_STATE"; printf '{"labels":{}}\n' ;;
  run) if [ "$#" -gt 0 ]; then exec "$@"; fi ;;
  stop) rm -f "$MOCK_CRABBOX_STATE" ;;
  *) exit 82 ;;
esac
EOF
cat >"$TMP/bin/incus" <<'EOF'
#!/usr/bin/env bash
printf 'incus unexpectedly called\n' >&2
exit 83
EOF
chmod +x "$TMP/bin/crabbox" "$TMP/bin/incus"
printf 'provider: sprites\n' >crabbox.yaml
unset CRABBOX_PROVIDER
"$IMPL/dl-setup.sh" >"$TMP/local-tools.out" 2>"$TMP/local-tools.err"
[ ! -e "$MOCK_CRABBOX_LOG" ] || fail "installed Crabbox or repo config implicitly enabled remote mode"
rm crabbox.yaml

remote="$(new_task 'remote work')"
"$IMPL/dl-claim.sh" "$remote" >"$TMP/remote-claim.out" 2>"$TMP/remote-claim.err"
remote_handle="$(CRABBOX_PROVIDER=sprites "$IMPL/dl-box.sh" "$remote" 2>"$TMP/remote-box.err")"
[ "$remote_handle" = cbx_mock ] || fail "remote warmup did not return its canonical handle"
tw "$remote" export | jq -e '[.[0].annotations[].description] | index("box-provider=sprites") != null' >/dev/null \
  || fail "remote preparation did not retain its provider"
expect_rc 7 env CRABBOX_PROVIDER=other "$IMPL/dl-run.sh" "$remote" -- sh -c 'exit 7'
"$IMPL/dl-release.sh" "$remote" --stop-box >"$TMP/remote-release.out" 2>"$TMP/remote-release.err"
grep -Fxq 'run sprites' "$MOCK_CRABBOX_LOG" || fail "handoff did not run with the saved provider"
grep -Fxq 'stop sprites' "$MOCK_CRABBOX_LOG" || fail "local worker did not release the saved remote provider"

# A selected provider failure never executes the workload locally.
broken="$(new_task 'broken provider')"
"$IMPL/dl-claim.sh" "$broken" >"$TMP/broken-claim.out" 2>"$TMP/broken-claim.err"
expect_rc 20 env CRABBOX_PROVIDER=broken "$IMPL/dl-box.sh" "$broken"
expect_rc 20 "$IMPL/dl-run.sh" "$broken" -- sh -c 'touch forbidden-fallback'
expect_rc 20 env CRABBOX_PROVIDER=broken "$IMPL/dl-setup.sh"

# Parked pools cannot cross providers or operator-selected scopes.
. "$IMPL/dl-common.sh"
CRABBOX_PROVIDER=sprites; sprites_slot="$(dl_idle_box_file)"
CRABBOX_PROVIDER=incus; incus_slot="$(dl_idle_box_file)"
DEV_LOOP_BOX_SCOPE=second-account; scoped_slot="$(dl_idle_box_file)"
[ "$sprites_slot" != "$incus_slot" ] && [ "$incus_slot" != "$scoped_slot" ] \
  || fail "parked lease namespaces collided"
printf 'ok: local lifecycle, optional provider tooling, and saved remote routes\n'
