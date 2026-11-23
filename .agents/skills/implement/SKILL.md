---
name: implement
description: Use whenever implementing a change.
---

# Implement

## Confirm implementation intent

Start implementation when the user asks you to make a change or gives the
go-ahead on a plan. For feasibility questions, design discussions, and
tentative suggestions, inspect the relevant code as needed and discuss the
options. Wait for a request to implement before editing files or delegating.
When the request is clear, proceed without asking for confirmation again.

## Check for skill updates

The lead agent runs this step once per project per task, before editing files
or delegating implementation. Skip the check if the target project's Git root
has no `.agents/mstack.lock.json` or if the user or the project's `AGENTS.md`
directs you to skip it. Otherwise run `mstack update --check` from that root
with a short execution timeout.

- If the check succeeds and reports skill updates, dependencies to install, or
  `Skill attributes need updating: .agents/.gitattributes`, run `mstack update`,
  including in unattended runs, unless the user or the project's `AGENTS.md`
  directs you to defer updates. The attributes message can appear alongside
  `Already current`. Use a short timeout that allows graceful cancellation and
  report the result. When deferring updates, report the deferred changes and
  continue with the installed skills.
- If the check succeeds and reports no pending changes, continue.
- If mstack is unavailable or either command returns a nonzero exit or times
  out, report the issue and any conflicting paths. Preserve local edits and
  continue with the installed skills. If the check fails, report any changes
  it listed as deferred.

## Implement the change

Use subagents to parallelize independent work.
