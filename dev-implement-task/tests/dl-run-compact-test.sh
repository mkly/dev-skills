#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/dl-run.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-run-compact-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP/bin-rtk" "$TMP/bin-raw" "$TMP/worktree"

cat >"$TMP/bin-rtk/task" <<'EOF'
#!/usr/bin/env bash
printf '[{"uuid":"%s","project":"demo.compact","assignee":"%s#nonce","annotations":[{"description":"box=mock-box"},{"description":"worktree=%s"}]}]\n' \
  "$MOCK_UUID" "$DEV_LOOP_OWNER" "$MOCK_WORKTREE"
EOF

cat >"$TMP/bin-rtk/crabbox" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
[ "$#" -gt 0 ] && shift
exec "$@"
EOF

cat >"$TMP/bin-rtk/rtk" <<'EOF'
#!/usr/bin/env bash
printf 'rtk-used\n' >>"$MOCK_RTK_MARKER"
[ "${1:-}" = test ] || exit 91
shift
# Match RTK's command reconstruction closely enough to expose argv-boundary
# loss when callers pass a multi-argument command directly.
exec sh -c "$*"
EOF

cat >"$TMP/bin-rtk/probe" <<'EOF'
#!/usr/bin/env bash
printf '<%s>\n' "$@"
exit 7
EOF

chmod +x "$TMP/bin-rtk/task" "$TMP/bin-rtk/crabbox" "$TMP/bin-rtk/rtk" "$TMP/bin-rtk/probe"
ln -s "$TMP/bin-rtk/task" "$TMP/bin-raw/task"
ln -s "$TMP/bin-rtk/crabbox" "$TMP/bin-raw/crabbox"
ln -s "$TMP/bin-rtk/probe" "$TMP/bin-raw/probe"

export MOCK_UUID=12345678-1234-1234-1234-123456789abc
export MOCK_WORKTREE="$TMP/worktree"
export MOCK_RTK_MARKER="$TMP/rtk.marker"
export DEV_LOOP_OWNER=compact-test

cat >"$TMP/expected.args" <<'EOF'
<normal>
<two words>
<>
<'single' and "double">
<(left right)>
<literal;$*?[]&|<>>
EOF

argv=(normal 'two words' '' "'single' and \"double\"" '(left right)' 'literal;$*?[]&|<>')

set +e
PATH="$TMP/bin-rtk:/usr/bin:/bin" "$RUN" "$MOCK_UUID" --compact -- probe "${argv[@]}" \
  >"$TMP/compact.out" 2>"$TMP/compact.err"
compact_rc=$?
set -e
[ "$compact_rc" -eq 7 ] || fail "compact command exited $compact_rc, expected 7"
cmp -s "$TMP/expected.args" "$TMP/compact.out" || fail "compact mode changed command arguments"
[ "$(<"$TMP/rtk.marker")" = rtk-used ] || fail "compact mode did not invoke in-box rtk test"

rm -f "$TMP/rtk.marker"
set +e
PATH="$TMP/bin-rtk:/usr/bin:/bin" "$RUN" "$MOCK_UUID" -- probe "${argv[@]}" \
  >"$TMP/plain.out" 2>"$TMP/plain.err"
plain_rc=$?
set -e
[ "$plain_rc" -eq 7 ] || fail "plain command exited $plain_rc, expected 7"
cmp -s "$TMP/expected.args" "$TMP/plain.out" || fail "plain mode changed command arguments"
[ ! -e "$TMP/rtk.marker" ] || fail "plain mode unexpectedly invoked rtk"

set +e
PATH="$TMP/bin-raw:/usr/bin:/bin" "$RUN" "$MOCK_UUID" --compact -- probe 'raw fallback' \
  >"$TMP/fallback.out" 2>"$TMP/fallback.err"
fallback_rc=$?
set -e
[ "$fallback_rc" -eq 7 ] || fail "fallback command exited $fallback_rc, expected 7"
[ "$(<"$TMP/fallback.out")" = '<raw fallback>' ] || fail "fallback changed command arguments"
[ ! -e "$TMP/rtk.marker" ] || fail "fallback unexpectedly invoked rtk"
grep -Fq -- '--compact requested but rtk is unavailable in box; running unfiltered' "$TMP/fallback.err" \
  || fail "fallback warning was not emitted"

set +e
PATH="$TMP/bin-raw:/usr/bin:/bin" "$RUN" "$MOCK_UUID" --compact -sync-only -- \
  >"$TMP/sync.out" 2>"$TMP/sync.err"
sync_rc=$?
set -e
[ "$sync_rc" -eq 20 ] || fail "compact sync-only exited $sync_rc, expected 20"
grep -Fq -- '--compact cannot be combined with -sync-only' "$TMP/sync.err" \
  || fail "compact sync-only rejection was not explained"

printf 'ok: dl-run compact mode and fallback tests\n'
