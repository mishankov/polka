import { spawnSync } from 'node:child_process';
// Pinned bridge 0.5.2 has no staging cancellation API. Keep this small extension
// reproducible across npm ci; fail closed if upstream source no longer matches.
const args = ['--directory=node_modules/electron-sparkle-updater', 'scripts/sparkle-bridge.patch'];
const check = spawnSync('git', ['apply', '--check', ...args], { stdio: 'ignore' });
if (check.status === 0) {
  const patch = spawnSync('git', ['apply', ...args], { stdio: 'inherit' });
  if (patch.status !== 0) process.exit(patch.status || 1);
} else if (
  spawnSync('git', ['apply', '--reverse', '--check', ...args], { stdio: 'ignore' }).status !== 0
) {
  throw Error('Sparkle bridge source changed; review the cancellation patch before building.');
}
const result = spawnSync(
  'node_modules/.bin/electron-sparkle-updater',
  ['rebuild', '--arch', 'arm64'],
  { stdio: 'inherit' },
);
process.exit(result.status ?? 1);
