import test from 'node:test';
import assert from 'node:assert/strict';
// @ts-expect-error Pure build-time JavaScript shared with the release command.
import { releaseConfig } from '../scripts/release-config.mjs';
test('release builds require explicit owner, signing and notarization, with draft publishing', () => {
  const pkg = {
    build: {
      mac: { target: ['dmg', 'zip'], identity: '-', hardenedRuntime: false, notarize: false },
    },
  };
  assert.throws(() => releaseConfig(pkg, {}), /RELEASE_REPOSITORY/);
  assert.throws(() => releaseConfig(pkg, { RELEASE_REPOSITORY: 'owner/app' }), /certificate/);
  const env = {
    RELEASE_REPOSITORY: 'owner/app',
    CSC_LINK: 'secret',
    CSC_KEY_PASSWORD: 'secret',
    APPLE_ID: 'owner',
    APPLE_APP_SPECIFIC_PASSWORD: 'secret',
    APPLE_TEAM_ID: 'TEAM',
  };
  const cfg = releaseConfig(pkg, env);
  assert(cfg.forceCodeSigning);
  assert(cfg.mac.notarize);
  assert.equal(cfg.mac.identity, undefined);
  assert(cfg.mac.hardenedRuntime);
  assert.equal(cfg.mac.artifactName, '${name}-${version}-${arch}.${ext}');
  assert.equal(cfg.publish[0].releaseType, 'draft');
  assert.equal(cfg.extraMetadata.release.repository, 'owner/app');
  assert(!JSON.stringify(cfg).includes('secret'));
});

test('signed release filenames match GitHub-safe update URLs and uploaded assets', async () => {
  const { mkdtemp, writeFile, rm } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { createHash } = await import('node:crypto');
  // @ts-expect-error Pure build-time JavaScript.
  const { releaseArtifactNames } = await import('../scripts/release-config.mjs');
  // @ts-expect-error Pure build-time JavaScript.
  const { verifyReleaseMetadata } = await import('../scripts/release-metadata.mjs');
  const pkg = { name: 'everything-app', version: '0.2.0' };
  const directory = await mkdtemp(join(tmpdir(), 'everything-release-'));
  try {
    const names: string[] = releaseArtifactNames(pkg);
    assert(names.every((name) => /^[A-Za-z0-9._-]+$/.test(name)));
    const data = Buffer.from('release fixture');
    const files = names
      .filter((name) => name.endsWith('.zip') || name.endsWith('.dmg'))
      .map((url) => ({
        url,
        size: data.length,
        sha512: createHash('sha512').update(data).digest('base64'),
      }));
    const zip = files.find((file) => file.url.endsWith('.zip'))!;
    for (const name of names) await writeFile(join(directory, name), data);
    const metadata = { version: pkg.version, files, path: zip.url, sha512: zip.sha512 };
    await writeFile(join(directory, 'latest-mac.yml'), JSON.stringify(metadata));
    assert.deepEqual(await verifyReleaseMetadata(pkg, directory), names);
    await writeFile(
      join(directory, 'latest-mac.yml'),
      JSON.stringify({ ...metadata, path: 'Everything App-0.2.0-arm64.zip' }),
    );
    await assert.rejects(verifyReleaseMetadata(pkg, directory), /ZIP asset/);
    await writeFile(join(directory, 'latest-mac.yml'), JSON.stringify(metadata));
    await writeFile(join(directory, zip.url), 'modified bytes');
    await assert.rejects(verifyReleaseMetadata(pkg, directory), /integrity mismatch/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
