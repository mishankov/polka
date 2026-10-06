import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error Pure build-time JavaScript shared with the release command.
import { releasePackage, releaseConfig, releaseArtifactNames } from '../scripts/release-config.mjs';
// @ts-expect-error Pure build-time JavaScript.
import { appcastXml, verifyReleaseMetadata } from '../scripts/release-metadata.mjs';

const pkg = {
  name: 'polka',
  version: '0.2.0',
  build: {
    productName: 'Polka',
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
  POLKA_SIGNING_CERT_SHA1: 'A'.repeat(40),
  POLKA_SIGNING_P12: 'private-certificate',
  POLKA_SIGNING_PASSWORD: 'private-password',
};

test('release config requires a persistent certificate and embeds only public update trust', () => {
  assert.throws(() => releaseConfig(pkg, {}), /RELEASE_REPOSITORY/);
  assert.throws(
    () => releaseConfig(pkg, { RELEASE_REPOSITORY: 'owner/app' }),
    /SPARKLE_PUBLIC_KEY/,
  );
  assert.throws(
    () => releaseConfig(pkg, { ...env, SPARKLE_PUBLIC_KEY: 'placeholder' }),
    /SPARKLE_PUBLIC_KEY/,
  );
  assert.throws(
    () => releaseConfig(pkg, { ...env, POLKA_SIGNING_CERT_SHA1: undefined }),
    /POLKA_SIGNING_CERT_SHA1/,
  );
  assert.throws(
    () => releaseConfig(pkg, { ...env, POLKA_SIGNING_CERT_SHA1: '-' }),
    /POLKA_SIGNING_CERT_SHA1/,
  );
  const cfg = releaseConfig(pkg, env);
  assert.equal(cfg.mac.identity, '-');
  assert.equal(cfg.mac.sign, './scripts/sign-macos.mjs');
  assert.equal(cfg.forceCodeSigning, true);
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
  assert(!JSON.stringify(cfg).includes('private-certificate'));
  assert(!JSON.stringify(cfg).includes('private-password'));
});

test('disposable updater fixtures explicitly retain certificate-free ad-hoc signing', () => {
  const cfg = releaseConfig(
    pkg,
    { RELEASE_REPOSITORY: 'smoke/app', SPARKLE_PUBLIC_KEY: publicKey },
    { adHoc: true },
  );
  assert.equal(cfg.mac.identity, '-');
  assert.equal(cfg.mac.sign, undefined);
  assert.equal(cfg.forceCodeSigning, false);
});

test('release tags drive bundle versions, asset names and exact feed URLs without editing package.json', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'polka-tag-release-'));
  try {
    assert.equal(releasePackage(pkg, {}).releaseTag, 'v0.2.0');
    for (const tag of ['v1.4.0', '1.4.0', 'v1.4.0-beta.1']) {
      const release = releasePackage(pkg, { RELEASE_TAG: tag });
      const version = tag.replace(/^v/, '');
      assert.equal(release.version, version);
      assert.equal(pkg.version, '0.2.0');
      const config = releaseConfig(release, env);
      assert.equal(config.extraMetadata.version, version);
      assert.equal(config.buildVersion, version);
      const bytes = Buffer.from('tagged release fixture');
      const signature = sign(null, bytes, keys.privateKey).toString('base64');
      const names = releaseArtifactNames(release);
      const zip = `polka-${version}-arm64.zip`;
      assert(names.includes(zip));
      for (const name of names) await writeFile(join(directory, name), bytes);
      const xml = appcastXml(release, 'owner/app', signature, bytes.length);
      assert(xml.includes(`/releases/download/${tag}/${zip}`));
      await writeFile(join(directory, 'appcast.xml'), xml);
      assert.deepEqual(
        await verifyReleaseMetadata(release, directory, 'owner/app', publicKey),
        names,
      );
      await assert.rejects(
        verifyReleaseMetadata(
          { ...release, releaseTag: 'v9.9.9' },
          directory,
          'owner/app',
          publicKey,
        ),
        /ZIP asset/,
      );
    }
    for (const tag of ['latest', 'v1.4', 'v1.4.0/path', 'v01.4.0'])
      assert.throws(() => releasePackage(pkg, { RELEASE_TAG: tag }), /RELEASE_TAG/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
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
