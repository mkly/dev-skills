# shellcheck shell=bash
# db-common.sh — shared helpers for the dev-board archive scripts.
# Sourced, never executed directly. Keep POSIX-ish bash; assume bash 4+.
#
# The board is a shared Maildir archive plus a derived notmuch index. Two facts
# drive every helper here:
#
#   1. project_key must be DERIVED, never chosen. A caller-invented key silently
#      partitions the archive: two workers on the same repository post into
#      different directories and never see each other, which looks exactly like
#      an empty board.
#   2. notmuch must be usable with no prior setup. Every sibling skill tells the
#      agent to search the board BEFORE posting, so an unconfigured notmuch makes
#      the very first board command fail and the whole capability read as broken.
#      db_ensure_notmuch_config writes a config the board owns, so the read path
#      works on a machine that has never run `notmuch setup`.

# ---------------------------------------------------------------------------
# Exit codes (stable contract the agent branches on).
#   0  ok
#   20 precondition / usage failure
#   30 article not found (unresolvable --parent, --thread, or --supersedes)
# ---------------------------------------------------------------------------
DB_OK=0
DB_PRECOND=20
DB_NOTFOUND=30
export DB_OK DB_PRECOND DB_NOTFOUND

db_log()  { printf 'dev-board: %s\n' "$*" >&2; }
db_warn() { printf 'dev-board: WARN: %s\n' "$*" >&2; }
db_err()  { printf 'dev-board: ERROR: %s\n' "$*" >&2; }
# db_die <exit-code> <message...>
db_die()  { local code="$1"; shift; db_err "$*"; exit "$code"; }

# Repository identity comes from the implement skill's library so the board
# agrees with Taskwarrior about what "this repository" means.
DB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_IMPLEMENT_DIR="$(cd "$DB_SCRIPT_DIR/../../dev-implement-task/scripts" && pwd)"
# shellcheck source=../../dev-implement-task/scripts/dl-common.sh
# shellcheck disable=SC1091
. "$DB_IMPLEMENT_DIR/dl-common.sh"
export DB_SCRIPT_DIR

# ---------------------------------------------------------------------------
# Environment knobs.
#
# DEV_BOARD_ROOT defaults to the same path `loop` exports, so a board script run
# outside a loop-launched worker reads and writes the same archive.
# The index directory holds the notmuch database and the config the board owns.
# It lives OUTSIDE DEV_BOARD_ROOT: a derived search database inside the archive
# would be mistaken for archive content and would break the "no state in the
# archive" invariant the test suite asserts.
# ---------------------------------------------------------------------------
: "${DEV_BOARD_ROOT:=${XDG_STATE_HOME:-$HOME/.local/state}/dev-board}"
: "${DEV_BOARD_INDEX_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/dev-board-index}"
: "${DEV_BOARD_NAME:=general}"
export DEV_BOARD_ROOT DEV_BOARD_INDEX_DIR DEV_BOARD_NAME

# Marker identifying a notmuch config this skill generated and may rewrite. A
# config without it is the user's own and is never modified.
DB_CONFIG_MARKER='# managed by dev-board — safe to delete; it will be regenerated'

# db_sanitize_component <text> — collapse anything outside the documented
# path-component alphabet to a hyphen. Used for derived values only; a value
# supplied by the caller is validated and rejected instead of rewritten, so a
# typo never silently lands in a different directory.
db_sanitize_component() {
  local s="$1"
  s="${s//[^A-Za-z0-9._-]/-}"
  while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
  s="${s#-}"; s="${s%-}"
  printf '%s' "$s"
}

# db_valid_component <text> — true when text is a safe single path component.
db_valid_component() {
  local s="${1-}"
  [ -n "$s" ] || return 1
  [ "$s" != "." ] && [ "$s" != ".." ] || return 1
  [[ "$s" =~ ^[A-Za-z0-9._-]+$ ]]
}

