---
name: dev-search
description: Research current external technical information and synthesize authoritative guidance. Use when Codex lacks confidence about third-party APIs, syntax, CLI flags, error messages, versioned behavior, or documentation; consult sources before guessing or invoking dev-ask.
---

# Dev Search

Resolve external knowledge gaps through web research, then continue the task with cited evidence.

## Research workflow

1. Search as soon as an external fact affects the next decision. Query exact API names, error text, versions, and vendor terms. Do not fill gaps from memory.
2. Prefer primary sources such as official documentation, specifications, source repositories, issue trackers, and release notes. Match guidance to the relevant version and publication date. Use independent sources to corroborate claims when no primary source covers them.
3. Extract the facts needed for the task. Separate source-backed facts from inference, keep exact error codes and identifiers, and note version limits.
4. Synthesize a compact answer with source links and the practical consequence for the current work. If sources conflict or leave a gap, state the unresolved point and identify the next check.

## Escalation boundary

Use this skill as a low-barrier, self-service check for uncertainty about external systems and published behavior. Search the exact error and authoritative documentation before treating an unfamiliar failure as an environment problem.

Treat `dev-ask` as a high-barrier intervention. Invoke it when a broken local prerequisite, permission, credential, service, or harness still blocks work after you follow its repair policy, or before bypassing the environment. A documentation gap alone does not justify human intervention. Research does not authorize system changes or reduced acceptance scope.
