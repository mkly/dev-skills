#!/usr/bin/env bash
# db-search.sh — search and read the shared board archive through notmuch.
#
# Self-heals the notmuch configuration before every query. Every sibling skill
# instructs the agent to search the board BEFORE posting or diagnosing, so this
# is the first board command an agent runs; on a machine that has never run
# `notmuch setup` a bare `notmuch new` fails with "cannot load config file", and
# an agent that cannot read the board reasonably concludes it is broken and
# never posts either.
#
# Exit 0 whether or not anything matched — an empty board is a normal answer,
# not an error. Unresolvable --thread: exit 30. Precondition/usage: exit 20.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=db-common.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/db-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: db-search.sh [query terms...] [--text <text>] [--task <uuid>]
                    [--loop <uuid>] [--thread <thread-id>]
                    [--board <name>] [--project-key <key>] [--all]
                    [--threads] [--json] [--limit <n>] [--digest]

Searches this repository's board and prints matching discussions. With no
selector at all, lists the most recent discussions on the board.

Selectors (combined with OR):
  query terms...           raw notmuch query terms, e.g. subject:"retry policy"
  --text <text>            free text (a task description); reduced to word
                           tokens so its punctuation never reaches the query
                           parser
  --task <uuid>            articles carrying that X-Dev-Task
  --loop <uuid>            articles carrying that X-Dev-Loop

Reading:
  --thread <thread-id>     print one complete thread as JSON, ancestry nested.
                           Read structure from the nesting, never from output
                           order: notmuch text output is depth-first preorder
                           and can place a chronologically later article first.

Scope:
  --board <name>           board name (default: $DEV_BOARD_NAME, else "general")
  --project-key <key>      override the derived repository key
  --all                    search every project and board in the archive

Output:
  --threads                bare thread IDs, one per line, for use with --thread
  --json                   JSON search results
  --limit <n>              cap results (default 20)
  --digest                 short advisory summary; prints nothing when the board
                           has no match, for use in an automated pre-flight
EOF
}

declare -a RAW_TERMS=()
TEXT=""
TASK_UUID=""
LOOP_ID=""
THREAD=""
BOARD=""
PROJECT_KEY=""
ALL_SCOPE=0
THREADS_ONLY=0
JSON_OUTPUT=0
DIGEST=0
LIMIT=20

need_value() {
  [ "$2" -gt 1 ] || { usage; db_die "$DB_PRECOND" "$1 needs a value"; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --text)         need_value "$1" "$#"; shift; TEXT="$1" ;;
    --task)         need_value "$1" "$#"; shift; TASK_UUID="$(db_trim "$1")" ;;
    --loop)         need_value "$1" "$#"; shift; LOOP_ID="$(db_trim "$1")" ;;
    --thread)       need_value "$1" "$#"; shift; THREAD="$(db_trim "$1")" ;;
    --board)        need_value "$1" "$#"; shift; BOARD="$1" ;;
    --project-key)  need_value "$1" "$#"; shift; PROJECT_KEY="$1" ;;
    --limit)        need_value "$1" "$#"; shift; LIMIT="$1" ;;
    --all)          ALL_SCOPE=1 ;;
    --threads)      THREADS_ONLY=1 ;;
    --json)         JSON_OUTPUT=1 ;;
    --digest)       DIGEST=1 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             usage; db_die "$DB_PRECOND" "unknown flag: $1" ;;
    *)              RAW_TERMS+=("$1") ;;
  esac
  shift
done

[[ "$LIMIT" =~ ^[0-9]+$ ]] && [ "$LIMIT" -gt 0 ] \
  || db_die "$DB_PRECOND" "--limit must be a positive integer: $LIMIT"

if [ -n "$PROJECT_KEY" ]; then
  db_valid_component "$PROJECT_KEY" \
    || db_die "$DB_PRECOND" "--project-key must contain only letters, digits, periods, underscores, and hyphens: $PROJECT_KEY"
elif [ "$ALL_SCOPE" -eq 0 ]; then
  PROJECT_KEY="$(db_project_key)"
fi

[ -n "$BOARD" ] || BOARD="$DEV_BOARD_NAME"
db_valid_component "$BOARD" \
  || db_die "$DB_PRECOND" "--board must contain only letters, digits, periods, underscores, and hyphens: $BOARD"

dl_require notmuch jq

