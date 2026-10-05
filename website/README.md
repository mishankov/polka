# Polka promo site

A standalone, responsive static site using Polka’s production logo and its ivory, terracotta, and graphite palette. The hero shows real screenshots captured from the running Electron app with an isolated profile. The surrounding wallpaper is decorative. The Apps and Calculator controls switch screenshots; they do not simulate the app. All assets are local; no fonts, analytics, or remote scripts are loaded.

From the repository root:

```sh
npm ci
npm run site:dev
npm run site:build
npm run site:preview
```

Deploy the contents of `out/website` to any static web host. The site uses relative asset paths and can be served from a subdirectory. Download links point to the latest GitHub Release, where users choose the DMG. App requirements and behavior are sourced from the repository README; update the site when those change.
