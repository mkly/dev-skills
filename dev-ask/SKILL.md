---
name: dev-ask
description: >-
  Stop and ask the user when the blocker is the dev environment, harness, or
  tooling rather than the code being worked on — instead of burning time and
  tokens on repeated workarounds. Applies whenever a command fails for
  environmental reasons (missing tool/dependency, broken venv or PATH, sandbox
  or permission wall, unreachable service, misbehaving harness script, flaky
  container/box), whenever the same error has come back twice despite
  different attempts, or whenever the next idea is a hack that routes AROUND
  the environment instead of THROUGH it. The point is to surface the issue so
  it can actually be fixed once, not papered over every session.
---

# dev-ask

You are here because something outside the code is broken. **Your job right
now is to produce a clear, actionable report and stop — not to defeat the
environment.** An environment problem the user never hears about gets
re-fought by every future session; a reported one gets fixed once.

## The core rule

**Two strikes, then ask.** You get at most two genuine, distinct attempts to
resolve an environmental failure. If the second attempt doesn't cleanly fix
it, stop and report. Retrying the same command, adding `|| true`, or trying
the same idea with different flags does not count as a distinct attempt — it
counts as strike two.

"Environmental" means the problem is not in the code you were asked to change:

- A tool, interpreter, or dependency is missing, wrong-versioned, or not on
  PATH (no venv, `command not found`, ABI/lockfile mismatch).
- A harness or infrastructure script fails on its own preconditions —
  Taskwarrior state, Crabbox/Incus boxes, worktrees, CI config, launchers.
- A permission, sandbox, network, or credential wall (denied writes, blocked
  hosts, expired auth, interactive login required).
- A service the task assumes is up isn't (database, daemon, container that
  won't start, port already bound).
- The same test/build fails identically on a known-good baseline (e.g. on
  `main` before your change) — the suite or environment is broken, not you.

## Forbidden moves

These are the steamroller patterns this skill exists to prevent. Do **not**
do any of them to get past an environmental failure — each is worth reporting
*instead*:

- **Don't mutate the machine to make the error go away**: no `sudo`, no
  global `pip/npm install -g`, no reinstalling toolchains, no editing shell
  profiles or system config, no `chmod -R`, no killing processes you didn't
  start.
- **Don't hollow out the verification**: no skipping/deleting failing tests,
  no `--no-verify`, no mocking or stubbing the broken service so the suite
  "passes", no loosening assertions, no marking the task done with checks
  unrun.
- **Don't reimplement the harness**: if a project script (`dl-*.sh`,
  `dlr-*.sh`, Makefile target, CI step) fails, fix-or-report the script's
  problem; don't hand-roll its steps inline to sidestep it.
- **Don't loop**: never run the same failing command more than twice hoping
  for a different result, and never enter a rebuild/retry cycle ("clean and
  try again" counts as one attempt, not a strategy).
- **Don't silently downgrade the goal**: switching to "I'll just do the parts
  that don't need the environment" without telling the user is a hack too —
  offer it in the report as an option, don't unilaterally take it.

Quick fixes that are squarely in-scope remain fine: activating an existing
venv, running the project's documented setup command once (`make setup`,
`uv sync`, `npm ci`), creating a missing directory the task obviously owns,
or re-reading docs/reference.md for the correct flags. Those are strike-free
when they're the documented path. It's when the documented path itself fails
that you're in this skill's territory.

## How to stop well

A good stop is short, specific, and decision-ready. Report, in this shape:

```markdown
## Environment issue — stopping for input

**Blocked on:** <one sentence: what is broken, in plain terms>
**Task impact:** <what I can't do / what remains undone>

**Evidence:**
<the exact command and the relevant 3–10 lines of its output — not the whole log>

**What I tried:** (max 2)
1. <attempt> → <result>
2. <attempt> → <result>

**Diagnosis:** <best guess at root cause, one or two sentences; say "unsure" if unsure>

**Options:**
- <the fix I'd make if authorized — e.g. "install X", "restart the incus daemon">
- <a workaround and its cost, if one exists>
- <continue with reduced scope: what that would and wouldn't cover>
```

Then **end the turn**. Do not append "meanwhile, I'll keep trying…" — the
entire point is that the human can fix in thirty seconds what costs you half
an hour of hacks, and the fix then sticks for every future session.

## Judgment calls

- **Ambiguous origin (code vs. environment)?** Check the baseline: does the
  failing command also fail on a clean checkout / `main` / a trivially
  correct input? If yes, it's environmental — stop and report. If no, it's
  your code — keep debugging normally; this skill doesn't apply.
- **Partial progress is fine to bank.** If some of the task completed before
  the wall, commit/save the finished part (per the task's own conventions),
  say exactly where you stopped, and report. Don't discard good work just
  because the last step is blocked.
- **Autonomous context (dev-loop box, no human mid-task)?** You can't ask
  mid-flight — so fail loudly instead of hacking quietly: leave the task
  incomplete, write the same report as an artifact the harness surfaces (task
  annotation, box log, or the run summary), and exit nonzero. A cleanly
  failed task with a diagnosis beats a "passed" task with a hollowed-out
  check every time.
- **Recurring nuisance that has a known workaround?** Applying a known,
  documented workaround is fine — but still note it in your summary as a
  candidate fix ("this bites every run; consider fixing X properly") so it
  can be filed and killed for good.
