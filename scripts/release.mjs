import { readFile, access, mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { releaseConfig, releaseArtifactNames } from './release-config.mjs';
const pkg = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
const config = releaseConfig(pkg, process.env);
if (process.platform !== 'darwin' || process.arch !== 'arm64')
  throw Error('Build signed releases on an Apple silicon Mac.');
if (process.argv.includes('--publish') && !process.env.GH_TOKEN)
  throw Error('GH_TOKEN is required for draft release upload.');
await mkdir('artifacts', { recursive: true });
await writeFile('artifacts/release-config.json', JSON.stringify(config, null, 2));
function run(command, args) {
  const result = spawnSync(command, args, { stdio: 'inherit', env: process.env });
  if (result.status !== 0) process.exit(result.status || 1);
}
run('npm', ['run', 'build']);
run('npm', ['run', 'native:build']);
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
run('npm', ['run', 'release:verify']);
if (process.argv.includes('--publish')) {
  const sha = spawnSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' });
  if (sha.status !== 0) throw new Error('Release must be built from a Git commit.');
  const artifacts = releaseArtifactNames(pkg).map((name) => `release/${name}`);
  await Promise.all(artifacts.map((path) => access(path)));
  run('gh', [
    'release',
    'create',
    `v${pkg.version}`,
    ...artifacts,
    '--draft',
    '--repo',
    env.RELEASE_REPOSITORY,
    '--target',
    sha.stdout.trim(),
    '--title',
    `Polka ${pkg.version}`,
    '--notes',
    'Signed and notarized macOS arm64 build. Review acceptance results before publishing.',
  ]);
}
