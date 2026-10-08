# UI keyboard shortcuts

- Always include a keyboard shortcut when adding a primary UI command such as Create, Save, Edit, or Delete. Prefer familiar macOS conventions, such as ⌘N for Create/New. Check existing bindings before choosing one; report any unavoidable conflict instead of silently omitting the shortcut.
- Show the shortcut on the button, in its tooltip, or in its menu, and expose `aria-keyshortcuts` where applicable.
- Use the same action handler for the button and shortcut. Scope in-app shortcuts to the active surface, respect disabled and busy states and open dialogs, and preserve drafts. Handle IME composition, key repeat, and non-English keyboard layouts without stealing normal text input.
- Before finishing a UI change, explicitly review shortcuts and verify the main keyboard flow. Use `tests/desktop/desktop-test.ts` with its shared lock, isolated profiles, and synthetic data for desktop checks; do not touch the user's clipboard or interfere with other app instances.
