#!/usr/bin/env bash

set -eu

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
umask 077

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v notmuch >/dev/null 2>&1 || fail 'notmuch is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'

archive="$ROOT/archive"
project_key='github.com-mkly-dev-skills'
board='DECISIONS'
project_dir="$archive/projects/$project_key"
board_maildir="$project_dir/boards/$board"
mkdir -p "$board_maildir/tmp" "$board_maildir/new" "$board_maildir/cur"

task_uuid='ad1eaa54-d814-4376-af20-051c8dd027db'
loop_id='fc362e9f-074c-400f-bb5a-1c541438d4bd'

post() {
  article_id="$1"
  article_subject="$2"
  article_date="$3"
  parent_id="$4"
  references="$5"
  article_body="$6"

  draft="$(mktemp "$board_maildir/tmp/article.XXXXXX")"
  {
    printf 'From: test-author <test-author@agents.invalid>\n'
    printf 'Subject: %s\n' "$article_subject"
    printf 'Date: %s\n' "$article_date"
    printf 'Message-ID: %s\n' "$article_id"
    printf 'Newsgroups: %s\n' "$board"
    if [ -n "$parent_id" ]; then
      printf 'In-Reply-To: %s\n' "$parent_id"
      printf 'References: %s\n' "$references"
    fi
    printf 'X-Dev-Task: %s\n' "$task_uuid"
    printf 'X-Dev-Loop: %s\n' "$loop_id"
    printf '\n%s\n' "$article_body"
  } >"$draft"
  mv "$draft" "$board_maildir/new/$(basename "$draft")"
}

root_id='<root-retry-policy@dev-board.invalid>'
approve_id='<approve-retry-policy@dev-board.invalid>'
reject_id='<reject-retry-policy@dev-board.invalid>'
resolution_id='<resolve-retry-policy@dev-board.invalid>'

post "$root_id" 'Retry policy' 'Fri, 07 Aug 2026 17:00:00 -0700' '' '' \
  'Should failed deployments retry automatically?'
post "$approve_id" 'Re: Retry policy' 'Fri, 07 Aug 2026 17:01:00 -0700' \
  "$root_id" "$root_id" 'Yes: retry once after a transient failure.'
post "$reject_id" 'Re: Retry policy' 'Fri, 07 Aug 2026 17:02:00 -0700' \
  "$root_id" "$root_id" 'No: retries can duplicate destructive work.'
post "$resolution_id" 'Re: Retry policy' 'Fri, 07 Aug 2026 17:03:00 -0700' \
  "$reject_id" "$root_id $reject_id" \
  'Resolution: retry only operations proven idempotent.'

[ ! -d "$project_dir/agents" ] || fail 'per-agent Maildir tier exists'
[ -z "$(find "$board_maildir/tmp" -type f -print -quit)" ] || \
  fail 'temporary article remained after delivery'
[ -z "$(find "$board_maildir/cur" -type f -print -quit)" ] || \
  fail 'archive article was moved to cur'
[ "$(find "$board_maildir/new" -type f | wc -l)" -eq 4 ] || \
  fail 'shared archive does not contain exactly four articles'

before="$ROOT/before.sha256"
find "$board_maildir/new" -type f -print0 | sort -z | xargs -0 sha256sum >"$before"

config="$ROOT/notmuch-config"
database="$ROOT/notmuch-database"
cat >"$config" <<EOF
[database]
path=$database
mail_root=$archive

[user]
name=Dev Board Test
primary_email=test-author@agents.invalid

[new]
tags=archive
ignore=

[maildir]
synchronize_flags=false
EOF

export NOTMUCH_CONFIG="$config"
notmuch new >/dev/null

thread_query="$(notmuch search --output=threads 'subject:"Retry policy"')"
[ -n "$thread_query" ] || fail 'notmuch search found no discussion'
[ "$(printf '%s\n' "$thread_query" | wc -l)" -eq 1 ] || \
  fail 'articles were not grouped into one thread'

thread_json="$ROOT/thread.json"
notmuch show --entire-thread --format=json "$thread_query" >"$thread_json"
jq -e '
  .[0][0] as $root
  | ($root[1] | length) == 2
    and ([$root[1][] | (.[1] | length)] | sort == [0, 1])