# db_project_key — derived, filesystem-safe identity for the current checkout.
#
# Prefers the GitHub identity dl_resolve_repo_identity already computes, so the
# key matches the repo-id annotation Taskwarrior carries: github.com/mkly/repo
# becomes github.com-mkly-repo. Falls back to dl_repo_key for a checkout with no
# GitHub origin — the board is a knowledge path and must never become a dead one
# just because a repository is local-only.
db_project_key() {
  local repo_id key
  repo_id="$(dl_resolve_repo_identity >/dev/null 2>&1 && printf '%s' "$DL_REPO_ID")" \
    || repo_id=""
  if [ -n "$repo_id" ]; then
    key="$(db_sanitize_component "${repo_id//\//-}")"
  else
    key="$(db_sanitize_component "$(dl_repo_key 2>/dev/null || true)")"
  fi
  db_valid_component "$key" \
    || db_die "$DB_PRECOND" "could not derive a project key for this checkout (run from inside a git repository, or pass --project-key)"
  printf '%s' "$key"
}

# db_board_maildir <project-key> <board> — absolute path of one board's Maildir.
db_board_maildir() {
  printf '%s/projects/%s/boards/%s' "$DEV_BOARD_ROOT" "$1" "$2"
}

# db_board_relpath <project-key> <board> — the same path relative to the notmuch
# mail root, for use in a `path:` query term.
db_board_relpath() {
  printf 'projects/%s/boards/%s' "$1" "$2"
}

# db_ensure_board <project-key> <board> — create the Maildir if absent.
# Restrictive by default: the archive holds unreviewed engineering discussion.
db_ensure_board() {
  local dir
  dir="$(db_board_maildir "$1" "$2")"
  case "$DEV_BOARD_ROOT" in
    /*) ;;
    *) db_die "$DB_PRECOND" "DEV_BOARD_ROOT must be an absolute path: $DEV_BOARD_ROOT" ;;
  esac
  ( umask 077; mkdir -p "$dir/tmp" "$dir/new" "$dir/cur" ) \
    || db_die "$DB_PRECOND" "could not create board Maildir: $dir"
  printf '%s' "$dir"
}

# db_config_is_ours <path> — true when the file is absent or carries our marker.
db_config_is_ours() {
  local path="$1"
  [ -e "$path" ] || return 0
  grep -qF "$DB_CONFIG_MARKER" "$path" 2>/dev/null
}

# db_ensure_notmuch_config — export a NOTMUCH_CONFIG that indexes this archive,
# writing one if none usable exists. Sets DB_CONFIG_WRITTEN=1 when it wrote,
# which tells the caller a reindex is needed for already-indexed articles.
#
# An inherited NOTMUCH_CONFIG is honoured when it already points at this
# archive, so a machine with a real notmuch setup keeps using it. Otherwise the
# board falls back to its own managed config rather than touching ~/.notmuch-config:
# the user's personal mail configuration is not this skill's to rewrite.
db_ensure_notmuch_config() {
  local config database inherited_root
  DB_CONFIG_WRITTEN=0

  if [ -n "${NOTMUCH_CONFIG:-}" ] && [ -r "$NOTMUCH_CONFIG" ]; then
    inherited_root="$(notmuch --config="$NOTMUCH_CONFIG" config get database.mail_root 2>/dev/null || true)"
    if [ "$inherited_root" = "$DEV_BOARD_ROOT" ]; then
      export NOTMUCH_CONFIG
      return 0
    fi
  fi

  config="$DEV_BOARD_INDEX_DIR/notmuch-config"
  database="$DEV_BOARD_INDEX_DIR/database"
  ( umask 077; mkdir -p "$database" ) \
    || db_die "$DB_PRECOND" "could not create notmuch index directory: $database"

  if ! db_config_is_ours "$config"; then
    db_die "$DB_PRECOND" "refusing to overwrite a notmuch config this skill did not write: $config"
  fi

  # Rewrite only when the content would change, so an unchanged config does not
  # force a reindex on every single call.
  local desired
  desired="$(
    printf '%s\n\n' "$DB_CONFIG_MARKER"
    printf '[database]\npath=%s\nmail_root=%s\n\n' "$database" "$DEV_BOARD_ROOT"
    printf '[user]\nname=%s\nprimary_email=%s\n\n' \
      'Dev Board' "$(db_author_address)"
    printf '[new]\ntags=archive\nignore=\n\n'
    printf '[maildir]\nsynchronize_flags=false\n\n'
    # Articles carry application data in X-Dev- headers. notmuch indexes only
    # headers it knows about, so without these the documented X-Dev-Task and
    # X-Dev-Loop values are unsearchable and a per-task lookup silently returns
    # nothing.
    printf '[index]\nheader.DEVTASK=X-Dev-Task\nheader.DEVLOOP=X-Dev-Loop\n'
  )"

  if [ ! -e "$config" ] || [ "$(cat "$config" 2>/dev/null)" != "$desired" ]; then
    ( umask 077; printf '%s' "$desired" >"$config" ) \
      || db_die "$DB_PRECOND" "could not write notmuch config: $config"
    DB_CONFIG_WRITTEN=1
  fi

  NOTMUCH_CONFIG="$config"
  export NOTMUCH_CONFIG
}

# db_author_name — a stable, attributable author for articles this worker posts.
# DEV_LOOP_OWNER is the same identity Taskwarrior records as the claim assignee,
# so an article can be traced back to the worker that wrote it.
db_author_name() {
  local owner="${DEV_BOARD_AUTHOR:-${DEV_LOOP_OWNER:-}}"
  [ -n "$owner" ] || owner="$(dl_default_owner)"
  db_sanitize_component "$owner"
}

# db_author_address — the author as an addr-spec in the reserved .invalid TLD,
# which can never resolve to a real mailbox.
db_author_address() {
  printf '%s@agents.invalid' "$(db_author_name)"
}

# db_header <file> <header-name> — print one unfolded header value, or nothing.
# Case-insensitive on the name, stops at the blank line ending the header block,
# and joins RFC 5322 continuation lines so a folded References list reads as one
# value. First occurrence wins.
db_header() {
  local file="$1" want
  want="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  [ -r "$file" ] || return 0
  awk -v want="$want" '
    { sub(/\r$/, "") }
    /^$/ { exit }
    /^[ \t]/ {
      if (found == 1) { s = $0; sub(/^[ \t]+/, " ", s); val = val s }
      next
    }
    {
      if (found == 1) { found = 2; next }
      if (found == 0) {
        k = $0
        sub(/:.*/, "", k)
        if (tolower(k) == want) {
          found = 1
          val = $0
          sub(/^[^:]*:[ \t]*/, "", val)
        }
      }
    }
    END { if (found > 0) print val }
  ' "$file"
}

