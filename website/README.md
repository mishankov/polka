# Polka promo site

A standalone static site using Polka’s logo and ivory, terracotta, and graphite palette. Copy follows the native Swift app and the v0.9.0 release (source commit `7681f99`), with the snippet editor height fix in this branch. Assets, fonts, and scripts are local; there are no analytics.

The website has its own Node tooling. The native app remains independent of npm.

```sh
cd website
npm ci
npm run dev
npm run build
npm run preview
npm test
```

Deploy `website/dist` to a static host. Assets use relative paths, including when hosted in a subdirectory. Downloads link to the latest GitHub Release; installation guidance links to `docs/installation.md`.

## Screenshots

Hero images are unedited captures from the native Swift app's desktop harness, using an isolated profile and synthetic data. The surrounding wallpaper is decorative. From the repository root, run `./polka desktop core`; the harness owns the shared desktop lock and writes captures to `artifacts/desktop/native-smoke/`.

Copy `launcher.png`, `clipboard-color-history.png`, `snippet-editor.png`, `emoji.png`, and `files-selection.png` to their corresponding `website/assets/polka-*.png` files. The launcher frame shows the built-in tools from the isolated fixture. No personal clipboard or Keychain data is used. For these compositor-backed Liquid Glass images, we used `POLKA_NATIVE_SMOKE_WINDOW_CAPTURE=1` and temporarily extended its named-frame filter to the five frames above. That capture-only edit is not shipped. The default bitmap path can omit SwiftUI content; inspect every regenerated frame before replacing an asset. Window capture requires screen capture access. The updated snippet frame is captured directly by the supported `snippet-editor` window-capture path after fixing the editor height.

## Keyboard review

The page has navigation links and a screenshot tablist, with no Create/Save/Edit/Delete commands. Native links activate with Enter; tabs support Left/Right, Home/End, and native Enter/Space. The arrow hints are visible and exposed through `aria-keyshortcuts`. Tab changes share one action handler for pointer and keyboard, skip disabled tabs, and ignore composition, repeated and modified key events. All app shortcuts printed in feature copy describe the desktop app, not global website bindings.

`npm test` uses Playwright with installed Chrome to verify navigation, tab/panel state, focus, keyboard guards, images, and mobile overflow. Run `npm exec playwright install chromium` and set `POLKA_TEST_BROWSER=chromium` if Chrome is unavailable.
