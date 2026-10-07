import test from 'node:test';
import assert from 'node:assert/strict';
import { Worker } from 'node:worker_threads';
import { DatabaseSync } from 'node:sqlite';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { SettingsStore } from '../../src/main/settings-store';
const bundle = join(import.meta.dirname, '../../out/main/worker.js');
test(
  'settings worker preserves existing preferences and legacy data and rejects removed RPCs',
  {
    skip: existsSync(bundle) ? false : 'Run npm run build first',
    timeout: 10000,
  },
  async () => {
    const root = mkdtempSync(join(tmpdir(), 'polka-settings-'));
    const db = new DatabaseSync(join(root, 'workspace.sqlite'));
    db.exec(`CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE state(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE apps(id TEXT PRIMARY KEY,definition TEXT NOT NULL);`);
    db.prepare('INSERT INTO settings VALUES(?,?)').run(
      'launcherShortcut',
      JSON.stringify('Alt+Space'),
    );
    db.prepare('INSERT INTO state VALUES(?,?)').run('runtime.jobs', '[{"id":"old-job"}]');
    db.prepare('INSERT INTO apps VALUES(?,?)').run('old-app', '{"name":"Saved app"}');
    db.close();
    const worker = new Worker(bundle, { workerData: { root, customAppsEnabled: true } });
    const hosts: unknown[] = [];
    worker.on('message', (message) => {
      if (message.kind === 'host') hosts.push(message);
    });
    try {
      let ready;
      do {
        [ready] = await once(worker, 'message');
      } while (ready.kind !== 'ready');
      async function call(method: string, params: any = {}) {
        const id = randomUUID();
        const result = new Promise<any>((resolve) => {
          const listener = (message: any) => {
            if (message.kind !== 'result' || message.id !== id) return;
            worker.off('message', listener);
            resolve(message);
          };
          worker.on('message', listener);
        });
        worker.postMessage({ kind: 'call', id, method, params });
        return result;
      }
      assert.equal((await call('settings.get', { key: 'launcherShortcut' })).result, 'Alt+Space');
      assert.equal(
        (await call('settings.set', { key: 'mediaIndicatorEnabled', value: false })).result,
        false,
      );
      for (const method of [
        'apps.create',
        'apps.start',
        'provider.get',
        'provider.save',
        'agent.send',
        'jobs.enqueue',
        'runtime.signal',
        'extensions.run',
        'packages.importCommit',
        'state.get',
      ])
        assert.match((await call(method)).error, /Неизвестная операция/);
      assert.deepEqual(hosts, []);
      const exited = once(worker, 'exit');
      worker.postMessage({ kind: 'shutdown' });
      await exited;
      const after = new DatabaseSync(join(root, 'workspace.sqlite'));
      assert.equal(after.prepare('SELECT value FROM state').get()!.value, '[{"id":"old-job"}]');
      assert.equal(
        after.prepare('SELECT definition FROM apps').get()!.definition,
        '{"name":"Saved app"}',
      );
      after.close();
      const settings = new SettingsStore(root);
      assert.equal(await settings.handle('settings.get', { key: 'mediaIndicatorEnabled' }), false);
      settings.close();
    } finally {
      await worker.terminate();
      rmSync(root, { recursive: true, force: true });
    }
  },
);
test('settings reject secrets and invalid values', async () => {
  const root = mkdtempSync(join(tmpdir(), 'polka-settings-'));
  const settings = new SettingsStore(root);
  try {
    for (const key of ['apiKey', 'password', 'token'])
      await assert.rejects(settings.handle('settings.set', { key, value: 'private' }), /Секреты/);
    await assert.rejects(settings.handle('settings.set', { key: 'missing' }), /Некорректные/);
    await assert.rejects(settings.handle('settings.set', { key: 12, value: true }), /Некорректные/);
  } finally {
    settings.close();
    rmSync(root, { recursive: true, force: true });
  }
});