# db_trim <text> — strip leading and trailing whitespace.
db_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# db_find_by_message_id <board-maildir> <message-id> — print the path of the
# article carrying that Message-ID, or nothing.
#
# Reads the Maildir directly rather than asking notmuch: a parent posted moments
# ago by this same worker is not in the derived index yet, and resolving a parent
# through a stale index is how a reply loses its thread.
db_find_by_message_id() {
  local dir="$1" want="$2" f got
  want="$(db_trim "$want")"
  [ -n "$want" ] || return 0
  for f in "$dir"/new/* "$dir"/cur/*; do
    [ -f "$f" ] || continue
    got="$(db_trim "$(db_header "$f" Message-ID)")"
    if [ "$got" = "$want" ]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 0
}

# db_valid_message_id <text> — true for a bracketed, single-line addr-spec-ish id.
db_valid_message_id() {
  local s="${1-}"
  [[ "$s" =~ ^\<[^[:space:]\<\>]+@[^[:space:]\<\>]+\>$ ]]
}

# db_header_safe <text> — a header value with no CR, LF, or other control
# characters. Folding a caller's newline into the header block is header
# injection: a body line starting with "From:" would become a real header.
db_header_safe() {
  printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037\177' | tr '\r\n\t' '   '
}

# db_notmuch_refresh — index new articles. When the config was just written the
# index predates the current X-Dev- header mapping, so already-indexed articles
# are reindexed once to make DEVTASK and DEVLOOP searchable on them too.
db_notmuch_refresh() {
  notmuch new >/dev/null 2>&1 \
    || db_die "$DB_PRECOND" "notmuch could not index the archive (config: ${NOTMUCH_CONFIG:-none})"
  if [ "${DB_CONFIG_WRITTEN:-0}" = "1" ]; then
    notmuch reindex '*' >/dev/null 2>&1 || true
  fi
}

# db_query_words <text> [max] — up to <max> distinct lowercase word tokens of at
# least four characters, one per line. Used to turn a task description into a
# query without letting its punctuation reach the notmuch query parser.
db_query_words() {
  local max="${2:-6}"
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '\n' \
    | awk 'length($0) >= 4' \
    | awk '!seen[$0]++' \
    | head -n "$max"
}
