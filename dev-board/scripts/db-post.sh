#!/usr/bin/env bash
# db-post.sh — deliver one immutable article into a project's shared board.
#
# Exists because posting by hand is a ten-step ritual (unique tmp file, RFC 5322
# header block, globally unique Message-ID, References ancestry in thread order,
# atomic rename) performed at exactly the moment the agent is busy with an
# exception. Every other durable operation in this system is one script call;
# this makes the board one too.
#
# On success: prints the delivered article's Message-ID to stdout, exit 0.
# Unresolvable --parent or --supersedes: exit 30. Usage/precondition: exit 20.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=db-common.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/db-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: db-post.sh --subject <text> [--body <file> | --body-text <text>]
                  [--parent <message-id>] [--board <name>]
                  [--project-key <key>] [--task <uuid>] [--loop <uuid>]
                  [--supersedes <message-id>] [--expires <date>]
                  [--author <name>] [--json] [--dry-run]

Delivers one article into the shared board archive for this repository.

Required:
  --subject <text>         one-line article subject

Body (choose one; defaults to reading stdin):
  --body <file>            read the article body from a file
  --body-text <text>       use this literal text as the body

Threading:
  --parent <message-id>    reply to this article; References is computed from
                           the parent's own ancestry, so thread order is never
                           assembled by hand
  --supersedes <message-id>  mark an earlier article as replaced by this one
  --expires <date>         RFC 5322 date after which readers ignore the article

Identity (all derived when omitted):
  --project-key <key>      override the derived repository key
  --board <name>           board name (default: $DEV_BOARD_NAME, else "general")
  --author <name>          override the derived author (DEV_LOOP_OWNER)
  --task <uuid>            Taskwarrior UUID, recorded as X-Dev-Task
  --loop <uuid>            loop ID, recorded as X-Dev-Loop

Output:
  --json                   emit a JSON object instead of the bare Message-ID
  --dry-run                print the article that would be delivered; write nothing

Articles are immutable once delivered. Correct or retract by posting a later
article with --supersedes, never by editing a file in the archive.
EOF
}

SUBJECT=""
BODY_FILE=""
BODY_TEXT=""
HAVE_BODY_TEXT=0
PARENT_ID=""
SUPERSEDES=""
EXPIRES=""
BOARD=""
PROJECT_KEY=""
TASK_UUID=""
LOOP_ID=""
AUTHOR=""
JSON_OUTPUT=0
DRY_RUN=0

need_value() {
  [ "$2" -gt 1 ] || { usage; db_die "$DB_PRECOND" "$1 needs a value"; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --subject)      need_value "$1" "$#"; shift; SUBJECT="$1" ;;
    --body)         need_value "$1" "$#"; shift; BODY_FILE="$1" ;;
    --body-text)    need_value "$1" "$#"; shift; BODY_TEXT="$1"; HAVE_BODY_TEXT=1 ;;
    --parent)       need_value "$1" "$#"; shift; PARENT_ID="$(db_trim "$1")" ;;
    --supersedes)   need_value "$1" "$#"; shift; SUPERSEDES="$(db_trim "$1")" ;;
    --expires)      need_value "$1" "$#"; shift; EXPIRES="$1" ;;
    --board)        need_value "$1" "$#"; shift; BOARD="$1" ;;
    --project-key)  need_value "$1" "$#"; shift; PROJECT_KEY="$1" ;;
    --task)         need_value "$1" "$#"; shift; TASK_UUID="$(db_trim "$1")" ;;
    --loop)         need_value "$1" "$#"; shift; LOOP_ID="$(db_trim "$1")" ;;
    --author)       need_value "$1" "$#"; shift; AUTHOR="$1" ;;
    --json)         JSON_OUTPUT=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             usage; db_die "$DB_PRECOND" "unknown flag: $1" ;;
    *)              usage; db_die "$DB_PRECOND" "unexpected argument: $1" ;;
  esac
  shift
done

SUBJECT="$(db_trim "$(db_header_safe "$SUBJECT")")"
[ -n "$SUBJECT" ] || { usage; db_die "$DB_PRECOND" "--subject is required and must not be blank"; }

if [ -n "$BODY_FILE" ] && [ "$HAVE_BODY_TEXT" -eq 1 ]; then
  db_die "$DB_PRECOND" "--body and --body-text are mutually exclusive"
fi

if [ -n "$AUTHOR" ]; then
  DEV_BOARD_AUTHOR="$AUTHOR"
  export DEV_BOARD_AUTHOR
fi
author_name="$(db_author_name)"
[ -n "$author_name" ] || db_die "$DB_PRECOND" "could not derive an author name"

# A caller-supplied component is validated, not rewritten: quietly sanitizing a
# typo would deliver into a directory the caller never named and cannot find.
if [ -n "$PROJECT_KEY" ]; then
  db_valid_component "$PROJECT_KEY" \
    || db_die "$DB_PRECOND" "--project-key must contain only letters, digits, periods, underscores, and hyphens: $PROJECT_KEY"
else
  PROJECT_KEY="$(db_project_key)"
fi

[ -n "$BOARD" ] || BOARD="$DEV_BOARD_NAME"
db_valid_component "$BOARD" \
  || db_die "$DB_PRECOND" "--board must contain only letters, digits, periods, underscores, and hyphens: $BOARD"

for id_spec in "--parent:$PARENT_ID" "--supersedes:$SUPERSEDES"; do
  id_flag="${id_spec%%:*}"
  id_value="${id_spec#*:}"
  [ -n "$id_value" ] || continue
  db_valid_message_id "$id_value" \
    || db_die "$DB_PRECOND" "$id_flag must be a bracketed Message-ID like <id@host>: $id_value"
