#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_RUN="$ROOT/scripts/dlc-test.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dlc-test-compact-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP/bin-rtk" "$TMP/bin-raw" "$TMP/repo"

cat >"$TMP/bin-rtk/crabbox" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  status|stop) exit 0 ;;
  run)
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
    [ "$#" -gt 0 ] && shift
    exec "$@"
    ;;
  *) exit 92 ;;
esac
EOF

cat >"$TMP/bin-rtk/rtk" <<'EOF'
#!/usr/bin/env bash
printf 'rtk-used\n' >>"$MOCK_RTK_MARKER"
[ "${1:-}" = test ] || exit 91
shift
exec "$@"
EOF

cat >"$TMP/bin-rtk/probe" <<'EOF'
#!/usr/bin/env bash
printf 'arg=%s\n' "$1"
exit 9
EOF

chmod +x "$TMP/bin-rtk/crabbox" "$TMP/bin-rtk/rtk" "$TMP/bin-rtk/probe"
ln -s "$TMP/bin-rtk/crabbox" "$TMP/bin-raw/crabbox"
ln -s "$TMP/bin-rtk/probe" "$TMP/bin-raw/probe"

git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.name test
git -C "$TMP/repo" config user.email test@example.invalid
printf 'base\n' >"$TMP/repo/file.txt"
git -C "$TMP/repo" add file.txt
git -C "$TMP/repo" commit -qm base
git -C "$TMP/repo" branch review/compact

export DLC_WORKTREE_DIR="$TMP/worktrees"
export MOCK_RTK_MARKER="$TMP/rtk.marker"

set +e
(
  cd "$TMP/repo"
  PATH="$TMP/bin-rtk:/usr/bin:/bin" "$TEST_RUN" review/compact --compact -- probe 'two words'
) >"$TMP/compact.out" 2>"$TMP/compact.err"
compact_rc=$?
set -e
[ "$compact_rc" -eq 9 ] || fail "compact review command exited $compact_rc, expected 9"
[ "$(<"$TMP/compact.out")" = 'arg=two words' ] || fail "compact review mode changed arguments"
[ "$(<"$TMP/rtk.marker")" = rtk-used ] || fail "compact review mode did not invoke in-box rtk test"

rm -f "$TMP/rtk.marker"
set +e
(
  cd "$TMP/repo"
  PATH="$TMP/bin-rtk:/usr/bin:/bin" "$TEST_RUN" review/compact -- probe 'plain mode'
) >"$TMP/plain.out" 2>"$TMP/plain.err"
plain_rc=$?
set -e
[ "$plain_rc" -eq 9 ] || fail "plain review command exited $plain_rc, expected 9"
[ "$(<"$TMP/plain.out")" = 'arg=plain mode' ] || fail "plain review mode changed arguments"
[ ! -e "$TMP/rtk.marker" ] || fail "plain review mode unexpectedly invoked rtk"

set +e
(
  cd "$TMP/repo"
  PATH="$TMP/bin-raw:/usr/bin:/bin" "$TEST_RUN" review/compact --compact -- probe 'raw fallback'
) >"$TMP/fallback.out" 2>"$TMP/fallback.err"
fallback_rc=$?
set -e
[ "$fallback_rc" -eq 9 ] || fail "review fallback exited $fallback_rc, expected 9"
[ "$(<"$TMP/fallback.out")" = 'arg=raw fallback' ] || fail "review fallback changed arguments"
[ ! -e "$TMP/rtk.marker" ] || fail "review fallback unexpectedly invoked rtk"
grep -Fq -- '--compact requested but rtk is unavailable in box; running unfiltered' "$TMP/fallback.err" \
  || fail "review fallback warning was not emitted"

printf 'ok: dlc-test compact mode and fallback tests\n'
