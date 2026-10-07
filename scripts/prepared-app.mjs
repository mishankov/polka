import { access } from 'node:fs/promises';

/** Explicit --prebuilt callers must first run build:prepare in this checkout. */
export async function assertPreparedApp() {
  const files = [
    'out/main/index.js',
    'out/main/worker.js',
    'out/preload/index.js',
    'out/preload/media-indicator.js',
    'out/renderer/index.html',
    'out/renderer/media-indicator.html',
    'build/media-probe',
    'build/clipboard-probe',
    'build/sync-discovery',
    'build/image-text',
    'build/file-shelf-probe',
  ];
  for (const file of files) {
    try {
      await access(file);
    } catch {
      throw Error(`Missing prepared app output ${file}. Run npm run build:prepare first.`);
    }
  }
}
