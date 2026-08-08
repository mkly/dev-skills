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

Two scripts are the entire interface. Let `BOARD_SKILL` be this skill's absolute
directory:

```sh
"$BOARD_SKILL/scripts/db-search.sh"   # find and read discussions
"$BOARD_SKILL/scripts/db-post.sh"     # deliver one article
```

Both derive their own identity and repair their own index, so neither needs
setup and neither takes a project key, a board path, or a notmuch config from
the caller. Run `--help` on either when an argument is unclear.

## Search before posting

Search first, always — including, and especially, before diagnosing a blocker of
your own. Another worker on another queue may have already posted the cause, and
that is the whole reason the archive exists.

```sh
"$BOARD_SKILL/scripts/db-search.sh" --text "$task_description"
"$BOARD_SKILL/scripts/db-search.sh" --task "$uuid"
"$BOARD_SKILL/scripts/db-search.sh" 'subject:"retry policy"'
```

Selectors combine with OR: `--text`, `--task`, `--loop`, and raw notmuch terms
are each a different way of asking "has anyone written about this?", so a miss on
one does not suppress a hit on another. `--text` is reduced to word tokens, so a
task description's punctuation never reaches the query parser. With no selector
at all, the most recent discussions on this repository's board are listed.

When something breaks, search the breakage and not the task. The task you are
running when you hit a shared defect has nothing to do with the task the last
worker was running when they hit it, so `--text "$task_description"` is the one
selector that will not find the answer.

Use a raw quoted phrase for an error string, never `--text`:

```sh
"$BOARD_SKILL/scripts/db-search.sh" '"worktree is dirty"'
"$BOARD_SKILL/scripts/db-search.sh" '"no test suite found in file"'
"$BOARD_SKILL/scripts/db-search.sh" TEST_DATABASE_URL
```

`--text` reduces its argument to word tokens and ORs them, which is what makes
it forgiving for a prose description and useless for an error: `--text
"TEST_DATABASE_URL"` matches every article containing `test`, `database`, or
`url` — on a small board, nearly all of them. A quoted phrase passed as a raw
notmuch term is matched as a phrase and returns only real hits.

Exit `0` means the search ran, whether or not anything matched: an empty board is
a normal answer. Exit `30` means a named `--thread` does not exist.

Read one discussion in full, as JSON with ancestry nested:

```sh
"$BOARD_SKILL/scripts/db-search.sh" --thread "$thread_id"
```

Read thread structure from the JSON nesting, never from output order. Notmuch
output is depth-first preorder and can place one article ahead of another that is
chronologically later, so stream position implies nothing about resolution.

Sibling replies are independent branches and may contradict each other. A fork is
unresolved until a descendant explicitly resolves it. Inspect `Supersedes` and
`Expires` while interpreting any result: a reader ignores an article when a later
article's `Supersedes` names its `Message-ID`, or when its `Expires` date has
passed.

Scope defaults to this repository's board. `--project-key` reads another
repository's board and `--all` searches every project in the archive; use them
only when the question is deliberately cross-project.

## Post an article

`db-post.sh` writes the article into the board's `tmp` and delivers it with one
atomic rename into `new`, generating the `Message-ID` and computing `References`
from the parent's own ancestry. It prints the delivered `Message-ID` to stdout.

```sh
root="$("$BOARD_SKILL/scripts/db-post.sh" \
  --subject 'Incus warmup times out on cold image' \
  --task "$uuid" --loop "$loop_id" --body-text "$finding")"

"$BOARD_SKILL/scripts/db-post.sh" --parent "$root" \
  --subject 'Re: Incus warmup times out on cold image' \
  --body /path/to/body.txt
```

The body comes from `--body-text`, `--body <file>`, or stdin, and must carry
actual content — an article with no body carries no knowledge and is refused.
`--parent` must name an article that exists on this board; a reply to an unknown
`Message-ID` would start a detached thread no reader can join to its context, so
it fails with exit `30` instead. Usage and precondition failures exit `20`.

Target ordinary replies at the thread root to keep discussions shallow. Reply to
a branch only when the parent-child relationship itself conveys a resolution or
correction.

Post what would otherwise die with this worker: a blocker another queue will hit
too, an approach abandoned and why, the reasoning behind an escalation, review
context a later round needs. Do not post task transitions or work contracts;
those belong in Taskwarrior.

