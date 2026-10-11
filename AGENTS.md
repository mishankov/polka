# UI keyboard shortcuts

- Always include a keyboard shortcut when adding a primary UI command such as Create, Save, Edit, or Delete. Prefer familiar macOS conventions, such as ⌘N for Create/New. Check existing bindings before choosing one; report any unavoidable conflict instead of silently omitting the shortcut.
- Show the shortcut on the button, in its tooltip, or in its menu, and expose AppKit accessibility shortcut metadata where applicable.
- Use the same action handler for the button and shortcut. Scope in-app shortcuts to the active surface, respect disabled and busy states and open dialogs, and preserve drafts. Handle IME composition, key repeat, and non-English keyboard layouts without stealing normal text input.
- Before finishing a UI change, explicitly review shortcuts and verify the main keyboard flow. Run `./polka desktop core` using `tools/Sources/PolkaTools/Desktop.swift` with its shared lock, isolated profiles, and synthetic data for desktop checks; do not touch the user's clipboard or interfere with other app instances.

# Desktop test isolation

- Local desktop, focus, drag-and-drop and real updater checks run automatically in the managed macOS VM through `tools/Sources/PolkaTools/DesktopVM.swift`. Use the normal `./polka desktop ...` and `./polka verify` commands; the runner compiles current code and test executables on the host, starts and stops the guest, shares prepared outputs and a read-only source snapshot, and copies diagnostics back. Run the compiled CLI directly in the guest; never invoke guest SwiftPM, swiftc or asset compilation. Disposable updater signing keys stay inside the guest. Run `./polka vm setup` once and `./polka vm doctor` to diagnose guest readiness.
- Never fall back to the user's desktop when the VM is unavailable. `--host-desktop` and `POLKA_DESKTOP_BACKEND=host` explicitly opt into foreground testing and require the user's instruction to use their desktop. CI continues to run all required desktop checks directly on its own runner.
- Keep host clipboard, audio, USB devices, personal profiles and signing credentials out of the guest. Preserve the shared VM lock across worktrees and mandatory test assertions; report failed or incomplete guest validation accurately.

# CI build budget

- Required checks in `.github/workflows/build.yml` have a five-minute execution target and a ten-minute hard limit. The macOS jobs run independently in parallel, so the budget is the longest job duration from runner start to completion, including setup, cache operations, tests, artifact uploads and cleanup. Exclude every runner's queue delay, including staggered starts; report queues and the wall-clock span separately. Every macOS job also has a ten-minute timeout.
- Exceeding the five-minute target produces a warning; exceeding the ten-minute hard limit blocks CI. Treat overruns as performance regressions to fix. Keep coverage thresholds, regression fixtures, desktop smoke and real updater checks mandatory; do not skip checks, weaken assertions or raise the hard limit without explicit user instruction.
- Reuse compilation outputs within a run and compatible Swift caches across runs. Before finishing a CI performance change, inspect job and step timings and verify the budget check. Report whether hosted CI has actually met the five-minute target or only passed the ten-minute hard limit.
