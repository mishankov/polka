---
name: release-project
description: Prepare and publish a Polka minor or patch release by reviewing documentation, writing Russian and English release notes, verifying macOS CI, merging a preparation PR, and running the release GitHub Action.
---

# Release Polka

Use this skill for a release of this project. Creating or editing the skill does not request a release. Honor preparation-only requests. A full release request authorizes the PR, CI, merge, and workflow steps within the agreed release scope; do not ask for the same authorization again.

Paths and commands below are relative to the repository root.

## Establish the source and version

- Read repository instructions and inspect the working tree. Confirm the repository and default branch using the remote and authenticated GitHub access. They are currently `mishankov/polka` and `master`; verify them on each release.
- Fetch the remote default branch and tags before auditing or choosing a version. Use a clean branch from the remote default branch, preferably `codex/release-prep-VERSION`. If switching would disturb existing work or include unpublished local commits, use an isolated worktree. Preserve unrelated work; never reset or automatically stash it.
- Use the explicit version or `minor`/`patch` bump requested by the user. If neither is specified, ask which while continuing the documentation audit. Inspect published, non-draft, non-prerelease releases and use the highest stable semantic version as the baseline. Ask for an initial version if there is no stable baseline. `package.json` is not the release baseline.
- Read `.github/workflows/release.yml`, `.github/workflows/build.yml`, `scripts/release-config.mjs`, `scripts/release-version.mjs`, `scripts/release-notes.mjs`, `scripts/release.mjs`, and `docs/macos.md`. The release tag drives the bundle version and artifact names; do not add an unrelated `package.json` version bump.
- Inspect any existing tag, draft, published release, or active release run for the chosen version. Resume an identified attempt rather than creating duplicates or overwriting an unrelated release.

## Audit documentation and write bilingual notes

Compare changes since the baseline release and current behavior with `README.md` and the relevant `docs/` files, especially `macos.md`, `data.md`, `architecture.md`, and `validation.md`. Correct stale feature claims, UI labels, shortcuts, defaults, supported platforms, installation steps, local data behavior, signing requirements, and validation claims. This is a macOS 27+ Apple silicon app, not a multiplatform app; it has no separate promotional site workflow.

Inspect screenshots actually referenced by the documentation. Refresh stale images when needed, using real UI captures and a disposable profile (`EVERYTHING_PROFILE=/absolute/test/profile`). Keep private clipboard contents and credentials out of screenshots. Do not invent a screenshot or website refresh requirement if none exists. Report anything that could not be verified.

Create `release-notes/VERSION.json` in the release source commit, without the tag's optional `v` prefix:

```json
{
  "ru": "• Описание изменений для пользователя.\n• Исправления и ограничения, относящиеся к этому выпуску.",
  "en": "• User-facing changes.\n• Fixes and limitations relevant to this release."
}
```

Both fields must contain nonempty text, at most 20,000 characters each. Describe the same changes in both languages. Ground notes in the actual diff and behavior; do not claim untested fixes. Notes are shown as plain text in the app, so use readable lines and bullets rather than relying on HTML or Markdown rendering.

Validate and preview the GitHub description from the repository root:

```bash
node scripts/release-notes.mjs vX.Y.Z /tmp/polka-release-notes.md
```

The same validated text goes into the appcast and the GitHub Release description. Editing a GitHub Release body alone does not change the app's notes. The preparation job reads notes from the selected release commit before creating a new draft/tag or starting macOS jobs. New releases require bilingual notes; the legacy exception exists only to retry existing releases whose source predates note support.

## Review, validate, and merge preparation

Present the chosen version, source/baseline, documentation corrections, both translations, relevant captures, and validation evidence before pushing. For a preparation-only request, stop with these reviewable changes. For a full release request, continue with the authorized workflow unless a material decision or requested review remains unresolved.

Run `git diff --check` and validate the notes. Documentation, notes, and skill-only edits do not by themselves require rebuilding an unchanged app. For changed app/build inputs, use the appropriate project checks: `npm ci`, `npm run build:prepare`, `npm run verify:desktop`, `npm run verify:workflows`, and updater tests when affected. GUI suites share clipboard, focus, and shortcuts; run them sequentially locally or on separate CI runners. Reuse a freshly prepared build with `--prebuilt`; this option checks outputs exist, not that they match the source.