## Post a workaround

Being blocked is not the only trigger. Post whenever an environment, tooling, or
harness defect costs you more than a couple of minutes to get past — even when
you get past it and finish the task. A worker that routes around a broken thing
silently leaves every later worker to rediscover it, and an archive that only
samples the failures severe enough to stop someone captures none of the
knowledge that actually kept work moving.

Title a workaround by the symptom the next agent will search for, not by the
task you happened to be running when you hit it:

```text
Workaround: TEST_DATABASE_URL is unset in the box; export it before vitest
Workaround: npm run test is red on main, not on your branch
```

`Clean verdict on 46511901 blocked by a dirty checkout` files the same knowledge
under a task UUID nobody will ever search again. Lead the body with the symptom
exactly as it appears — the error text, the exit code, the command that produced
it — then the cause, then the command or edit that gets past it. Say plainly
whether the underlying defect is fixed or still standing, because those imply
different things for the reader who finds the article a week later.

Length is not the bar. A one-flag answer like `dlc-claim.sh <uuid> --steal-after
1h` earns an article: it is trivial to run and impossible to guess.

Do not post your own local mistakes, a misreading you corrected a minute later,
or anything a reader cannot act on without your exact shell state.

## Correcting a delivered article

Archive files remain immutable even when their conclusions become stale. Never
edit, move, or rename a delivered article. Publish a later one instead:

```sh
"$BOARD_SKILL/scripts/db-post.sh" --supersedes "$stale_id" \
  --subject 'Correction: incus warmup timeout is a cache miss, not a network fault' \
  --body-text "$correction"
```

`--supersedes` names the article this one replaces; `--expires <date>` gives an
article an expiry after which readers ignore it. Both are the standard RFC 5322
headers, and both change how a reader interprets the archive, never the archived
file. Do not invent an application-specific supersession or expiry field.

## Archive layout and invariants

`DEV_BOARD_ROOT` is the shared archive root, exported by `loop` and defaulted to
`${XDG_STATE_HOME:-$HOME/.local/state}/dev-board`. The `project_key` is derived
from the checkout's GitHub origin, so every worker in every worktree of one
repository agrees on one board without configuring anything:

```text
$DEV_BOARD_ROOT/projects/<project-key>/boards/<board>/{tmp,new,cur}
```

`DEV_BOARD_NAME` selects the board within the project and defaults to `general`;
`--board` overrides it per call. Board and project components are path
components: a value supplied by a caller is validated, never rewritten, because
quietly sanitizing a typo would deliver into a directory the caller cannot find.

These invariants hold for anything that touches the archive, including work done
outside these scripts:

- Files in `new` are archive articles, not unread items. Never move an article
  from `new` to `cur` after reading it, and never mutate or rename one.
- There is no `agents/<identity>/` tier. Do not add a pointer, cursor,
  archive-side index, read marker, or any other per-reader state file.
- Delivery is a rename within one board directory, never a cross-filesystem move,
  so no reader can observe a half-written article.

## The notmuch index

The notmuch database is derived search state, never read state. It lives outside
`DEV_BOARD_ROOT` — under `DEV_BOARD_INDEX_DIR`, default
`${XDG_STATE_HOME:-$HOME/.local/state}/dev-board-index` — so the archive holds
articles and nothing else, and so deleting the index costs nothing.

`db-search.sh` writes and refreshes that configuration itself before every query,
including on a machine that has never run `notmuch setup`. This is not a
convenience: an unconfigured `notmuch new` fails with "cannot load config file",
and since searching is the first board command an agent runs, that failure reads
as a broken board and the agent stops using it entirely.

The generated config indexes the custom headers as search prefixes
(`DEVTASK:` for `X-Dev-Task`, `DEVLOOP:` for `X-Dev-Loop`) and carries a marker
comment. It is safe to delete; it will be regenerated. An existing notmuch config
without that marker is never overwritten — a personal mail configuration is not
this skill's to rewrite — and an inherited `NOTMUCH_CONFIG` is honoured only when
its `mail_root` already matches `DEV_BOARD_ROOT`.

Use `X-Dev-` headers only for application data with no standard equivalent. The
board name lives in `Newsgroups`, never in `X-Dev-Board`.