' "$thread_json" >/dev/null || \
  fail 'JSON does not contain a root with two children and one nested reply'

after="$ROOT/after.sha256"
find "$board_maildir/new" -type f -print0 | sort -z | xargs -0 sha256sum >"$after"
cmp -s "$before" "$after" || fail 'reading mutated an archived article'

state_file="$(find "$archive" -type f \
  ! -path "$board_maildir/tmp/*" \
  ! -path "$board_maildir/new/*" \
  ! -path "$board_maildir/cur/*" -print -quit)"
[ -z "$state_file" ] || fail "per-reader state file exists in archive: $state_file"
[ ! -e "$archive/.notmuch" ] || fail 'notmuch database was stored in archive'

# --- the scripts, on a machine that has never configured notmuch -------------
#
# The section above hand-writes a working notmuch config, which is exactly why it
# could not catch the failure that made agents abandon the board: on a real
# worker there is no such config, `notmuch new` fails with "cannot load config
# file", and the first board command an agent runs errors out. Everything below
# runs with a HOME that contains nothing at all.

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
post_sh="$skill_dir/dev-board/scripts/db-post.sh"
search_sh="$skill_dir/dev-board/scripts/db-search.sh"
[ -x "$post_sh" ] || fail 'db-post.sh is not executable'
[ -x "$search_sh" ] || fail 'db-search.sh is not executable'

command -v git >/dev/null 2>&1 || fail 'git is required'

# The project key is derived from the checkout, so the test needs a checkout.
checkout="$ROOT/checkout"
mkdir -p "$checkout"
git -C "$checkout" init -q
git -C "$checkout" remote add origin 'git@github.com:mkly/board-under-test.git'

virgin_home="$ROOT/virgin-home"
mkdir -p "$virgin_home"
script_archive="$virgin_home/.local/state/dev-board"
index_dir="$virgin_home/.local/state/dev-board-index"

# NOTMUCH_CONFIG is unset, not merely repointed: an inherited value is one of the
# things the scripts have to cope with, and its absence is the failing case.
board_run() {
  ( cd "$checkout" \
    && env -u NOTMUCH_CONFIG -u XDG_STATE_HOME -u XDG_CONFIG_HOME \
      -u DEV_BOARD_ROOT -u DEV_BOARD_INDEX_DIR -u DEV_BOARD_NAME \
      HOME="$virgin_home" DEV_LOOP_OWNER='tester@host/worker-0badcafe' "$@" )
}

board_run "$search_sh" >/dev/null 2>&1 || \
  fail 'searching an empty board on an unconfigured HOME did not exit 0'

[ -f "$index_dir/notmuch-config" ] || \
  fail 'db-search.sh did not write a managed notmuch config'
grep -q '^mail_root=' "$index_dir/notmuch-config" || \
  fail 'managed notmuch config has no mail_root'
grep -q 'header.DEVTASK=X-Dev-Task' "$index_dir/notmuch-config" || \
  fail 'managed notmuch config does not index X-Dev-Task'

script_board="$script_archive/projects/github.com-mkly-board-under-test/boards/general"
[ -d "$script_board/new" ] || \
  fail "derived board was not created at $script_board"

# A config the scripts did not write is never overwritten: a personal notmuch
# configuration is not this skill's to rewrite.
personal="$ROOT/personal-notmuch-config"
printf '[database]\npath=%s\n' "$ROOT/personal-db" >"$personal"
personal_before="$(sha256sum "$personal" | cut -d' ' -f1)"
board_run env DEV_BOARD_INDEX_DIR="$ROOT/personal-index" \
  sh -c "mkdir -p '$ROOT/personal-index' && cp '$personal' '$ROOT/personal-index/notmuch-config' && exec \"\$@\"" _ \
  "$search_sh" >/dev/null 2>&1 && \
  fail 'db-search.sh proceeded with an unmanaged notmuch config in its index dir'
[ "$(sha256sum "$ROOT/personal-index/notmuch-config" | cut -d' ' -f1)" = "$personal_before" ] || \
  fail 'db-search.sh overwrote a notmuch config it did not write'

script_root_id="$(board_run "$post_sh" --subject 'Incus warmup times out' \
  --task "$task_uuid" --loop "$loop_id" --body-text 'Cold image pull exceeds the warmup budget.')"
case "$script_root_id" in
  \<*@*\>) ;;
  *) fail "db-post.sh did not print a bracketed Message-ID: $script_root_id" ;;
esac

script_reply_id="$(board_run "$post_sh" --subject 'Re: Incus warmup times out' \
  --parent "$script_root_id" --task "$task_uuid" \
  --body-text 'Raising the budget to 300s clears it.')"

script_leaf_id="$(board_run "$post_sh" --subject 'Re: Incus warmup times out' \
  --parent "$script_reply_id" --body-text 'Confirmed on a second host.')"

# References is the parent's ancestry plus the parent, thread root first: the
# ordering the caller no longer has to track, and the one notmuch threads on.
leaf_file="$(grep -rl "^Message-ID: $script_leaf_id\$" "$script_board/new")"
[ -n "$leaf_file" ] || fail 'delivered article is not in new'
leaf_refs="$(awk '/^References:/{sub(/^References:[[:space:]]*/,"");print;exit}' "$leaf_file")"
[ "$leaf_refs" = "$script_root_id $script_reply_id" ] || \
  fail "References ancestry is wrong: $leaf_refs"

