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

printf 'test-dev-board: ok\n'
