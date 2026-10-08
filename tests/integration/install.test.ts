import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  mkdtemp,
  mkdir,
  writeFile,
  readFile,
  readdir,
  rm,
  symlink,
  chmod,
  lstat,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const installer = resolve('scripts/install.sh');

// Exercise the actual Bash script with isolated applications and download fixtures.
// Only macOS/network commands are substituted; checksum, staging and rollback are real.
async function fixture(options: Record<string, string> = {}) {
  const root = await mkdtemp(join(tmpdir(), 'polka-installer-'));
  const bin = join(root, 'bin');
  const applications = join(root, 'Applications with spaces');
  const downloads = join(root, 'downloads');
  const bundle = join(root, 'bundle');
  const log = join(root, 'calls.jsonl');
  await Promise.all([bin, applications, downloads, bundle].map((path) => mkdir(path)));
  const archive = Buffer.from('Release ZIP fixture');
  const checksum = createHash('sha256').update(archive).digest('hex');
  await writeFile(join(root, 'archive.zip'), archive);
  await writeFile(join(root, 'checksums.txt'), `${checksum}  polka-0.5.0-arm64.zip\n`);
  await writeFile(join(bundle, 'version'), 'new');
  await writeFile(join(bundle, 'quarantine'), 'quarantined');
  await writeFile(log, '');
  const shim = join(bin, 'shim.cjs');
  await writeFile(
    shim,
    `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const command = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const env = process.env;
fs.appendFileSync(env.INSTALL_TEST_LOG, JSON.stringify({command, args}) + '\\n');
switch (command) {
  case 'uname': console.log(args[0] === '-s' ? env.PLATFORM || 'Darwin' : env.ARCH || 'arm64'); break;
  case 'sw_vers': console.log(env.OS_VERSION || '27.0'); break;
  case 'pgrep': process.exit(env.RUNNING === 'true' ? 0 : 1);
  case 'curl': {
    if (env.DOWNLOAD_FAILURE) process.exit(22);
    const url = args.at(-1);
    if (url.endsWith('/latest')) {
      process.stdout.write(env.RELEASE_URL || 'https://github.com/mishankov/polka/releases/tag/v0.5.0');
    } else {
      const dest = args[args.indexOf('--output') + 1];
      const name = url.endsWith('/checksums.txt') ? 'checksums.txt' : 'archive.zip';
      fs.copyFileSync(path.join(env.INSTALL_TEST_ROOT, name), dest);
    }
    break;
  }
  case 'zipinfo': console.log(env.ZIP_ENTRIES || 'Polka.app/\\nPolka.app/Contents/Info.plist'); break;
  case 'ditto': {
    const extracting = args[0] === '-x';
    const source = extracting ? path.join(env.INSTALL_TEST_ROOT, 'bundle') : args[0];
    const dest = extracting ? path.join(args.at(-1), 'Polka.app') : args[1];
    fs.cpSync(source, dest, {recursive:true});
    if (!extracting && env.COPY_FAILURE) process.exit(1);
    break;
  }
  case 'plutil': console.log(args[1] === 'CFBundleIdentifier' ? env.BUNDLE_ID || 'app.everything.desktop' : env.BUNDLE_VERSION || '0.5.0'); break;
  case 'codesign': process.exit(env.SIGNATURE_FAILURE || (env.STAGED_SIGNATURE_FAILURE && args.at(-1).includes('.polka-install.')) ? 1 : 0);
  case 'xattr':
    if (env.QUARANTINE_FAILURE) process.exit(1);
    fs.unlinkSync(path.join(args.at(-1), 'quarantine'));
    break;
  case 'mv':
    if (env.MOVE_FAILURE && args[0].includes('.polka-install.') && args[0].endsWith('/Polka.app')) process.exit(1);
    fs.renameSync(args[0], args[1]);
    break;
  case 'open': process.exit(env.LAUNCH_FAILURE ? 1 : 0);
  case 'sudo': {
    if (args[0] === '-v') process.exit(0);
    if (args[0] === 'rm' || args[0] === 'mv') {
      // Simulate root's ability to move or remove the read-only previous app.
      const makeWritable = directory => {
        if (!fs.existsSync(directory) || !fs.statSync(directory).isDirectory()) return;
        fs.chmodSync(directory, 0o755);
        for (const entry of fs.readdirSync(directory)) makeWritable(path.join(directory, entry));
      };
      makeWritable(args[0] === 'mv' ? args[1] : args.at(-1));
    }
    const result = spawnSync(args[0], args.slice(1), {stdio:'inherit'});
    process.exit(result.status ?? 1);
  }
  default: throw Error('Unexpected command: ' + command);
}
`,
    { mode: 0o755 },
  );
  for (const command of [
    'uname',
    'sw_vers',
    'pgrep',
    'curl',
    'zipinfo',
    'ditto',
    'plutil',
    'codesign',
    'xattr',
    'mv',
    'open',
    'sudo',
  ])
    await symlink(shim, join(bin, command));
  const env = {
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    TMPDIR: downloads,
    INSTALL_TEST_ROOT: root,
    INSTALL_TEST_LOG: log,
    ...options,
  };
  return {
    root,
    applications,
    downloads,
    bundle,
    run: (...args: string[]) =>
      spawnSync('/bin/bash', [installer, '--install-dir', applications, ...args], {
        env,
        encoding: 'utf8',
      }),
    calls: async () =>
      (await readFile(log, 'utf8'))
        .trim()
        .split('\n')
        .filter(Boolean)
        .map((line) => JSON.parse(line)),
    clean: async () => {
      const makeWritable = async (directory: string) => {
        if (!(await lstat(directory)).isDirectory()) return;
        await chmod(directory, 0o755);
        for (const entry of await readdir(directory)) await makeWritable(join(directory, entry));
      };
      await makeWritable(root);
      await rm(root, { recursive: true, force: true });
    },
  };
}