# The scoped board must exist before notmuch is pointed at the archive: with no
# mail root on disk at all, `notmuch new` fails rather than reporting an empty
# result, which would turn "nobody has posted yet" into an error.
( umask 077; mkdir -p "$DEV_BOARD_ROOT" ) \
  || db_die "$DB_PRECOND" "could not create board root: $DEV_BOARD_ROOT"
if [ "$ALL_SCOPE" -eq 0 ]; then
  db_ensure_board "$PROJECT_KEY" "$BOARD" >/dev/null
fi

db_ensure_notmuch_config
db_notmuch_refresh

# db_quote_term <text> — a notmuch phrase term with embedded quotes removed, so
# a value taken from a task description cannot terminate the phrase and inject
# query syntax.
db_quote_term() {
  printf '"%s"' "$(printf '%s' "$1" | tr -d '"()' | tr -s '[:space:]' ' ')"
}

scope=""
if [ "$ALL_SCOPE" -eq 0 ]; then
  scope="path:$(db_board_relpath "$PROJECT_KEY" "$BOARD")/**"
fi

if [ -n "$THREAD" ]; then
  case "$THREAD" in
    thread:*) thread_query="$THREAD" ;;
    *)        thread_query="thread:$THREAD" ;;
  esac
  count="$(notmuch count --output=messages "$thread_query" 2>/dev/null || echo 0)"
  [ "${count:-0}" -gt 0 ] \
    || db_die "$DB_NOTFOUND" "no articles in $thread_query (list threads first with db-search.sh --threads)"
  notmuch show --entire-thread --format=json "$thread_query"
  exit "$DB_OK"
fi

# Selectors are ORed: a per-task lookup and a free-text lookup are two ways of
# asking the same question — "has anyone already written about this?" — and an
# AND would answer no whenever either half missed.
declare -a selectors=()
if [ "${#RAW_TERMS[@]}" -gt 0 ]; then
  for term in "${RAW_TERMS[@]}"; do
    selectors+=("($term)")
  done
fi
[ -z "$TASK_UUID" ] || selectors+=("(DEVTASK:$(db_quote_term "$TASK_UUID"))")
[ -z "$LOOP_ID" ] || selectors+=("(DEVLOOP:$(db_quote_term "$LOOP_ID"))")
if [ -n "$TEXT" ]; then
  while IFS= read -r word; do
    [ -n "$word" ] || continue
    selectors+=("($word)")
  done < <(db_query_words "$TEXT" 6)
fi

selection=""
if [ "${#selectors[@]}" -gt 0 ]; then
  selection="$(printf '%s OR ' "${selectors[@]}")"
  selection="( ${selection% OR } )"
fi

# "*" is a whole-database query in notmuch and is not composable with AND, so a
# selector-less listing narrows by scope alone rather than ANDing against it.
if [ -n "$scope" ] && [ -n "$selection" ]; then
  query="$scope AND $selection"
elif [ -n "$scope" ]; then
  query="$scope"
elif [ -n "$selection" ]; then
  query="$selection"
else
  query="*"
fi

if [ "$THREADS_ONLY" -eq 1 ]; then
  notmuch search --output=threads --limit="$LIMIT" "$query" 2>/dev/null || true
  exit "$DB_OK"
fi

if [ "$JSON_OUTPUT" -eq 1 ]; then
  notmuch search --output=summary --format=json --limit="$LIMIT" "$query" \
    2>/dev/null || printf '[]\n'
  exit "$DB_OK"
fi

results="$(notmuch search --output=summary --limit="$LIMIT" "$query" 2>/dev/null || true)"

if [ -z "$results" ]; then
  # A digest is a pre-flight hint attached to another command's output. Printing
  # "no results" there would add noise to every claim on an empty board, which
  # is the normal state of a new project.
  if [ "$DIGEST" -eq 1 ]; then
    exit "$DB_OK"
  fi
  if [ "$ALL_SCOPE" -eq 1 ]; then
    db_log "no matching articles in any project"
  else
    db_log "no matching articles in ${PROJECT_KEY}/${BOARD}"
  fi
  exit "$DB_OK"
fi

if [ "$DIGEST" -eq 1 ]; then
  printf 'dev-board: existing discussion in %s/%s — read before diagnosing:\n' \
    "$PROJECT_KEY" "$BOARD"
  printf '%s\n' "$results"
  printf 'dev-board: read one with: %s --thread <thread-id>\n' \
    "$SCRIPT_DIR/db-search.sh"
else
  printf '%s\n' "$results"
  db_log "read a discussion with: $SCRIPT_DIR/db-search.sh --thread <thread-id>"
fi