Commit only release preparation changes, push the branch, and create a PR against the verified default branch. Use a body file for multiline `gh pr create` descriptions. Reuse an existing preparation PR on resumption. In T3 Code, link the PR to the thread; when its PR watcher is available, use it and resume on its wake-up instead of running a polling watcher.

Require all branch-protection checks and reviews on the latest PR head. For app, dependency, native helper, packaging, or workflow changes, require the complete `build.yml` run: both source suites, packaging, all updater modes (ad-hoc, self-signed, signing migration), and aggregate `Verify and package macOS arm64`. Never treat pending, cancelled, missing, or failed required checks as success.

For documentation/notes/skill-only changes, a successful build on an earlier default-branch SHA can supply app validation evidence if the intervening diff proves app and build inputs unchanged. Record its SHA and run URL; this does not waive branch protection. The release workflow still validates and packages the exact release source on macOS.

Fix failures within scope, and rerun a demonstrated transient failure at most once before reassessing. Do not change product behavior merely to get a green check. Merge by a supported method, pinning the expected head when possible (`gh pr merge --match-head-commit SHA`). Follow a required merge queue to completion and verify the actual merged commit; enabling auto-merge is not completion.

## Dispatch and follow the release

Recheck the remote baseline, selected version, default-branch source, notes file, CI evidence, tag/release state, and active runs immediately before dispatch. If another release advanced the baseline, recompute the requested bump and rename/revalidate the notes file before releasing. If new product/build changes entered the source, review the notes and require passing CI covering them.

For a fresh version, `workflow_dispatch` resolves the current default branch and creates its tag itself; `--ref` selects workflow code and does not pin the release source. Existing tags resolve to their tagged commit; drafts without tags resolve from their `targetCommitish`. Prefer manual dispatch, which publishes the draft only after checks and uploads succeed. A `release: published` trigger starts from an already public release.

With verified values, run:

```bash
gh workflow run release.yml --repo OWNER/REPO --ref DEFAULT_BRANCH -f tag=vX.Y.Z -f prerelease=false
```

Use `prerelease=true` only when requested; prereleases do not appear in the stable latest feed. Identify the dispatched run by workflow, event, branch, creation time, and requested tag. If the dispatch response is ambiguous, inspect runs and release state before retrying. Do not blindly follow the latest run when another release exists.

Follow the run to a terminal conclusion, with bounded waits and progress updates. Verify preparation's source SHA and that the tag resolves to the intended tested commit containing the notes/preparation merge. If it differs unexpectedly, stop further release actions and report the mismatch. On failure or cancellation, inspect logs, draft/tag, and uploaded assets before one justified retry of the same target. Never retarget a published tag or replace published archives; only draft staging assets may be clobbered.

The release environment already holds Sparkle's Ed25519 keys and the persistent self-signed application identity. Verify required secret/variable names are configured without reading or printing their values: `SPARKLE_PUBLIC_KEY`, `SPARKLE_PRIVATE_KEY`, `POLKA_SIGNING_P12`, `POLKA_SIGNING_PASSWORD`, `POLKA_SIGNING_CERT_SHA1`. Keep the same signing identity across releases. Production must not fall back to ad-hoc signing; do not introduce Apple notarization credentials or regenerate certificates as a routine release step. See `docs/macos.md` for signing migration and permission acceptance.

## Verify the published result

Success requires a successful release workflow and a published release with the intended stable/prerelease status and these assets:

- `polka-VERSION-arm64.dmg`
- `polka-VERSION-arm64.zip`
- `checksums.txt`
- `appcast.xml`

Verify both languages in the GitHub description and corresponding appcast `description` JSON. Check the appcast version, minimum macOS, exact immutable ZIP URL, byte length, and Ed25519 signature; use `verifyReleaseMetadata` when checking downloaded assets against the configured public key. Uploads put archives/checksums first, appcast next, and synchronize the description before publishing a draft. For a stable release, verify the stable latest feed resolves to this version; never manually promote an older version to latest.

Report the released version, preparation PR (or no-change finding), validated source SHA, workflow result/link, and release/download link. Dispatch or asset upload alone is not a completed release. If blocked, report the exact remaining step and recovery information. Users running a version without the notification interface must install that interface first; the new card appears for subsequent updates.