done

# Read the body before touching the archive, so a bad --body path fails without
# leaving a partial draft in tmp.
body_source="$(mktemp "${TMPDIR:-/tmp}/db-body.XXXXXX")"
trap 'rm -f "$body_source"' EXIT
if [ -n "$BODY_FILE" ]; then
  [ -r "$BODY_FILE" ] || db_die "$DB_PRECOND" "body file not readable: $BODY_FILE"
  cat "$BODY_FILE" >"$body_source"
elif [ "$HAVE_BODY_TEXT" -eq 1 ]; then
  printf '%s\n' "$BODY_TEXT" >"$body_source"
else
  cat >"$body_source"
fi
# Emptiness is measured in content, not bytes: `--body-text ''` and a file of
# blank lines both produce a nonzero size and an article that says nothing.
[ -n "$(tr -d '[:space:]' <"$body_source")" ] \
  || db_die "$DB_PRECOND" "article body is empty; an article with no body carries no knowledge"

board_maildir="$(db_ensure_board "$PROJECT_KEY" "$BOARD")"

# References is the parent's own References plus the parent itself, which keeps
# the thread root first and the direct parent last without the caller tracking
# ancestry. Resolving the parent from the Maildir also proves it exists: a reply
# to a Message-ID that is not in this board would start a detached thread that
# no reader can ever join to its context.
REFERENCES=""
if [ -n "$PARENT_ID" ]; then
  parent_file="$(db_find_by_message_id "$board_maildir" "$PARENT_ID")"
  [ -n "$parent_file" ] \
    || db_die "$DB_NOTFOUND" "no article with Message-ID $PARENT_ID in board '$BOARD' of project '$PROJECT_KEY'"
  parent_refs="$(db_trim "$(db_header "$parent_file" References)")"
  if [ -n "$parent_refs" ]; then
    REFERENCES="$parent_refs $PARENT_ID"
  else
    REFERENCES="$PARENT_ID"
  fi
fi

if [ -n "$SUPERSEDES" ]; then
  superseded_file="$(db_find_by_message_id "$board_maildir" "$SUPERSEDES")"
  [ -n "$superseded_file" ] \
    || db_die "$DB_NOTFOUND" "no article with Message-ID $SUPERSEDES to supersede in board '$BOARD' of project '$PROJECT_KEY'"
fi

# Write into this board's own tmp, then deliver with a single rename within the
# same directory. A cross-filesystem move would not be atomic, and a reader
# could observe a half-written article in new.
if [ "$DRY_RUN" -eq 1 ]; then
  draft="$(mktemp "${TMPDIR:-/tmp}/db-draft.XXXXXX")"
  trap 'rm -f "$body_source" "$draft"' EXIT
else
  draft="$(mktemp "$board_maildir/tmp/article.XXXXXX")" \
    || db_die "$DB_PRECOND" "could not create a draft in $board_maildir/tmp"
  trap 'rm -f "$body_source" "$draft"' EXIT
fi

host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
message_id="<$(basename "$draft").$(date -u +%s%N).$$.$(db_sanitize_component "$host")@dev-board.invalid>"

{
  printf 'From: %s <%s>\n' "$author_name" "$(db_author_address)"
  printf 'Subject: %s\n' "$SUBJECT"
  printf 'Date: %s\n' "$(date -R)"
  printf 'Message-ID: %s\n' "$message_id"
  printf 'Newsgroups: %s\n' "$BOARD"
  if [ -n "$PARENT_ID" ]; then
    printf 'In-Reply-To: %s\n' "$PARENT_ID"
    printf 'References: %s\n' "$REFERENCES"
  fi
  [ -z "$SUPERSEDES" ] || printf 'Supersedes: %s\n' "$SUPERSEDES"
  [ -z "$EXPIRES" ] || printf 'Expires: %s\n' "$(db_header_safe "$EXPIRES")"
  [ -z "$TASK_UUID" ] || printf 'X-Dev-Task: %s\n' "$(db_header_safe "$TASK_UUID")"
  [ -z "$LOOP_ID" ] || printf 'X-Dev-Loop: %s\n' "$(db_header_safe "$LOOP_ID")"
  printf 'MIME-Version: 1.0\n'
  printf 'Content-Type: text/plain; charset=utf-8\n'
  printf '\n'
  cat "$body_source"
} >"$draft"

if [ "$DRY_RUN" -eq 1 ]; then
  cat "$draft" >&2
  db_log "dry run: nothing was delivered"
  exit "$DB_OK"
fi

delivered="$board_maildir/new/$(basename "$draft")"
mv "$draft" "$delivered" \
  || db_die "$DB_PRECOND" "could not deliver article into $board_maildir/new"
trap 'rm -f "$body_source"' EXIT

db_log "posted to ${PROJECT_KEY}/${BOARD}: $SUBJECT"

if [ "$JSON_OUTPUT" -eq 1 ]; then
  jq -n \
    --arg message_id "$message_id" --arg project_key "$PROJECT_KEY" \
    --arg board "$BOARD" --arg subject "$SUBJECT" --arg author "$author_name" \
    --arg path "$delivered" --arg parent "$PARENT_ID" --arg references "$REFERENCES" \
    '{message_id: $message_id, project_key: $project_key, board: $board,
      subject: $subject, author: $author, path: $path,
      parent: (if $parent == "" then null else $parent end),
      references: (if $references == "" then [] else ($references | split(" ")) end)}'
else
  printf '%s\n' "$message_id"
fi
