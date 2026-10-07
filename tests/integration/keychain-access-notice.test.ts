import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { explainKeychainAccess } from '../../src/main/keychain-access-notice';

test('Keychain access waits for the explanation, remembered across restarts per version', async () => {
  const profile = await mkdtemp(join(tmpdir(), 'polka-keychain-notice-'));
  try {
    let shown = 0;
    let acknowledge = () => {};
    let displayed = () => {};
    const visible = new Promise<void>((resolve) => {
      acknowledge = resolve;
    });
    const showing = new Promise<void>((resolve) => {
      displayed = resolve;
    });
    let accessStarted = false;
    const opening = explainKeychainAccess(profile, '0.5.0', async () => {
      shown++;
      displayed();
      await visible;
    }).then(() => {
      accessStarted = true;
    });
    await showing;
    assert.equal(accessStarted, false);
    await assert.rejects(readFile(join(profile, 'keychain-notice-version')), { code: 'ENOENT' });
    acknowledge();
    await opening;
    assert.equal(accessStarted, true);
    const show = async () => {
      shown++;
    };
    await explainKeychainAccess(profile, '0.5.0', show);
    assert.equal(shown, 1);
    await explainKeychainAccess(profile, '0.6.0', show);
    assert.equal(shown, 2);
    assert.equal(await readFile(join(profile, 'keychain-notice-version'), 'utf8'), '0.6.0');
  } finally {
    await rm(profile, { recursive: true, force: true });
  }
});

test('a failed explanation is retried; an unwritable notice preference does not block storage access', async () => {
  const profile = await mkdtemp(join(tmpdir(), 'polka-keychain-notice-'));
  try {
    await explainKeychainAccess(profile, '0.5.0', async () => {
      throw Error('dialog failed');
    });
    await assert.rejects(readFile(join(profile, 'keychain-notice-version')), { code: 'ENOENT' });
    // A directory at the preference path makes it unreadable and unwritable as a file.
    await mkdir(join(profile, 'keychain-notice-version'));
    let shown = false;
    await explainKeychainAccess(profile, '0.5.0', async () => {
      shown = true;
    });
    assert.equal(shown, true);
  } finally {
    await rm(profile, { recursive: true, force: true });
  }
});
