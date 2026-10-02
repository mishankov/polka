# Backlog and current scope

Updated 2 October 2026 from the owner's review of the requirements audit. This file records scope decisions; it does not replace the original specification or claim deferred features are finished.

## Current implementation scope

- Documents/editors: folders, dropped files, batch previews, transformation chains, richer raster operations.
- Extensions/integrations: shared themed UI, curated bundled dependencies, isolated recoverable UI execution, trusted capability adapters.
- Import/export: deliberate demonstration data, reconnection report, progress and cancellation.
- Distribution: complete update UI and lifecycle, reproducible signed-release automation and verification.
- Provider verification: automated protocol mocks and local end-to-end fixtures belong to implementation. The owner performs live-provider/model acceptance; no live credentials are requested for this work.

## Deferred by owner

| Area | Follow-up scope | Acceptance target |
|---|---|---|
| Cross-app functionality | Publish/invoke actions and events; richer dependency graph and export dependency choices | Explicit grant, immediate revocation, dependency consequences shown before changes |
| Changes and recovery | Interactive three-way conflict resolution, migration transformation plans, split/merge programmable apps | Preserve personal logic/data, preview conflicts and changed references, transactional activation |
| Background work and macOS | Visual workflow editor, more reconnecting watchers, shortcut settings, app-specific menu-bar UI | Closed-window operation, explicit effects and permissions, native sleep/wake and conflict tests |
| Diagnostics and customization | Central logs/support bundles, full localization/a11y audit, character variants, configurable home widgets | Secret-safe diagnostics, keyboard-complete workflows, minimal home stays the default |

## External release/acceptance dependencies

- Owner-provided Developer ID and Apple notarization credentials, plus the intended release repository.
- Live-provider acceptance is owner-owned.
- Real macOS acceptance (other apps' camera/mic use, sleep/wake, permission changes, displays, clean second Mac, installed version-to-version upgrades) remains distinct from automated fixtures.
- Global screen-sharing and mute detection are unsupported with the current public adapter; unknown signals must never be reported as inactive.