test('installer verifies the pinned release, removes quarantine and launches', async () => {
  const f = await fixture();
  try {
    const result = f.run();
    assert.equal(result.status, 0, result.stderr);
    const target = join(f.applications, 'Polka.app');
    assert.equal(await readFile(join(target, 'version'), 'utf8'), 'new');
    assert.deepEqual(await readdir(target), ['version']);
    assert.deepEqual(await readdir(f.downloads), []);
    assert.deepEqual(await readdir(f.applications), ['Polka.app']);
    const calls = await f.calls();
    const downloads = calls.filter((call) => call.command === 'curl');
    assert.deepEqual(
      downloads.slice(1).map((call) => call.args.at(-1)),
      [
        'https://github.com/mishankov/polka/releases/download/v0.5.0/polka-0.5.0-arm64.zip',
        'https://github.com/mishankov/polka/releases/download/v0.5.0/checksums.txt',
      ],
    );
    assert.equal(calls.filter((call) => call.command === 'codesign').length, 2);
    const xattr = calls.find((call) => call.command === 'xattr');
    assert.deepEqual(xattr.args.slice(0, 2), ['-dr', 'com.apple.quarantine']);
    assert.ok(xattr.args[2].startsWith(`${f.applications}/.polka-install.`));
    assert.deepEqual(calls.find((call) => call.command === 'open').args, [target]);
    assert.equal(
      calls.some((call) => call.command === 'sudo'),
      false,
    );
  } finally {
    await f.clean();
  }
});

test('installer replaces an existing app and supports --no-launch', async () => {
  const f = await fixture();
  try {
    const target = join(f.applications, 'Polka.app');
    await mkdir(target);
    await writeFile(join(target, 'version'), 'old');
    const result = f.run('--no-launch');
    assert.equal(result.status, 0, result.stderr);
    assert.equal(await readFile(join(target, 'version'), 'utf8'), 'new');
    assert.deepEqual(await readdir(f.applications), ['Polka.app']);
    assert.equal(
      (await f.calls()).some((call) => call.command === 'open'),
      false,
    );
  } finally {
    await f.clean();
  }
});

