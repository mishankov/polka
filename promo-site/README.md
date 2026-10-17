# Polka promo site

A responsive, dependency-free landing page in English and Russian, using Polka's existing icon and real app screenshots. Product claims and compatibility follow the repository README.

The design uses a compact two-column introduction, one real app screenshot, plain feature descriptions, and three installation methods. “What goes on the shelf” introduces smart input and search first, then gives each of the six built-in apps its own description, matching the catalog in `native-app/Sources/PolkaCore/Search.swift`. Colors come from Polka's ivory, graphite, and terracotta icon. The open shelf is shown flush with the display's top edge, with its native bottom corners. No notch, connector, or app outline is drawn in CSS.

Preview from this directory:

```sh
python3 serve.py
```

Open http://127.0.0.1:4173 on this Mac, or http://<this-Mac-IP>:4173 from another device on the same network. The server binds to all interfaces (`0.0.0.0`) and disables caching so edits appear on reload. English is served at `/` and Russian at `/ru/`. Both pages use relative asset and language links, so the same files also work beneath the GitHub Pages project path `/polka/`. Language navigation uses ordinary links and works without JavaScript. Each page has a translated title, description, alternative text, accessibility labels, canonical URL, and `hreflang` alternatives. App screenshots remain unedited real captures.

JavaScript reveals only the shelf screenshot once when the document opens and accessible installation tabs for all three methods from `docs/installation.md`: the installer script, DMG + Terminal, and DMG + System Settings. The reveal uses the native app’s 96 × 3-point closed mask for this unnotched VM capture, expands to the full screenshot in 100 ms with ease-out after a 350 ms hold, and keeps the image at its final size. Hero text and the demonstration frame stay still. It does not replay on scroll or tab changes, respects reduced motion, and resolves to the open state on resize or page exit. A decode timeout keeps a stalled image from remaining clipped. Without JavaScript, the hero is visible and all three installation methods remain readable.

Installation tabs support Left/Right, Home/End, Enter/Space, and normal Tab navigation. They share one selection handler and ignore IME composition, repeats, and modifier combinations. Download and navigation links use standard browser keyboard behavior; no global shortcuts override browser or Polka bindings. The permission-error disclosure uses native HTML keyboard behavior. Visible focus and a skip link are included. The page has no clipboard-writing control.

The icon is copied from `build/icon.png`. `dist/assets/shelf-open.png` is an unedited compositor capture of the actual native window, generated with `POLKA_NATIVE_SMOKE_WINDOW_CAPTURE=1 ./polka desktop core` in the managed macOS VM. The source artifact is `artifacts/desktop/native-smoke/controls-clipboard.png`; its entry uses synthetic fixture data. CSS supplies only the surrounding mat. The reveal temporarily clips the image; it never scales or redraws the app’s contents. Keep the image in sync when updating the app.

The feature section has its heading above full-width capability rows. Every feature has a small, unedited screenshot, placed beside its description on wider screens and underneath on phones. They are lazy-loaded and have descriptive alternative text. The search example and built-in app captures come from the same isolated VM workflow, with compositor capture temporarily enabled for the search conversion, selected files, and System Status. No capture-only changes remain in the native app source.

| Site asset | Original capture |
| --- | --- |
| `feature-search.png` | `artifacts/desktop/native-smoke/promo-smart-input.png` |
| `feature-clipboard.png` | `artifacts/desktop/native-smoke/controls-clipboard.png` |
| `feature-snippets.png` | `artifacts/desktop/native-smoke/controls-snippets.png` |
| `feature-files.png` | `artifacts/desktop/native-smoke/files-selection.png` |
| `feature-screenshots.png` | `docs/screenshots/screenshot-editor.png` |
| `feature-emoji.png` | `artifacts/desktop/native-smoke/controls-emoji.png` |
| `feature-system-status.png` | `artifacts/desktop/native-smoke/system-status-normal.png` |


## GitHub Pages

`.github/workflows/pages.yml` validates the site on pull requests, then uploads `promo-site/dist/` and deploys it on every push to `master`, regardless of which files changed. A manual run from `master` can redeploy the current version. Other branches and pull requests only run validation. The workflow uses Ubuntu, takes no macOS build capacity, and requires no deployment secret. Deployment uses GitHub's `github-pages` environment with the standard Pages and OIDC permissions, following the [GitHub Pages workflow guide](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

Published URLs after the first successful deployment:

- English: https://mishankov.github.io/polka/
- Russian: https://mishankov.github.io/polka/ru/

The repository's Pages publishing source is configured as **GitHub Actions** (`build_type: workflow`), with HTTPS enforced. The files and workflow must reach `master` before the first automatic deployment; local edits alone do not publish the site.

Run the same static checks locally:

```sh
python3 promo-site/check.py
```

The checker validates local assets, anchors, unique IDs, accessibility references, both language links and metadata, and paths for GitHub Pages project hosting. When editing page content, update both `dist/index.html` and `dist/ru/index.html`. Shared presentation and behavior live in `dist/styles.css` and `dist/site.js`.
