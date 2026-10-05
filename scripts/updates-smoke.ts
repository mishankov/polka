import { _electron as electron, expect, type ElectronApplication } from '@playwright/test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { createServer } from 'node:http';
import { spawnSync, execFileSync } from 'node:child_process';
import { readFile, writeFile, mkdtemp, mkdir, rm } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
// @ts-expect-error Build-time JavaScript.
import { releaseConfig, releaseArtifactNames } from './release-config.mjs';
// @ts-expect-error Build-time JavaScript.
import { appcastXml, verifyReleaseMetadata } from './release-metadata.mjs';

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
  let profile: string | undefined;
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
    run('npm', ['run', 'build']);
    run('npm', ['run', 'native:build']);
    run('npm', ['run', 'sparkle:build']);
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
      config.directories.output = join(directory, folder);
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
    profile = await running.evaluate(({ app }) => app.getPath('userData'));
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
    let relaunchedPid = 0;
    await expect
      .poll(
        () => {
          const output = spawnSync('pgrep', ['-f', executable], { encoding: 'utf8' }).stdout;
          relaunchedPid =
            output
              .trim()
              .split('\n')
              .map(Number)
              .find((pid) => pid !== oldPid && pid > 0) || 0;
          return relaunchedPid > 0;
        },
        { timeout: 45000 },
      )
      .toBe(true);
    process.kill(relaunchedPid, 'SIGTERM');
    await new Promise((done) => setTimeout(done, 1000));
    running = await launch();
    page = await running.firstWindow();
    await expect.poll(async () => (await status()).status, { timeout: 45000 }).toBe('current');
    assert.equal((await status()).currentVersion, newPkg.version);
    assert.equal(
      await page.evaluate(() => window.platform.call('settings.get', { key: 'updateSmokeMarker' })),
      'preserved',
    );
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
    if (profile) await rm(profile, { recursive: true, force: true });
    await rm(join(homedir(), 'Library/Caches', appId), { recursive: true, force: true });
    await rm(join(homedir(), 'Library/Preferences', `${appId}.plist`), { force: true });
    await rm(directory, { recursive: true, force: true });
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