for (const [name, options, message] of [
  ['unsupported platform', { PLATFORM: 'Linux' }, 'requires macOS'],
  ['Intel or Rosetta', { ARCH: 'x86_64' }, 'requires Apple silicon'],
  ['older macOS', { OS_VERSION: '26.1' }, 'requires macOS 27'],
  ['running app', { RUNNING: 'true' }, 'Quit Polka'],
  [
    'wrong release host',
    { RELEASE_URL: 'https://example.com/releases/tag/v0.5.0' },
    'resolve the latest',
  ],
  [
    'unsafe release tag',
    { RELEASE_URL: 'https://github.com/mishankov/polka/releases/tag/v0.5.0%2Fbad' },
    'Unsupported release tag',
  ],
  ['network failure', { DOWNLOAD_FAILURE: 'true' }, ''],
  ['ZIP traversal', { ZIP_ENTRIES: 'Polka.app/../../outside' }, 'Unsafe path'],
  ['unexpected ZIP root', { ZIP_ENTRIES: 'Other.app/Contents/Info.plist' }, 'Unexpected path'],
  ['wrong app identity', { BUNDLE_ID: 'app.other' }, 'Unexpected app identity'],
  ['wrong app version', { BUNDLE_VERSION: '0.4.0' }, 'does not match'],
  ['invalid signature', { SIGNATURE_FAILURE: 'true' }, ''],
  ['invalid staged signature', { STAGED_SIGNATURE_FAILURE: 'true' }, ''],
  ['failed staging copy', { COPY_FAILURE: 'true' }, ''],
  ['failed quarantine removal', { QUARANTINE_FAILURE: 'true' }, ''],
  ['failed replacement', { MOVE_FAILURE: 'true' }, ''],
] as const) {
  test(`installer preserves the existing app on ${name}`, async () => {
    const f = await fixture(options);
    try {
      const target = join(f.applications, 'Polka.app');
      await mkdir(target);
      await writeFile(join(target, 'version'), 'old');
      const result = f.run();
      assert.notEqual(result.status, 0);
      if (message) assert.ok(result.stderr.includes(message), result.stderr);
      assert.equal(await readFile(join(target, 'version'), 'utf8'), 'old');
      assert.deepEqual(await readdir(f.applications), ['Polka.app']);
      assert.deepEqual(await readdir(f.downloads), []);
      assert.equal(
        (await f.calls()).some((call) => call.command === 'open'),
        false,
      );
    } finally {
      await f.clean();
    }
  });
}

for (const checksum of ['wrong', 'missing', 'duplicate']) {
  test(`installer rejects a ${checksum} checksum before extraction`, async () => {
    const f = await fixture();
    try {
      const file = join(f.root, 'checksums.txt');
      const original = await readFile(file, 'utf8');
      await writeFile(
        file,
        checksum === 'wrong'
          ? `${'0'.repeat(64)}  polka-0.5.0-arm64.zip\n`
          : checksum === 'missing'
            ? ''
            : original.repeat(2),
      );
      const result = f.run();
      assert.notEqual(result.status, 0);
      assert.ok(result.stderr.includes('checksum'), result.stderr);
      assert.deepEqual(await readdir(f.applications), []);
      assert.equal(
        (await f.calls()).some((call) => call.command === 'ditto'),
        false,
      );
    } finally {
      await f.clean();
    }
  });
}

test('launch failure leaves the successfully installed app available', async () => {
  const f = await fixture({ LAUNCH_FAILURE: 'true' });
  try {
    const result = f.run();
    assert.notEqual(result.status, 0);
    assert.ok(result.stderr.includes('is installed, but could not be opened'));
    assert.equal(await readFile(join(f.applications, 'Polka.app/version'), 'utf8'), 'new');
    assert.deepEqual(await readdir(f.applications), ['Polka.app']);
    assert.deepEqual(await readdir(f.downloads), []);
  } finally {
    await f.clean();
  }
});

test('installer requests authorization only for a protected installation', async () => {
  const f = await fixture();
  try {
    // Making the existing app read-only is enough to trigger the privileged path.
    const target = join(f.applications, 'Polka.app');
    await mkdir(target);
    await writeFile(join(target, 'version'), 'old');
    await chmod(target, 0o555);
    const result = f.run('--no-launch');
    assert.equal(result.status, 0, result.stderr);
    const calls = await f.calls();
    const sudo = calls.filter((call) => call.command === 'sudo');
    assert.deepEqual(sudo[0].args, ['-v']);
    assert.ok(sudo.some((call) => call.args[0] === 'xattr'));
    assert.ok(sudo.some((call) => call.args[0] === 'mv'));
    assert.equal(await readFile(join(target, 'version'), 'utf8'), 'new');
  } finally {
    await f.clean();
  }
});

test('an incomplete piped script never starts installation', async () => {
  const f = await fixture();
  try {
    const source = await readFile(installer, 'utf8');
    const incomplete = source.slice(0, source.indexOf("  printf 'Installing in %s"));
    const result = spawnSync('/bin/bash', [], { input: incomplete, encoding: 'utf8' });
    assert.notEqual(result.status, 0);
    assert.deepEqual(await f.calls(), []);
    assert.deepEqual(await readdir(f.applications), []);
  } finally {
    await f.clean();
  }
});
