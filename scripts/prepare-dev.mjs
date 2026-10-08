import { createRequire } from 'node:module';
import { stat } from 'node:fs/promises';
import { buildNativeHelpers, nativeHelpers } from './build.mjs';

// Resolve the lazily downloaded binary before Vite or Playwright tries to start it.
const require = createRequire(import.meta.url);
const electron = require('electron');
await stat(electron);
const stale = await Promise.all(
  nativeHelpers.map(async ({ source, output, dependencies = [] }) => {
    const inputs = await Promise.all([source, ...dependencies].map((path) => stat(path)));
    const built = await stat(output).catch(() => undefined);
    return !built || inputs.some((input) => built.mtimeMs < input.mtimeMs);
  }),
);
const helpers = nativeHelpers.filter((_, index) => stale[index]);
if (helpers.length) buildNativeHelpers(helpers);
