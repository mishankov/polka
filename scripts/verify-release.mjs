import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { releasePackage, releaseConfig } from './release-config.mjs';
import { verifyReleaseMetadata } from './release-metadata.mjs';
import { verifySignedBundle } from './sign-macos.mjs';
import { signingFingerprint } from './signing-certificate.mjs';
const pkg = releasePackage(
  JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8')),
  process.env,
);
const config = releaseConfig(pkg, process.env);
const bundle = `release/mac-arm64/${pkg.build.productName}.app`;
const image = `release/${pkg.name}-${pkg.version}-arm64.dmg`;
verifySignedBundle(bundle, pkg.build.appId, signingFingerprint(process.env));
await verifyReleaseMetadata(
  pkg,
  'release',
  config.extraMetadata.release.repository,
  config.extraMetadata.release.publicKey,
);
for (const [cmd, args] of [
  ['codesign', ['--verify', '--deep', '--strict', '--verbose=2', bundle]],
  ['hdiutil', ['verify', image]],
  ['npm', ['run', 'test:packaged']],
]) {
  const r = spawnSync(cmd, args, { stdio: 'inherit' });
  if (r.status !== 0) process.exit(r.status || 1);
}
