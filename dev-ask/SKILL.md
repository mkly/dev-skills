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

Outside the generic base-image exception below, never respond by installing
system software. Never change global configuration, kill unrelated processes,
bypass the harness, weaken tests, retry indefinitely, or silently reduce scope.

## Generic base-image exception

Installing one required system package is a repair attempt only when reliable
image metadata or harness configuration positively identifies the current
environment as a generic base image, not a project-specific image. A repository
checkout, an available package manager, or an inference from missing tools is
not proof of the image type.

Identify the exact package that supplies the missing prerequisite, then install
only that package through the image's normal package manager; resolver-selected
dependencies are allowed, but broad bundles, system upgrades, extra package
sources, and unrelated packages are not. Record the command and result as one
of the two environmental repair attempts, then rerun the original failing check
unchanged. Do not skip, replace, or weaken that check.

Never install a system package in a verified project-specific image. If the
image type cannot be positively verified, stop and ask for the smallest user
decision or repair needed to continue.

## Stop report

Report and end the turn with:

- the broken prerequisite and task impact;
- the failing command plus only the relevant output;
- the two attempts and results;
- the likely cause, explicitly uncertain when necessary; and
- the smallest user decision or repair needed to continue.

Preserve completed work. In an autonomous worker, record the same report in its
durable task/log, leave the task incomplete, and exit nonzero.

Before stopping, search the shared board for this blocker: another worker may
have already resolved it, which makes the block moot. When it is new, load the
`dev-board` skill and post the same report there so the next worker finds it
instead of rediscovering it. `loop` exports `DEV_BOARD_ROOT`. Posting never
substitutes for stopping — post, then stop.
