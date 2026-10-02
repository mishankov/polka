import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { build } from 'esbuild';
import { unzipSync, strFromU8 } from 'fflate';
import { CoreService } from '../src/core/service';
import { PackageTasks, type PackageTask } from '../src/core/package-tasks';
import type { AppDefinition } from '../src/shared/types';

const definition: AppDefinition = {
  schemaVersion: 1,
  name: 'Portable',
  entities: [
    {
      id: 'items',
      name: 'Items',
      fields: [
        { id: 'name', name: 'Name', type: 'text' },
        { id: 'related', name: 'Related', type: 'relation', targetEntity: 'items' },
        { id: 'file', name: 'File', type: 'attachment' },
      ],
    },
  ],
  screens: [],
  actions: [],
  automations: [],
  extensions: [],
  permissions: [],
};
async function fixture(
  run: (
    core: CoreService,
    root: string,
    tasks: PackageTasks,
    events: PackageTask[],
  ) => Promise<void>,
) {
  const root = mkdtempSync(join(tmpdir(), 'everything-package-test-'));
  const core = new CoreService(join(root, 'profile'));
  const workerPath = join(root, 'package-worker.cjs');
  await build({
    entryPoints: [resolve('src/core/package-worker.ts')],
    outfile: workerPath,
    bundle: true,
    platform: 'node',
    format: 'cjs',
    logLevel: 'silent',
  });
  const events: PackageTask[] = [];
  const tasks = new PackageTasks(core, workerPath, (_event, value) => events.push(value));
  try {
    await run(core, root, tasks, events);
  } finally {
    await tasks.shutdown();
    core.close();
    rmSync(root, { recursive: true, force: true });
  }
}

test('demo fixtures export separately and template never copies personal rows', () =>
  fixture(async (core, root, tasks) => {
    const app = await core.handle('apps.create', { definition });
    await core.handle('records.upsert', {
      appId: app.id,
      entityId: 'items',
      values: { name: 'PRIVATE' },
    });
    await core.handle('packages.demoSave', {
      appId: app.id,
      records: [
        { id: 'example', entityId: 'items', values: { name: 'Example' } },
        {
          id: 'example2',
          entityId: 'items',
          values: { name: 'Related example', related: 'example' },
        },
      ],
    });
    const path = join(root, 'template.everyapp');
    await tasks.export({ appId: app.id, mode: 'template', includeDemo: true, path }, 'demo-export');
    const files = unzipSync(readFileSync(path));
    assert.deepEqual(JSON.parse(strFromU8(files['data.json'])), []);
    assert.equal(JSON.parse(strFromU8(files['demo-data.json'])).length, 2);
    assert(!Object.values(files).some((bytes) => strFromU8(bytes).includes('PRIVATE')));
    const preview = await tasks.importPreview(path, 'demo-import');
    assert.equal(preview.demoRecordCount, 2);
    const imported = await core.handle('packages.importCommit', { previewId: preview.previewId });
    assert.equal(imported.report.demoRecords, 2);
    const rows = await core.handle('records.list', { appId: imported.app.id, entityId: 'items' });
    const original = rows.records.find((r: any) => r.values.name === 'Example');
    assert(rows.records.some((r: any) => r.values.related === original.id));
    await tasks.export({ appId: imported.app.id, mode: 'template', path }, 'without-demo');
    assert.deepEqual(JSON.parse(strFromU8(unzipSync(readFileSync(path))['demo-data.json'])), []);
    await assert.rejects(
      core.handle('packages.demoSave', {
        appId: app.id,
        records: [{ id: 'bad', entityId: 'items', values: { related: 'private-id' } }],
      }),
      /недоступна/,
    );
    await assert.rejects(
      core.handle('packages.demoSave', {
        appId: app.id,
        records: [{ id: 'bad', entityId: 'items', values: { file: 'private-file' } }],
      }),
      /личные вложения/,
    );
  }));

test('cancelled export keeps existing destination and removes temporary writes', () =>
  fixture(async (core, root, tasks, events) => {
    const app = await core.handle('apps.create', { definition });
    const path = join(root, 'existing.everyapp');
    writeFileSync(path, 'existing file');
    const promise = tasks.export({ appId: app.id, mode: 'template', path }, 'cancel-export');
    const rejection = assert.rejects(promise, /отменена/);
    assert.equal((await tasks.cancel('cancel-export')).cancelled, true);
    await rejection;
    assert.equal(readFileSync(path, 'utf8'), 'existing file');
    assert(!readdirSync(root).some((name) => name.endsWith('.tmp')));
    assert.equal(tasks.status('cancel-export')?.status, 'cancelled');
    assert(events.some((event) => event.status === 'cancelled'));
  }));

test('cancelled import never installs or registers an activation preview', () =>
  fixture(async (core, root, tasks) => {
    const app = await core.handle('apps.create', { definition });
    const path = join(root, 'app.everyapp');
    await core.handle('packages.export', { appId: app.id, mode: 'template', path });
    const promise = tasks.importPreview(path, 'cancel-import');
    const rejection = assert.rejects(promise, /отменена/);
    await tasks.cancel('cancel-import');
    await rejection;
    assert.equal((await core.handle('apps.list')).length, 1);
    await assert.rejects(
      core.handle('packages.importCommit', { previewId: 'cancel-import' }),
      /Предпросмотр/,
    );
  }));

test('validated import commits staged content even if the original file is replaced', () =>
  fixture(async (core, root, tasks, events) => {
    const app = await core.handle('apps.create', { definition });
    const path = join(root, 'staged.everyapp');
    await tasks.export({ appId: app.id, mode: 'template', path }, 'staged-export');
    const preview = await tasks.importPreview(path, 'staged-import');
    writeFileSync(path, 'replaced after preview');
    const imported = await core.handle('packages.importCommit', { previewId: preview.previewId });
    assert.equal(imported.app.name, 'Portable');
    assert(events.some((event) => event.completed > 0 && event.total >= event.completed));
  }));

test('cancellation during real compression discards bytes already written', () =>
  fixture(async (core, root) => {
    const app = await core.handle('apps.create', { definition });
    for (let i = 0; i < 20; i++)
      await core.handle('records.upsert', {
        appId: app.id,
        entityId: 'items',
        values: { name: String(i) + 'x'.repeat(100_000) },
      });
    const path = join(root, 'partial.everyapp');
    writeFileSync(path, 'old archive');
    let progressObserved = false;
    const tasks = new PackageTasks(core, join(root, 'package-worker.cjs'), (_event, event) => {
      if (!progressObserved && event.completed > 0 && event.status === 'running') {
        progressObserved = true;
        void tasks.cancel(event.id);
      }
    });
    try {
      await assert.rejects(
        tasks.export({ appId: app.id, mode: 'data', path }, 'mid-write'),
        /отменена/,
      );
      assert(progressObserved, 'must cancel after compressor consumed bytes');
      assert.equal(readFileSync(path, 'utf8'), 'old archive');
      assert(!readdirSync(root).some((name) => name.endsWith('.tmp')));
    } finally {
      await tasks.shutdown();
    }
  }));
