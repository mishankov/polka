import { readFile, access, mkdir, writeFile, stat } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { releasePackage, releaseConfig, releaseArtifactNames } from './release-config.mjs';
import { appcastXml } from './release-metadata.mjs';
import { join } from 'node:path';
import { assertPreparedApp } from './prepared-app.mjs';
import { withSigningKeychain } from './signing-certificate.mjs';
const pkg = releasePackage(
  JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8')),
  process.env,
);
const config = releaseConfig(pkg, process.env);
if (process.platform !== 'darwin' || process.arch !== 'arm64')
  throw Error('Build releases on an Apple silicon Mac.');
if (!process.env.SPARKLE_PRIVATE_KEY)
  throw Error('SPARKLE_PRIVATE_KEY is required to sign update archives.');
if (process.argv.includes('--publish') && !process.env.GH_TOKEN)
  throw Error('GH_TOKEN is required for draft release upload.');
await withSigningKeychain(process.env, async (publicEnv) => {
  await mkdir('artifacts', { recursive: true });
  await writeFile('artifacts/release-config.json', JSON.stringify(config, null, 2));
  function run(command, args) {
    const result = spawnSync(command, args, { stdio: 'inherit', env: publicEnv });
    if (result.status !== 0)
      throw Error(`${command} failed (${result.status ?? 'could not start'}).`);
  }
  if (process.argv.includes('--prebuilt')) await assertPreparedApp();
  else run('npm', ['run', 'build:prepare']);
  run('npm', ['run', 'sparkle:build']);
  run('npx', [
    'electron-builder',
    '--config',
    'artifacts/release-config.json',
    '--mac',
    'dmg',
    'zip',
    '--arm64',
    '--publish',
    'never',
  ]);
  const env = process.env;
  const zip = releaseArtifactNames(pkg).find((name) => name.endsWith('.zip'));
  const archive = join('release', zip);
  // Feed the secret through stdin, never through process arguments or a config file.
  const signed = spawnSync(
    'node_modules/electron-sparkle-updater/native/vendor/bin/sign_update',
    ['--ed-key-file', '-', '-p', archive],
    { input: env.SPARKLE_PRIVATE_KEY, encoding: 'utf8', env: publicEnv },
  );
  if (signed.status !== 0)
    throw Error('Sparkle archive signing failed. Check the release signing key.');
  const signature = signed.stdout.trim();
  await writeFile(
    'release/appcast.xml',
    appcastXml(pkg, env.RELEASE_REPOSITORY, signature, (await stat(archive)).size),
  );
  run('npm', ['run', 'release:verify']);
  if (process.argv.includes('--publish')) {
    const sha = spawnSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' });
    if (sha.status !== 0) throw new Error('Release must be built from a Git commit.');
    const artifacts = releaseArtifactNames(pkg).map((name) => `release/${name}`);
    await Promise.all(artifacts.map((path) => access(path)));
    run('gh', [
      'release',
      'create',
      pkg.releaseTag,
      ...artifacts,
      '--draft',
      '--repo',
      env.RELEASE_REPOSITORY,
      '--target',
      sha.stdout.trim(),
      '--title',
      `${pkg.build.productName} ${pkg.version}`,
      '--notes',
      'Self-signed macOS arm64 build with a persistent code identity and authenticated Sparkle updates. Review acceptance results before publishing.',
    ]);
  }
});
