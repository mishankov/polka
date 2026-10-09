# UI keyboard shortcuts

- Always include a keyboard shortcut when adding a primary UI command such as Create, Save, Edit, or Delete. Prefer familiar macOS conventions, such as ⌘N for Create/New. Check existing bindings before choosing one; report any unavoidable conflict instead of silently omitting the shortcut.
- Show the shortcut on the button, in its tooltip, or in its menu, and expose AppKit accessibility shortcut metadata where applicable.
- Use the same action handler for the button and shortcut. Scope in-app shortcuts to the active surface, respect disabled and busy states and open dialogs, and preserve drafts. Handle IME composition, key repeat, and non-English keyboard layouts without stealing normal text input.
- Before finishing a UI change, explicitly review shortcuts and verify the main keyboard flow. Run `./polka desktop core` using `tools/Sources/PolkaTools/Desktop.swift` with its shared lock, isolated profiles, and synthetic data for desktop checks; do not touch the user's clipboard or interfere with other app instances.

# CI build budget

- Required checks in `.github/workflows/build.yml` must pass within five minutes of CI execution. The macOS jobs run independently in parallel, so the budget is the longest job duration from runner start to completion, including setup, cache operations, tests, artifact uploads and cleanup. Exclude every runner's queue delay, including staggered starts; report queues and the wall-clock span separately. Every macOS job also has a five-minute timeout.
- Treat a budget failure as a CI regression to fix. Keep coverage thresholds, regression fixtures, desktop smoke and real updater checks mandatory; do not skip checks, weaken assertions or increase the budget to make CI green.
- Reuse compilation outputs within a run and compatible Swift caches across runs. Before finishing a CI performance change, inspect job and step timings and verify the budget check. Report whether hosted CI has actually demonstrated a passing run under five minutes.