[ -z "$(find "$script_board/tmp" -type f -print -quit)" ] || \
  fail 'db-post.sh left a draft in tmp'
[ -z "$(find "$script_board/cur" -type f -print -quit)" ] || \
  fail 'db-post.sh delivered into cur'
[ "$(find "$script_board/new" -type f | wc -l)" -eq 3 ] || \
  fail 'board does not contain exactly the three posted articles'

# The database is derived state and belongs outside the archive, so that dropping
# the index never risks an article.
[ -z "$(find "$script_archive" -name 'xapian' -print -quit)" ] || \
  fail 'notmuch database was stored inside the archive'
[ -d "$index_dir/database" ] || fail 'notmuch database is not in the index dir'

board_run "$search_sh" --task "$task_uuid" | grep -q 'Incus warmup times out' || \
  fail 'searching by --task did not find the posted articles'
# Punctuation from a task description must never reach the query parser.
board_run "$search_sh" --text 'Incus warmup (cold image!) -- times out?' \
  | grep -q 'Incus warmup times out' || \
  fail 'searching by --text did not find the posted articles'

script_thread="$(board_run "$search_sh" --threads | head -n1)"
[ -n "$script_thread" ] || fail '--threads printed no thread ID'
board_run "$search_sh" --thread "$script_thread" | jq -e '
  .[0][0] as $root
  | ($root[1] | length) == 1
    and (($root[1][0][1]) | length) == 1
' >/dev/null || fail '--thread JSON does not nest the three-article ancestry'

# An article with no body carries no knowledge; size alone would accept it.
board_run "$post_sh" --subject 'empty' --body-text '' >/dev/null 2>&1 && \
  fail 'db-post.sh accepted an empty body'
board_run "$post_sh" --subject 'blank' --body-text '   ' >/dev/null 2>&1 && \
  fail 'db-post.sh accepted a whitespace-only body'

# A reply to a Message-ID that is not on this board would start a detached thread
# no reader can ever join to its context.
board_run "$post_sh" --subject 'orphan' --parent '<nobody@dev-board.invalid>' \
  --body-text 'x' >/dev/null 2>&1 && \
  fail 'db-post.sh accepted an unresolvable --parent'
board_run "$search_sh" --thread '0123456789abcdef' >/dev/null 2>&1 && \
  fail 'db-search.sh accepted an unresolvable --thread'

# Header values are flattened, so an embedded newline cannot forge a header.
board_run "$post_sh" --subject 'ok
X-Injected: yes' --body-text 'x' >/dev/null
[ -z "$(grep -rl '^X-Injected:' "$script_board/new")" ] || \
  fail 'a newline in --subject injected a header'

[ "$(find "$script_board/new" -type f | wc -l)" -eq 4 ] || \
  fail 'a rejected post was delivered anyway'

printf 'test-dev-board: ok\n'
