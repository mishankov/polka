import { createRequire } from 'node:module';
import { stat } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';

// Resolve the lazily downloaded binary before Vite or Playwright tries to start it.
const require = createRequire(import.meta.url);
const electron = require('electron');
await stat(electron);
const helpers = [
  ['native/MediaProbe.swift', 'build/media-probe'],
  ['native/ClipboardProbe.swift', 'build/clipboard-probe'],
  ['native/SyncDiscovery.swift', 'build/sync-discovery'],
  ['native/FileShelfProbe.swift', 'build/file-shelf-probe'],
];
const stale = await Promise.all(
  helpers.map(async ([source, output]) => {
    const input = await stat(source);
    const built = await stat(output).catch(() => undefined);
    return !built || built.mtimeMs < input.mtimeMs;
  }),
);
if (stale.some(Boolean)) execFileSync('npm', ['run', 'native:build'], { stdio: 'inherit' });
