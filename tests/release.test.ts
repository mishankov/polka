import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error Pure build-time JavaScript shared with the release command.
import { releaseConfig, releaseArtifactNames } from '../scripts/release-config.mjs';
// @ts-expect-error Pure build-time JavaScript.
import { appcastXml, verifyReleaseMetadata } from '../scripts/release-metadata.mjs';

const pkg = {
  name: 'everything-app',
  version: '0.2.0',
  build: {
    productName: 'Everything App',
    files: ['out/**/*', '!**/node_modules/electron-sparkle-updater/native/**'],
    mac: {
      target: ['dmg', 'zip'],
      minimumSystemVersion: '27.0',
      extendInfo: { LSUIElement: true },
    },
  },
};
const keys = generateKeyPairSync('ed25519');
const publicKey = keys.publicKey
  .export({ format: 'der', type: 'spki' })
  .subarray(-32)
  .toString('base64');
const env = {
  RELEASE_REPOSITORY: 'owner/app',
  SPARKLE_PUBLIC_KEY: publicKey,
  SPARKLE_PRIVATE_KEY: 'secret',
};

test('release config embeds public update trust and retains ad-hoc signing without Apple credentials', () => {
  assert.throws(() => releaseConfig(pkg, {}), /RELEASE_REPOSITORY/);
  assert.throws(
    () => releaseConfig(pkg, { RELEASE_REPOSITORY: 'owner/app' }),
    /SPARKLE_PUBLIC_KEY/,
  );
  assert.throws(
    () => releaseConfig(pkg, { ...env, SPARKLE_PUBLIC_KEY: 'placeholder' }),
    /SPARKLE_PUBLIC_KEY/,
  );
  const cfg = releaseConfig(pkg, env);
  assert.equal(cfg.mac.identity, '-');
  assert.equal(cfg.mac.notarize, false);
  assert.equal(cfg.mac.hardenedRuntime, false);
  assert.equal(cfg.mac.extendInfo.LSUIElement, true);
  assert.equal(cfg.mac.extendInfo.SUPublicEDKey, publicKey);
  assert.equal(cfg.mac.extendInfo.SUVerifyUpdateBeforeExtraction, true);
  assert.equal(cfg.mac.extendInfo.SUEnableAutomaticChecks, true);
  assert.equal(cfg.mac.extendInfo.SUAutomaticallyUpdate, false);
  assert.equal(
    cfg.extraMetadata.release.feedUrl,
    'https://github.com/owner/app/releases/latest/download/appcast.xml',
  );
  assert.equal(cfg.extraMetadata.release.updater, 'sparkle');
  assert.equal(cfg.dmg.writeUpdateInfo, false);
  assert(!cfg.files.includes('!**/node_modules/electron-sparkle-updater/native/**'));
  assert(!JSON.stringify(cfg).includes('secret'));
});

test('appcast authenticates exact ZIP bytes, version, platform requirements and GitHub asset URL', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'everything-release-'));
  try {
    const names: string[] = releaseArtifactNames(pkg);
    assert(names.every((name) => /^[A-Za-z0-9._-]+$/.test(name)));
    const bytes = Buffer.from('release fixture');
    const signature = sign(null, bytes, keys.privateKey).toString('base64');
    const zip = names.find((name) => name.endsWith('.zip'))!;
    for (const name of names) await writeFile(join(directory, name), bytes);
    const xml = appcastXml(pkg, 'owner/app', signature, bytes.length);
    const check = () => verifyReleaseMetadata(pkg, directory, 'owner/app', publicKey);
    await writeFile(join(directory, 'appcast.xml'), xml);
    assert.deepEqual(await check(), names);
    for (const [modified, message] of [
      [xml.replace(`/v0.2.0/${zip}`, '/v0.2.0/wrong.zip'), /ZIP asset/],
      [xml.replace('<sparkle:version>0.2.0', '<sparkle:version>0.1.0'), /version/],
      [xml.replace('27.0', '26.0'), /system version/],
      [xml.replace(signature, ''), /signature/],
      [xml.replace(`length="${bytes.length}"`, 'length="1"'), /size/],
    ] as const) {
      await writeFile(join(directory, 'appcast.xml'), modified);
      await assert.rejects(check(), message);
    }
    await writeFile(join(directory, 'appcast.xml'), xml);
    const wrongKey = generateKeyPairSync('ed25519')
      .publicKey.export({ format: 'der', type: 'spki' })
      .subarray(-32)
      .toString('base64');
    await assert.rejects(verifyReleaseMetadata(pkg, directory, 'owner/app', wrongKey), /signature/);
    await writeFile(join(directory, zip), Buffer.alloc(bytes.length, 1));
    await assert.rejects(check(), /signature/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
