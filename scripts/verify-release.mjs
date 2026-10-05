import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { verifyReleaseMetadata } from './release-metadata.mjs';
const pkg = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
const bundle = 'release/mac-arm64/Polka.app';
const image = `release/${pkg.name}-${pkg.version}-arm64.dmg`;
await verifyReleaseMetadata(pkg, 'release');
for (const [cmd, args] of [
  ['codesign', ['--verify', '--deep', '--strict', '--verbose=2', bundle]],
  ['spctl', ['--assess', '--type', 'execute', '--verbose=2', bundle]],
  ['xcrun', ['stapler', 'validate', bundle]],
  ['hdiutil', ['verify', image]],
  ['npm', ['run', 'test:packaged']],
  ['npm', ['run', 'test:packaged:workflows']],
]) {
  const r = spawnSync(cmd, args, { stdio: 'inherit' });
  if (r.status !== 0) process.exit(r.status || 1);
}
