import { mkdirSync, rmSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { cli, run } from './lib/command.mjs';

export const nativeHelpers = [
  {
    source: 'native/MediaProbe.swift',
    output: 'build/media-probe',
    frameworks: ['CoreAudio', 'CoreMediaIO', 'AVFoundation'],
  },
  {
    source: 'native/ClipboardProbe.swift',
    output: 'build/clipboard-probe',
    frameworks: ['AppKit'],
  },
  { source: 'native/SyncDiscovery.swift', output: 'build/sync-discovery', frameworks: [] },
];

export function buildNativeHelpers(helpers = nativeHelpers) {
  mkdirSync('build', { recursive: true });
  for (const { source, output, frameworks } of helpers)
    run('swiftc', [
      '-O',
      source,
      '-o',
      output,
      ...frameworks.flatMap((name) => ['-framework', name]),
    ]);
}

export function main(args = process.argv.slice(2)) {
  const { values } = parseArgs({
    args,
    options: { native: { type: 'boolean' }, help: { type: 'boolean' } },
  });
  if (values.help) {
    console.log(
      'Usage: npm run build -- [--native]\nBuild the app and Swift helpers; --native builds only the helpers.',
    );
    return;
  }
  if (!values.native) {
    rmSync('out', { recursive: true, force: true });
    run('node_modules/.bin/electron-vite', ['build']);
  }
  buildNativeHelpers();
}

cli(import.meta.url, () => main());
