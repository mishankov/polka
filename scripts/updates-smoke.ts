import { _electron as electron, expect, type ElectronApplication } from '@playwright/test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { spawnSync, execFileSync } from 'node:child_process';
import { readFile, writeFile, mkdtemp, mkdir, rm } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
// @ts-expect-error Build-time JavaScript.
import { releaseConfig, releaseArtifactNames } from './release-config.mjs';
// @ts-expect-error Build-time JavaScript.
import { appcastXml, verifyReleaseMetadata } from './release-metadata.mjs';
// @ts-expect-error Build-time JavaScript.
import { assertPreparedApp } from './prepared-app.mjs';

// Two real ad-hoc bundles, a disposable trust key and localhost feed. Nothing is published.
async function main() {
  const directory = await mkdtemp(join(tmpdir(), 'polka-update-smoke-'));
  const pkg = JSON.parse(await readFile('package.json', 'utf8'));
  const productName = `Polka Update Smoke ${Date.now()}`;
  const appId = `app.polka.update-smoke.${Date.now()}`;
  const keys = generateKeyPairSync('ed25519');
  const publicKey = keys.publicKey
    .export({ type: 'spki', format: 'der' })
    .subarray(-32)
    .toString('base64');
  const privateKey = keys.privateKey
    .export({ type: 'pkcs8', format: 'der' })
    .subarray(-32)
    .toString('base64');
  const [major, minor, patch] = pkg.version.split('.').map(Number);
  const newPkg = { ...pkg, version: `${major}.${minor}.${patch + 1}` };
  let feed = '';
  let zipBytes = Buffer.alloc(0);
  const server = createServer((request, response) => {
    if (request.url === '/appcast.xml') {
      response.setHeader('Content-Type', 'application/xml');
      response.end(feed);
    } else if (request.url?.endsWith('.zip')) {
      response.setHeader('Content-Length', zipBytes.length);
      response.end(zipBytes);
    } else {
      response.writeHead(404);
      response.end();
    }
  });
  await new Promise<void>((done) => server.listen(0, '127.0.0.1', done));
  const address = server.address();
  assert(address && typeof address !== 'string');
  const origin = `http://127.0.0.1:${address.port}`;
  const env = Object.fromEntries(
    Object.entries(process.env).filter(
      ([key, value]) => key !== 'ELECTRON_RUN_AS_NODE' && value !== undefined,
    ),
  ) as Record<string, string>;
  env.CSC_FOR_PULL_REQUEST = 'true'; // Fixture signing uses no certificate or release secret.
  let running: ElectronApplication | undefined;
  const profile = join(directory, 'profile');
  const bootstrap = join(directory, 'bootstrap');
  const relaunchReceipt = join(directory, 'relaunch.json');
  const fixtureStorageKey = randomBytes(32).toString('base64');
  let executable = '';
  function run(command: string, args: string[]) {
    const result = spawnSync(command, args, { stdio: 'inherit', env });
    assert.equal(result.status, 0, `${command} ${args.join(' ')} failed`);
  }
  function version(bundle: string) {
    return execFileSync(
      '/usr/libexec/PlistBuddy',
      ['-c', 'Print :CFBundleVersion', join(bundle, 'Contents/Info.plist')],
      { encoding: 'utf8' },
    ).trim();
  }
  try {
    if (process.argv.includes('--prebuilt')) await assertPreparedApp();
    else run('npm', ['run', 'build:prepare']);
    run('npm', ['run', 'sparkle:build']);
    // The rebranded app deliberately keeps the legacy user-data location. Bake a
    // fixture-only entry point into both bundles so Sparkle's native relaunch
    // also uses our temporary profile, even if launch environment is discarded.
    await mkdir(bootstrap);
    await writeFile(
      join(bootstrap, 'update-smoke-bootstrap.js'),
      `process.env.EVERYTHING_PROFILE = ${JSON.stringify(profile)};
const { app, safeStorage } = require('electron');
const { randomBytes, createCipheriv, createDecipheriv } = require('node:crypto');
// Both disposable builds share a test-only encryption key. Real safeStorage uses
// the login Keychain, whose trust changes with ad-hoc signing and can block CI
// or prompt the developer. This fixture does not exercise Keychain permissions.
const storageKey = Buffer.from(${JSON.stringify(fixtureStorageKey)}, 'base64');
safeStorage.isEncryptionAvailable = () => true;
safeStorage.encryptString = (text) => {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', storageKey, iv);
  const bytes = Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), bytes]);
};
safeStorage.decryptString = (bytes) => {
  const decipher = createDecipheriv('aes-256-gcm', storageKey, bytes.subarray(0, 12));
  decipher.setAuthTag(bytes.subarray(12, 28));
  return Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString('utf8');
};
const { writeFileSync, renameSync } = require('node:fs');
const receiptPath = ${JSON.stringify(relaunchReceipt)};
function report(value) {
  writeFileSync(receiptPath + '.tmp', JSON.stringify(value));
  renameSync(receiptPath + '.tmp', receiptPath);
}
// Observe the renderer in the process Sparkle actually relaunched. Starting a
// second instance would race startup/shutdown and Electron's single-instance lock.
app.on('browser-window-created', (_event, window) => {
  if (app.getVersion() !== ${JSON.stringify(newPkg.version)}) return;
  window.webContents.once('did-finish-load', async () => {
    if (new URL(window.webContents.getURL()).searchParams.get('mode') !== 'shelf') return;
    try {
      const result = await window.webContents.executeJavaScript(\`
        (async () => {
          const deadline = Date.now() + 45000;
          let status;
          do {
            status = await window.platform.call('updates.status');
            if (status.status === 'current') break;
            await new Promise(done => setTimeout(done, 100));
          } while (Date.now() < deadline);
          return {
            status,
            marker: await window.platform.call('settings.get', { key: 'updateSmokeMarker' }),
          };
        })()
      \`);
      report({
        pid: process.pid, version: app.getVersion(), profile: app.getPath('userData'), ...result,
      });
    } catch (error) {
      report({ error: String(error) });
    }
  });
});
require('./index.js');
`,
    );
    for (const [fixture, folder, target] of [
      [pkg, 'old', 'dir'],
      [newPkg, 'new', 'zip'],
    ] as const) {
      const config = releaseConfig(fixture, {
        RELEASE_REPOSITORY: 'smoke/app',
        SPARKLE_PUBLIC_KEY: publicKey,
      });
      config.appId = appId;
      config.productName = productName;
      config.buildVersion = fixture.version;
      // These localhost fixtures test authentication and installation, not compression.
      config.compression = 'store';
      config.directories.output = join(directory, folder);
      config.extraMetadata.main = 'out/main/update-smoke-bootstrap.js';
      config.files.push({ from: bootstrap, to: 'out/main', filter: ['update-smoke-bootstrap.js'] });
      config.extraMetadata.version = fixture.version;
      config.extraMetadata.productName = productName;
      config.extraMetadata.release.feedUrl = `${origin}/appcast.xml`;
      config.mac.extendInfo.SUFeedURL = `${origin}/appcast.xml`;
      config.mac.extendInfo.NSAppTransportSecurity = { NSAllowsLocalNetworking: true };
      // Keep real production archive names even though this app has a disposable name.
      config.mac.artifactName = releaseArtifactNames(fixture).find((name: string) =>
        name.endsWith('.zip'),
      );
      const path = join(directory, `${folder}.json`);
      await writeFile(path, JSON.stringify(config));
      run('node_modules/.bin/electron-builder', [
        '--config',
        path,
        '--mac',
        target,
        '--arm64',
        '--publish',
        'never',
      ]);
    }
    const bundle = join(directory, 'old/mac-arm64', `${productName}.app`);
    executable = join(bundle, 'Contents/MacOS', productName);
    const zip = releaseArtifactNames(newPkg).find((name: string) => name.endsWith('.zip'));
    const archive = join(directory, 'new', zip);
    zipBytes = await readFile(archive);
    const signed = spawnSync(
      'node_modules/electron-sparkle-updater/native/vendor/bin/sign_update',
      ['--ed-key-file', '-', '-p', archive],
      { input: privateKey, encoding: 'utf8' },
    );
    assert.equal(signed.status, 0, 'Fixture signing failed');
    const validFeed = appcastXml(newPkg, 'smoke/app', signed.stdout.trim(), zipBytes.length);
    // Verify the exact same manifest/ZIP signature contract as the release uploader.
    await writeFile(join(directory, 'new', 'appcast.xml'), validFeed);
    await writeFile(
      join(directory, 'new', releaseArtifactNames(newPkg)[0]),
      'DMG not needed for this ZIP-only fixture',
    );
    await verifyReleaseMetadata(newPkg, join(directory, 'new'), 'smoke/app', publicKey);
    const localFeed = validFeed.replace(
      `https://github.com/smoke/app/releases/download/v${newPkg.version}/${zip}`,
      `${origin}/${zip}`,
    );
    feed = localFeed.replace(signed.stdout.trim(), Buffer.alloc(64).toString('base64'));
    const launch = async () => {
      const instance = await electron.launch({
        executablePath: executable,
        args: [],
        env,
        cwd: resolve('.'),
      });
      instance.process().stderr?.on('data', (data) => process.stderr.write(data));
      return instance;
    };
    console.log('Starting packaged update fixture');
    running = await launch();
    assert.equal(await running.evaluate(({ app }) => app.getPath('userData')), profile);
    let page = await running.firstWindow();
    const status = () => page.evaluate(() => window.platform.call('updates.status'));
    await expect.poll(async () => (await status()).status, { timeout: 90000 }).toBe('error');
    assert.equal(version(bundle), pkg.version, 'Invalid signature must not replace the app');
    await page.evaluate(() =>
      window.platform.call('settings.set', { key: 'updateSmokeMarker', value: 'preserved' }),
    );
    console.log('Invalid signature rejected');
    feed = localFeed;
    await page.evaluate(() => window.platform.call('updates.check'));
    await expect.poll(async () => (await status()).status, { timeout: 90000 }).toBe('ready');
    assert.equal(version(bundle), pkg.version, 'Download must not install or restart');
    console.log('Valid update ready; testing ordinary quit cancellation');
    // A normal quit must cancel staging rather than authorize installation.
    await running.close();
    running = undefined;
    await expect.poll(() => version(bundle), { timeout: 5000 }).toBe(pkg.version);
    // Verify no asynchronous installation occurred while the app was closed.
    await new Promise((done) => setTimeout(done, 5000));
    assert.equal(version(bundle), pkg.version, 'Ordinary quit must not install a staged update');
    running = await launch();
    page = await running.firstWindow();
    await expect.poll(async () => (await status()).status, { timeout: 90000 }).toBe('ready');
    console.log('Update ready after relaunch; requesting explicit install');
    const oldPid = running.process().pid;
    const exited = new Promise<void>((done) => running!.process().once('exit', () => done()));
    // IPC may close before its reply; the durable evidence is replacement and relaunch.
    void page.evaluate(() => window.platform.call('updates.install')).catch(() => {});
    await Promise.race([
      exited,
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(Error('Update did not quit')), 45000).unref(),
      ),
    ]);
    running = undefined;
    await expect.poll(() => version(bundle), { timeout: 45000 }).toBe(newPkg.version);
    let receipt:
      | {
          pid: number;
          version: string;
          profile: string;
          status: { status: string; currentVersion: string };
          marker: string;
          error?: string;
        }
      | undefined;
    await expect
      .poll(
        async () => {
          try {
            receipt = JSON.parse(await readFile(relaunchReceipt, 'utf8'));
            return true;
          } catch (error) {
            if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false;
            throw error;
          }
        },
        { timeout: 90000, message: 'Sparkle-relaunched app must load its renderer and saved data' },
      )
      .toBe(true);
    assert(receipt);
    assert.equal(receipt.error, undefined, 'Relaunched renderer must initialize successfully');
    assert(receipt.pid > 0 && receipt.pid !== oldPid, 'Sparkle must start a new app process');
    assert.equal(receipt.profile, profile);
    assert.equal(receipt.version, newPkg.version);
    assert.equal(receipt.status.status, 'current');
    assert.equal(receipt.status.currentVersion, newPkg.version);
    assert.equal(receipt.marker, 'preserved');
    console.log(
      'Packaged update passed: signature rejection, automatic download, ordinary quit cancellation, explicit install, relaunch and preserved data.',
    );
  } finally {
    // Assertions above already verified orderly quit and relaunch. Playwright can
    // detach its debugger before a final quit acknowledgement, so terminate only
    // this disposable fixture during cleanup instead of waiting indefinitely.
    running?.process().kill('SIGKILL');
    await running?.close().catch(() => {});
    server.closeAllConnections();
    await new Promise<void>((done) => server.close(() => done()));
    // Terminate only disposable fixture helpers before removing their staged files.
    spawnSync('pkill', ['-f', directory]);
    spawnSync('pkill', ['-f', appId]);
    await rm(profile, { recursive: true, force: true });
    await rm(join(homedir(), 'Library/Caches', appId), { recursive: true, force: true });
    await rm(join(homedir(), 'Library/Preferences', `${appId}.plist`), { force: true });
    await rm(directory, { recursive: true, force: true });
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
