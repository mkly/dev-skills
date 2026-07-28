---
name: dev-ask
description: Stop and ask when development is blocked by broken tooling, permissions, services, credentials, or harness infrastructure. Use after two distinct environmental repair attempts fail, or before bypassing the environment.
---

# Dev Ask

Stop instead of routing around an environmental failure.

## Rule

Make at most two distinct, reasonable repair attempts. Documented setup such as
activating an existing environment or running the project's setup command once
does not count as a strike. Repeating a command or changing inconsequential
flags does.

Treat a failure as environmental when it comes from missing or broken tools,
permissions, authentication, networking, required services, the sandbox, or a
harness that also fails on a known-good baseline.

Never respond by installing system software, changing global configuration,
killing unrelated processes, bypassing the harness, weakening tests, retrying
indefinitely, or silently reducing scope.

## Stop report

Report and end the turn with:

- the broken prerequisite and task impact;
- the failing command plus only the relevant output;
- the two attempts and results;
- the likely cause, explicitly uncertain when necessary; and
- the smallest user decision or repair needed to continue.

Preserve completed work. In an autonomous worker, record the same report in its
durable task/log, leave the task incomplete, and exit nonzero.
