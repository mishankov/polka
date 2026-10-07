import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import {
  createSigningCertificate,
  withSigningKeychain,
  // @ts-expect-error Build-time JavaScript.
} from '../../scripts/release/signing-certificate.mjs';
// @ts-expect-error Build-time JavaScript.
import { sign, verifySignedBundle, nativeHelpers } from '../../scripts/release/sign-macos.mjs';

test(
  'self-signed updates retain app/helper requirements across changed binaries',
  {
    skip: process.platform !== 'darwin',
    timeout: 120_000,
  },
  async () => {
    const directory = await mkdtemp(join(tmpdir(), 'polka-signing-test-'));
    const searchList = execFileSync('security', ['list-keychains', '-d', 'user'], {
      encoding: 'utf8',
    });
    const appId = 'app.polka.signing-test';
    let keychain = '';
    try {
      const certificate = join(directory, 'certificate');
      const fingerprint = await createSigningCertificate(certificate);
      await assert.rejects(createSigningCertificate(certificate), /EEXIST/);
      const password = await readFile(join(certificate, 'password.txt'), 'utf8');
      const env = {
        ...process.env,
        POLKA_SIGNING_CERT_SHA1: fingerprint,
        POLKA_SIGNING_P12: join(certificate, 'identity.p12'),
        POLKA_SIGNING_PASSWORD: password,
        SPARKLE_PRIVATE_KEY: 'must-not-reach-build-children',
      };
      await assert.rejects(
        withSigningKeychain({ ...env, POLKA_SIGNING_CERT_SHA1: '0'.repeat(40) }, () => {}),
        /does not match/,
      );
      await assert.rejects(
        withSigningKeychain({ ...env, POLKA_SIGNING_PASSWORD: 'wrong' }, () => {}),
        /openssl failed/,
      );

      const bundles: string[] = [];
      for (const version of ['1', '2']) {
        const bundle = join(directory, `Version${version}.app`);
        const contents = join(bundle, 'Contents');
        await mkdir(join(contents, 'MacOS'), { recursive: true });
        await mkdir(join(contents, 'Resources'));
        await writeFile(
          join(contents, 'Info.plist'),
          `<?xml version="1.0"?><plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>${appId}</string>
        <key>CFBundleExecutable</key><string>Main</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleVersion</key><string>${version}</string>
      </dict></plist>`,
        );
        const source = join(directory, `version${version}.c`);
        await writeFile(
          source,
          `#include <stdio.h>\nint main(void) { puts("Version ${version}"); return 0; }\n`,
        );
        const executable = join(contents, 'MacOS/Main');
        execFileSync('clang', [source, '-o', executable]);
        for (const helper of nativeHelpers)
          await copyFile(executable, join(contents, 'Resources', helper));
        bundles.push(bundle);
      }
      // Test the base64 secret used in CI as well as the local file form above.
      env.POLKA_SIGNING_P12 = (await readFile(env.POLKA_SIGNING_P12)).toString('base64');
      await withSigningKeychain(env, async (buildEnv: Record<string, string>) => {
        assert.equal(buildEnv.POLKA_SIGNING_PASSWORD, undefined);
        assert.equal(buildEnv.POLKA_SIGNING_P12, undefined);
        assert.equal(buildEnv.SPARKLE_PRIVATE_KEY, undefined);
        keychain = buildEnv.POLKA_SIGNING_KEYCHAIN;
        for (const bundle of bundles)
          await sign(
            {
              app: bundle,
              platform: 'darwin',
              optionsForFile: () => ({ entitlements: resolve('build/entitlements.mac.plist') }),
            },
            { appInfo: { id: appId } },
            buildEnv,
          );
      });
      await assert.rejects(access(keychain), /ENOENT/);
      const oldRequirements = verifySignedBundle(bundles[0], appId, fingerprint);
      const newRequirements = verifySignedBundle(bundles[1], appId, fingerprint);
      assert.deepEqual(oldRequirements, newRequirements);
      assert.notDeepEqual(
        await readFile(join(bundles[0], 'Contents/MacOS/Main')),
        await readFile(join(bundles[1], 'Contents/MacOS/Main')),
      );
      for (const [identifier, requirement] of Object.entries(oldRequirements)) {
        const target =
          identifier === appId
            ? bundles[1]
            : join(bundles[1], 'Contents/Resources', identifier.slice(appId.length + 1));
        execFileSync('codesign', ['--verify', '-R', `=${requirement}`, target]);
      }
      assert.throws(() => verifySignedBundle(bundles[1], appId, '0'.repeat(40)));
      assert.throws(() => verifySignedBundle(bundles[1], 'app.polka.wrong', fingerprint));
      execFileSync('codesign', [
        '--force',
        '--sign',
        '-',
        join(bundles[1], 'Contents/Resources/clipboard-probe'),
      ]);
      assert.throws(() => verifySignedBundle(bundles[1], appId, fingerprint));
      await assert.rejects(
        withSigningKeychain(env, async (buildEnv: Record<string, string>) => {
          keychain = buildEnv.POLKA_SIGNING_KEYCHAIN;
          throw Error('simulated packaging failure');
        }),
        /simulated packaging failure/,
      );
      assert.notEqual(spawnSync('security', ['show-keychain-info', keychain]).status, 0);
      assert.equal(
        execFileSync('security', ['list-keychains', '-d', 'user'], { encoding: 'utf8' }),
        searchList,
      );
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
);
