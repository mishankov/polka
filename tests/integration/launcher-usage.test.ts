import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LauncherUsage } from '../../src/main/launcher-usage';
import { SettingsStore } from '../../src/main/settings-store';
import { launcherApps, type LauncherUsageStats } from '../../src/shared/launcher';

const id = `mac:${'a'.repeat(32)}`;
const other = `mac:${'b'.repeat(32)}`;

test('successful launches persist and affect ordering after reopening the settings store', async () => {
  const root = mkdtempSync(join(tmpdir(), 'polka-launcher-usage-'));
  let store = new SettingsStore(root);
  const service = () =>
    new LauncherUsage({
      read: () => store.handle('settings.get', { key: 'launcherUsage' }),
      save: (value) => store.handle('settings.set', { key: 'launcherUsage', value }),
      open: async (target) => {
        if (target === other) throw Error('App no longer exists');
        return { opened: true };
      },
      now: () => 100,
      onError: (error) => {
        throw error;
      },
    });
  try {
    const usage = service();
    assert.deepEqual(await usage.state(), {});
    await assert.rejects(usage.open(other), /no longer exists/);
    assert.deepEqual(await usage.state(), {});
    assert.equal((await usage.open(id)).opened, true);
    await usage.open(id);
    const returned = await usage.state();
    returned[id].count = 900;
    assert.equal((await usage.state())[id].count, 2);
    store.close();
    store = new SettingsStore(root);
    const persisted = await service().state();
    assert.deepEqual(persisted, { [id]: { count: 2, lastLaunchedAt: 100 } });
    const apps = ['Alpha', 'Beta'].map((name, i) => ({
      kind: 'mac' as const,
      id: i ? id : other,
      name,
      icon: '',
      description: '',
    }));
    assert.equal(launcherApps(apps, '', persisted)[0].name, 'Beta');
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test('concurrent successful launches serialize writes without losing increments', async () => {
  const saved: LauncherUsageStats[] = [];
  let time = 100;
  const usage = new LauncherUsage({
    read: async () => ({ [id]: { count: 1, lastLaunchedAt: 50 } }),
    save: async (value) => {
      await new Promise<void>((resolve) => setImmediate(resolve));
      saved.push(value);
    },
    open: async () => ({ opened: true }),
    now: () => time++,
    onError: (error) => {
      throw error;
    },
  });
  await Promise.all([usage.open(id), usage.open(id), usage.open(other)]);
  assert.deepEqual(
    saved.map((value) => value[id].count),
    [2, 3, 3],
  );
  assert.deepEqual(await usage.state(), {
    [id]: { count: 3, lastLaunchedAt: 101 },
    [other]: { count: 1, lastLaunchedAt: 102 },
  });
});

test('read and save errors preserve launching and future ranking writes can recover', async () => {
  const errors: unknown[] = [];
  let fail = true;
  let saved: LauncherUsageStats = {};
  const usage = new LauncherUsage({
    read: async () => {
      throw Error('Cannot read settings');
    },
    save: async (value) => {
      if (fail) throw Error('Disk full');
      saved = value;
    },
    open: async () => ({ opened: true }),
    now: () => 100,
    onError: (error) => {
      errors.push(error);
    },
  });
  assert.equal((await usage.open(id)).opened, true);
  assert.equal((await usage.state())[id].count, 1);
  fail = false;
  await usage.open(id);
  assert.equal(saved[id].count, 2);
  assert.equal(errors.length, 2);
});

test('unopened apps and invalid persisted values do not influence ranking', async () => {
  for (const saved of [
    null,
    true,
    [],
    { [id]: { count: -1, lastLaunchedAt: 100 } },
    {
      invalid: { count: 900, lastLaunchedAt: 100 },
      [id]: { count: 1.5, lastLaunchedAt: 100 },
      [other]: { count: 3, lastLaunchedAt: 'yesterday' },
    },
  ]) {
    const usage = new LauncherUsage({
      read: async () => saved,
      save: async () => {
        assert.fail('An unopened app must not update history');
      },
      open: async () => ({ opened: false }),
      onError: (error) => {
        throw error;
      },
    });
    assert.deepEqual(await usage.state(), {});
    assert.equal((await usage.open(id)).opened, false);
    assert.deepEqual(await usage.state(), {});
  }
});
