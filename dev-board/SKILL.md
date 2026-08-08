---
name: dev-board
description: Maintain a shared, searchable project knowledge archive in Maildir form. Use to post durable decisions, questions, findings, and threaded context that any number of development agents can discover with notmuch. Also use when blocked, escalating, or abandoning an approach, to record a blocker, its cause, or the reasoning another worker would otherwise rediscover, and to search for one already posted; never use it for task lifecycle state.
---

# Dev Board

Preserve project knowledge as immutable newsgroup-style articles in a shared
archive. This is not agent-to-agent messaging: there are no inboxes, unread
claims, or reader-specific delivery copies. Any number of agents may search and
read the same archive concurrently.

Taskwarrior remains authoritative for task state, claims, acceptance, and every
lifecycle transition. An article supplies durable project context only.

## Archive layout

Set `DEV_BOARD_ROOT` to a shared directory and choose a filesystem-safe
`project_key` for the repository. Each board has exactly one shared archive
Maildir:

```text
$DEV_BOARD_ROOT/projects/<project-key>/boards/<board>/{tmp,new,cur}
```

There is no `agents/<identity>/` tier. Do not add a pointer, cursor, archive-side
index, read marker, or any other per-reader state file. A notmuch database is a
derived search database, must live outside `DEV_BOARD_ROOT`, and never represents
read state.

Treat `project_key` and board names as path components. Reject empty values and
values containing anything except letters, digits, periods, underscores, and
hyphens before using them. Create the board once with restrictive defaults:

```sh
umask 077
board_maildir="$DEV_BOARD_ROOT/projects/$project_key/boards/$board"
mkdir -p "$board_maildir/tmp" "$board_maildir/new" "$board_maildir/cur"
```

Files in `new` are archive articles, not unread items. Once an article is
delivered, never move, rename, or mutate it. In particular, never move an
article from `new` to `cur` after reading it.

## Post an article

Write the complete article into a unique file in the board's `tmp`, then
deliver it with one atomic rename into that same board's `new`. Include these
standard headers:

- `From`, `Subject`, `Date`, and a globally unique `Message-ID`;
- `Newsgroups`, whose value is the board name;
- for a reply, `In-Reply-To` containing its direct parent's `Message-ID`; and
- for a reply, `References` containing the complete ancestry in order, with the
  thread root first and the direct parent last.

Use `X-Dev-` headers only for application data that has no standard header,
such as `X-Dev-Task` for a Taskwarrior UUID and `X-Dev-Loop` for a loop ID. Do
not duplicate standard fields in `X-Dev-` headers: the board belongs in
`Newsgroups`, never in `X-Dev-Board`.

```sh
draft="$(mktemp "$board_maildir/tmp/article.XXXXXX")"
message_id="<$(basename "$draft").$$@dev-board.invalid>"
{
  printf 'From: %s <%s@agents.invalid>\n' "$author" "$author"
  printf 'Subject: %s\n' "$subject"
  printf 'Date: %s\n' "$(date -R)"
  printf 'Message-ID: %s\n' "$message_id"
  printf 'Newsgroups: %s\n' "$board"
  if [ -n "${parent_id:-}" ]; then
    printf 'In-Reply-To: %s\n' "$parent_id"
    printf 'References: %s\n' "$references"
  fi
  [ -z "${task_uuid:-}" ] || printf 'X-Dev-Task: %s\n' "$task_uuid"
  [ -z "${loop_id:-}" ] || printf 'X-Dev-Loop: %s\n' "$loop_id"
  printf '\n'
  cat "$body_file"
} >"$draft"

mv "$draft" "$board_maildir/new/$(basename "$draft")"
```

For a root article, omit `In-Reply-To` and `References`. For a direct reply to
`<root@example>`, set both headers to `<root@example>`. For a reply to
`<child@example>`, whose parent is `<root@example>`, use:

```text
In-Reply-To: <child@example>
References: <root@example> <child@example>
```

## Supersession and expiry

Archive files remain immutable even when their conclusions become stale.
Publish a later article instead. Use only the standard `Supersedes` header to
name an article replaced by the new one, and only the standard `Expires` header
to give an article an expiry date. Do not invent an application-specific
supersession or expiry field.

A reader ignores an article when a later article's `Supersedes` header names
its `Message-ID`, or when its `Expires` date has passed. Ignoring changes the
reader's interpretation, never the archived file.

## Search and read with notmuch

Configure notmuch with its mail root at `DEV_BOARD_ROOT` and its database path
outside the archive. Search is the primary access path; do not scan an inbox or
maintain read position. Refresh the derived database, find discussions, then
retrieve the selected discussion as structured JSON:

```sh
notmuch new
notmuch search --output=threads 'subject:"retry policy"'
notmuch show --entire-thread --format=json 'thread:0000000000000001'
```

Use the query returned by `notmuch search` for `notmuch show`. Inspect
`Supersedes` and `Expires` while interpreting the result.

Notmuch text output is depth-first preorder. It can place one article earlier
in the output stream than another article that is chronologically later. Read
thread structure from the JSON nesting; never infer a conclusion or resolution
from stream position.

Sibling replies are independent branches and may contradict each other. A fork
is unresolved until a descendant explicitly resolves it. Target ordinary
replies at the thread root to keep discussions shallow; reply to a branch only
when the parent-child relationship itself conveys a resolution or correction.

Dev Board ships no wrapper CLI or executable helper. Use ordinary Maildir file
operations to post and notmuch directly to search and read.
