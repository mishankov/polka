import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { zipSync, unzipSync, strToU8 } from 'fflate';
import { CoreService } from '../src/core/service';
import type { AppDefinition } from '../src/shared/types';
import { boundedUnzip } from '../src/core/bounded-zip';

const definition = (): AppDefinition => ({
  schemaVersion: 1,
  name: 'Проверка',
  entities: [
    {
      id: 'folders',
      name: 'Папки',
      fields: [{ id: 'name', name: 'Название', type: 'text', required: true, unique: true }],
    },
    {
      id: 'items',
      name: 'Записи',
      fields: [
        { id: 'title', name: 'Название', type: 'text', required: true },
        { id: 'amount', name: 'Количество', type: 'number' },
        { id: 'folder', name: 'Папка', type: 'relation', targetEntity: 'folders' },
        { id: 'file', name: 'Файл', type: 'attachment' },
      ],
    },
  ],
  screens: [{ id: 'items', name: 'Записи', type: 'table', entityId: 'items' }],
  actions: [],
  automations: [],
  extensions: [],
  permissions: ['clipboard.read'],
});
async function fixture(fn: (core: CoreService, root: string) => Promise<void>) {
  const root = mkdtempSync(join(tmpdir(), 'everything-core-'));
  const core = new CoreService(root);
  try {
    await fn(core, root);
  } finally {
    core.close();
    rmSync(root, { recursive: true, force: true });
  }
}

test('opening starts an app without changing its data, metadata or permissions', () =>
  fixture(async (c) => {
    const app = await c.handle('apps.create', { definition: definition() });
    await c.handle('apps.updateMeta', {
      appId: app.id,
      name: 'Мои записи',
      icon: '📒',
      favorite: true,
    });
    const record = await c.handle('records.upsert', {
      appId: app.id,
      entityId: 'items',
      values: { title: 'Сохранённая запись', amount: 7 },
    });
    await c.handle('permissions.grant', { appId: app.id, permission: 'clipboard.read' });
    const permissions = await c.handle('permissions.list', { appId: app.id });

    for (const status of ['stopped', 'archived']) {
      await c.handle('apps.updateMeta', { appId: app.id, status });
      // An old timestamp makes the no-op assertion independent of clock resolution.
      c.db
        .prepare('UPDATE apps SET updatedAt=? WHERE id=?')
        .run('2020-01-01T00:00:00.000Z', app.id);
      const before = await c.handle('apps.get', { appId: app.id });
      const listed = (await c.handle('apps.list')).find((item: any) => item.id === app.id);
      assert.deepEqual(listed, before, 'listing an app must not start it');
      assert.equal(before.status, status, 'inspecting an app must not start it');

      const started = await c.handle('apps.start', { appId: app.id });
      assert.equal(started.status, 'running');
      assert.notEqual(started.updatedAt, before.updatedAt);
      assert.deepEqual(started, { ...before, status: 'running', updatedAt: started.updatedAt });

      c.db
        .prepare('UPDATE apps SET updatedAt=? WHERE id=?')
        .run('2021-01-01T00:00:00.000Z', app.id);
      const running = await c.handle('apps.get', { appId: app.id });
      assert.deepEqual(await c.handle('apps.start', { appId: app.id }), running);
      assert.deepEqual(await c.handle('permissions.list', { appId: app.id }), permissions);
      assert.deepEqual(
        (await c.handle('records.list', { appId: app.id, entityId: 'items' })).records,
        [record],
      );
    }

    await c.handle('apps.updateMeta', { appId: app.id, status: 'stopped' });
    assert.equal((await c.handle('apps.get', { appId: app.id })).status, 'stopped');
    assert.equal((await c.handle('apps.start', { appId: app.id })).status, 'running');
    await assert.rejects(c.handle('apps.start', { appId: 'missing' }), /не найдено/);
    await assert.rejects(c.callScoped(app.id, 'apps.start'), /недоступна/);
  }));

test('SQLite CRUD, constraints, querying, pagination and instance boundaries', () =>
  fixture(async (c) => {
    const a = await c.handle('apps.create', { definition: definition() }),
      b = await c.handle('apps.create', { definition: definition() });
    const folder = await c.handle('records.upsert', {
      appId: a.id,
      entityId: 'folders',
      values: { name: 'Первая' },
    });
    await assert.rejects(
      c.handle('records.upsert', { appId: a.id, entityId: 'folders', values: { name: 'Первая' } }),
      /уникальным/,
    );
    await assert.rejects(
      c.handle('records.upsert', {
        appId: a.id,
        entityId: 'items',
        values: { title: 'Неверная', amount: '2' },
      }),
      /тип/,
    );
    await assert.rejects(
      c.handle('records.upsert', {
        appId: b.id,
        entityId: 'items',
        values: { title: 'Чужая', folder: folder.id },
      }),
      /недоступна/,
    );
    await assert.rejects(
      c.callScoped(b.id, 'records.list', { appId: a.id, entityId: 'folders' }),
      /запрещён/,
    );
    await assert.rejects(c.callScoped(b.id, 'settings.get', {}), /недоступна/);
    const r = await c.handle('records.upsert', {
      appId: a.id,
      entityId: 'items',
      values: { title: 'Тест', amount: 2, folder: folder.id },
    });
    assert.equal(
      (
        await c.handle('records.list', {
          appId: a.id,
          entityId: 'items',
          filters: [{ field: 'amount', op: 'gt', value: 1 }],
          limit: 1,
        })
      ).total,
      1,
    );
    await assert.rejects(
      c.handle('records.delete', { appId: a.id, entityId: 'folders', id: folder.id }),
      /используется/,
    );
    await c.handle('records.delete', { appId: a.id, entityId: 'items', id: r.id });
    assert.equal((await c.handle('records.list', { appId: b.id, entityId: 'folders' })).total, 0);
  }));

test('definition activation preserves records and rejects stale migrations', () =>
  fixture(async (c) => {
    const app = await c.handle('apps.create', { definition: definition() });
    await c.handle('records.upsert', {
      appId: app.id,
      entityId: 'items',
      values: { title: 'Сохранить' },
    });
    const next = definition();
    next.entities[1].fields.push({
      id: 'status',
      name: 'Статус',
      type: 'text',
      default: 'Новый',
      required: true,
    });
    const draft = await c.handle('definitions.prepare', { appId: app.id, definition: next });
    await c.handle('records.upsert', {
      appId: app.id,
      entityId: 'items',
      values: { title: 'Параллельная' },
    });
    await assert.rejects(
      c.handle('definitions.activate', { draftId: draft.draftId }),
      /изменились/,
    );
    const fresh = await c.handle('definitions.prepare', { appId: app.id, definition: next });
    assert.equal((await c.handle('definitions.activate', { draftId: fresh.draftId })).version, 2);
    const rows = await c.handle('records.list', { appId: app.id, entityId: 'items' });
    assert.equal(rows.total, 2);
    assert.ok(rows.records.every((r: any) => r.values.status === 'Новый'));
    const bad = definition();
    bad.entities = bad.entities.filter((e) => e.id !== 'items');
    bad.screens = [];
    await assert.rejects(
      c.handle('definitions.prepare', { appId: app.id, definition: bad }),
      /содержит записи/,
    );
    assert.equal((await c.handle('apps.get', { appId: app.id })).version, 2);
  }));

test('snapshot recovery is explicit, consistent and creates a safety snapshot', () =>
  fixture(async (c) => {
    const app = await c.handle('apps.create', { definition: definition() });
    const original = await c.handle('records.upsert', {
      appId: app.id,
      entityId: 'items',
      values: { title: 'До' },
    });
    const snapshot = await c.handle('snapshots.create', { appId: app.id });
    await c.handle('records.upsert', {
      appId: app.id,
      entityId: 'items',
      id: original.id,
      values: { title: 'После' },
    });
    await assert.rejects(
      c.handle('snapshots.restore', { appId: app.id, snapshotId: snapshot.id }),
      /Подтвердите/,
    );
    await c.handle('snapshots.restore', { appId: app.id, snapshotId: snapshot.id, confirm: true });
    assert.equal(
      (await c.handle('records.list', { appId: app.id, entityId: 'items' })).records[0].values
        .title,
      'До',
    );
    assert.equal((await c.handle('snapshots.list', { appId: app.id })).length, 2);
  }));

test('portable data package remaps relations and attachments on repeated import', () =>
  fixture(async (c, root) => {
    const app = await c.handle('apps.create', { definition: definition() });
    const folder = await c.handle('records.upsert', {
      appId: app.id,
      entityId: 'folders',
      values: { name: 'Папка' },
    });
    const file = join(root, 'source.txt');
    writeFileSync(file, 'Привет, вложение');
    const attachment = await c.handle('attachments.add', { appId: app.id, path: file });
    await c.handle('records.upsert', {
      appId: app.id,
      entityId: 'items',
      values: { title: 'Связанная', folder: folder.id, file: attachment.id },
    });
    await c.handle('permissions.grant', { appId: app.id, permission: 'clipboard.read' });
    const path = join(root, 'test.everyapp');
    await c.handle('packages.export', { appId: app.id, mode: 'data', path });
    const resultIds = [];
    for (let i = 0; i < 2; i++) {
      const preview = await c.handle('packages.importPreview', { path });
      assert.equal(preview.recordCount, 2);
      const result = await c.handle('packages.importCommit', { previewId: preview.previewId });
      resultIds.push(result.app.id);
      const importedFolder = (
        await c.handle('records.list', { appId: result.app.id, entityId: 'folders' })
      ).records[0];
      const item = (await c.handle('records.list', { appId: result.app.id, entityId: 'items' }))
        .records[0];
      assert.notEqual(importedFolder.id, folder.id);
      assert.equal(item.values.folder, importedFolder.id);
      assert.notEqual(item.values.file, attachment.id);
      assert.equal(
        Buffer.from(
          (await c.handle('attachments.read', { appId: result.app.id, id: item.values.file }))
            .base64,
          'base64',
        ).toString(),
        'Привет, вложение',
      );
      assert.deepEqual(await c.handle('permissions.list', { appId: result.app.id }), []);
    }
    assert.notEqual(resultIds[0], resultIds[1]);
    assert.equal((await c.handle('apps.list')).length, 3);
    await assert.rejects(
      c.handle('packages.preview', { appId: app.id, mode: 'data', entityIds: ['items'] }),
      /связанная запись/,
    );
  }));

test('template excludes private records, attachments, settings and permissions', () =>
  fixture(async (c, root) => {
    const app = await c.handle('apps.create', { definition: definition() });
    await c.handle('records.upsert', {
      appId: app.id,
      entityId: 'items',
      values: { title: 'PRIVATE_SENTINEL' },
    });
    await c.handle('state.set', { key: 'internal', value: 'SECRET_SENTINEL' });
    const path = join(root, 'template.everyapp');
    await c.handle('packages.export', { appId: app.id, mode: 'template', path });
    const files = unzipSync(readFileSync(path));
    assert.equal(new TextDecoder().decode(files['data.json']), '[]');
    assert.ok(!Object.values(files).some((v) => new TextDecoder().decode(v).includes('SENTINEL')));
    const preview = await c.handle('packages.importPreview', { path });
    assert.equal(preview.recordCount, 0);
  }));

test('malicious archive paths, tampering and changed-preview imports are rejected without mutation', () =>
  fixture(async (c, root) => {
    const app = await c.handle('apps.create', { definition: definition() }),
      path = join(root, 'evil.everyapp');
    writeFileSync(path, zipSync({ '../evil': strToU8('hello') }));
    await assert.rejects(c.handle('packages.importPreview', { path }), /путь/);
    await c.handle('packages.export', { appId: app.id, mode: 'template', path });
    const files = unzipSync(readFileSync(path));
    files['definition.json'] = strToU8('{}');
    writeFileSync(path, zipSync(files));
    await assert.rejects(c.handle('packages.importPreview', { path }), /хеш/);
    await c.handle('packages.export', { appId: app.id, mode: 'template', path });
    const preview = await c.handle('packages.importPreview', { path });
    writeFileSync(path, 'changed');
    await assert.rejects(
      c.handle('packages.importCommit', { previewId: preview.previewId }),
      /изменился/,
    );
    assert.equal((await c.handle('apps.list')).length, 1);
  }));

test('cross-app links are explicit, scoped, and revocation takes effect immediately', () =>
  fixture(async (c) => {
    const a = await c.handle('apps.create', { definition: definition() }),
      b = await c.handle('apps.create', { definition: definition() });
    await c.handle('apps.updateMeta', { appId: b.id, status: 'running' });
    await c.handle('records.upsert', {
      appId: b.id,
      entityId: 'folders',
      values: { name: 'Разрешено' },
    });
    const link = await c.handle('links.grant', {
      sourceAppId: a.id,
      targetAppId: b.id,
      entityId: 'folders',
    });
    assert.equal((await c.callScoped(a.id, 'links.query', { linkId: link.id })).total, 1);
    await assert.rejects(c.callScoped(b.id, 'links.query', { linkId: link.id }), /не разрешена/);
    await c.handle('links.revoke', { id: link.id });
    await assert.rejects(c.callScoped(a.id, 'links.query', { linkId: link.id }), /отозван/);
  }));

test('split and merge create independent instances and detect intervening writes', () =>
  fixture(async (c) => {
    const a = await c.handle('apps.create', { definition: definition() }),
      b = await c.handle('apps.create', { definition: definition() });
    await c.handle('records.upsert', { appId: a.id, entityId: 'folders', values: { name: 'А' } });
    await c.handle('records.upsert', { appId: b.id, entityId: 'folders', values: { name: 'Б' } });
    const split = await c.handle('apps.splitPreview', {
      appId: a.id,
      entityIds: ['folders'],
      name: 'Часть',
    });
    const splitResult = await c.handle('apps.splitCommit', { previewId: split.previewId });
    assert.equal(splitResult.app.definition.entities.length, 1);
    const merge = await c.handle('apps.mergePreview', { appIds: [a.id, b.id], name: 'Вместе' });
    const combined = await c.handle('apps.mergeCommit', { previewId: merge.previewId });
    assert.equal(
      (await c.handle('records.list', { appId: combined.app.id, entityId: 'a1_folders' })).total,
      1,
    );
    assert.equal(
      (await c.handle('records.list', { appId: combined.app.id, entityId: 'a2_folders' })).total,
      1,
    );
    const stale = await c.handle('apps.splitPreview', { appId: a.id, entityIds: ['folders'] });
    await c.handle('records.upsert', {
      appId: a.id,
      entityId: 'folders',
      values: { name: 'Новая' },
    });
    await assert.rejects(
      c.handle('apps.splitCommit', { previewId: stale.previewId }),
      /изменились/,
    );
  }));

test('SQLite records and state survive service restart', async () => {
  const root = mkdtempSync(join(tmpdir(), 'everything-restart-'));
  let c = new CoreService(root);
  try {
    const app = await c.handle('apps.create', { definition: definition() });
    await c.handle('records.upsert', {
      appId: app.id,
      entityId: 'items',
      values: { title: 'Перезапуск' },
    });
    await c.handle('state.set', { key: 'job', value: { state: 'pending' } });
    c.close();
    c = new CoreService(root);
    assert.equal((await c.handle('records.list', { appId: app.id, entityId: 'items' })).total, 1);
    assert.deepEqual(await c.handle('state.get', { key: 'job' }), { state: 'pending' });
  } finally {
    c.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test('package update three-way merges local edits, preserves data and rejects conflicts', () =>
  fixture(async (c, root) => {
    const source = await c.handle('apps.create', { definition: definition() }),
      path = join(root, 'update.everyapp');
    await c.handle('packages.export', { appId: source.id, mode: 'template', path });
    const preview = await c.handle('packages.importPreview', { path });
    const target = (await c.handle('packages.importCommit', { previewId: preview.previewId })).app;
    await c.handle('records.upsert', {
      appId: target.id,
      entityId: 'items',
      values: { title: 'Личные данные' },
    });
    const local = structuredClone(target.definition);
    local.theme = { primaryColor: 'grape' };
    const localDraft = await c.handle('definitions.prepare', {
      appId: target.id,
      definition: local,
    });
    await c.handle('definitions.activate', { draftId: localDraft.draftId });
    const next = definition();
    next.entities[1].fields.push({ id: 'note', name: 'Заметка', type: 'text' });
    const sourceDraft = await c.handle('definitions.prepare', {
      appId: source.id,
      definition: next,
    });
    await c.handle('definitions.activate', { draftId: sourceDraft.draftId });
    await c.handle('packages.export', { appId: source.id, mode: 'template', path });
    const update = await c.handle('packages.updatePreview', { appId: target.id, path });
    assert.equal(update.definition.theme.primaryColor, 'grape');
    const result = await c.handle('packages.updateCommit', { previewId: update.previewId });
    assert.equal(result.app.sourceVersion, 2);
    assert.equal(result.app.definition.entities[1].fields.at(-1).id, 'note');
    assert.equal(
      (await c.handle('records.list', { appId: target.id, entityId: 'items' })).records[0].values
        .title,
      'Личные данные',
    );
    const conflicting = structuredClone(result.app.definition);
    conflicting.name = 'Личное имя';
    const d1 = await c.handle('definitions.prepare', { appId: target.id, definition: conflicting });
    await c.handle('definitions.activate', { draftId: d1.draftId });
    next.name = 'Имя автора';
    const d2 = await c.handle('definitions.prepare', { appId: source.id, definition: next });
    await c.handle('definitions.activate', { draftId: d2.draftId });
    await c.handle('packages.export', { appId: source.id, mode: 'template', path });
    await assert.rejects(
      c.handle('packages.updatePreview', { appId: target.id, path }),
      /Конфликт.*definition.name/,
    );
  }));

test('selected managed documents transfer without external paths or history', () =>
  fixture(async (c, root) => {
    const app = await c.handle('apps.create', { definition: definition() });
    await c.handle('state.set', {
      key: 'documents',
      value: [
        {
          id: 'doc1',
          appId: app.id,
          name: 'Текст',
          kind: 'text',
          content: 'Выбранный документ',
          encoding: 'utf8',
          lineEnding: 'LF',
          path: '/private/secret/file.txt',
          history: ['PRIVATE_HISTORY'],
          diskHash: 'OLD_HASH',
        },
        { id: 'doc2', appId: app.id, name: 'Личное', kind: 'text', content: 'PRIVATE_CONTENT' },
      ],
    });
    const path = join(root, 'documents.everyapp');
    await c.handle('packages.export', { appId: app.id, mode: 'data', documentIds: ['doc1'], path });
    const files = unzipSync(readFileSync(path)),
      text = new TextDecoder().decode(files['documents.json']);
    assert.ok(text.includes('Выбранный'));
    assert.ok(!text.includes('PRIVATE'));
    assert.ok(!text.includes('/private'));
    const preview = await c.handle('packages.importPreview', { path });
    assert.equal(preview.documents.length, 1);
    const installed = await c.handle('packages.importCommit', { previewId: preview.previewId });
    const docs = (await c.handle('state.get', { key: 'documents' })).filter(
      (d: any) => d.appId === installed.app.id,
    );
    assert.equal(docs.length, 1);
    assert.notEqual(docs[0].id, 'doc1');
    assert.equal(docs[0].external, false);
    assert.equal(docs[0].path, undefined);
  }));

test('bounded ZIP streaming rejects lying sizes and actual decompression limits', () => {
  const compressed = zipSync({ 'data.json': new Uint8Array(2 * 1024 * 1024) }, { level: 9 });
  assert.throws(() => boundedUnzip(compressed, 1024 * 1024), /лимит/);
  const forged = compressed.slice();
  new DataView(forged.buffer).setUint32(22, 1, true);
  assert.throws(() => boundedUnzip(forged, 1024 * 1024), /фактический лимит/);
  assert.throws(() => boundedUnzip(forged, 4 * 1024 * 1024), /не совпадает/);
  assert.throws(() => boundedUnzip(compressed.slice(0, -10)), /не завершён/);
});

test('batch operations validate complete final state and roll back atomically', () =>
  fixture(async (c) => {
    const app = await c.handle('apps.create', { definition: definition() });
    await c.handle('records.batch', {
      appId: app.id,
      operations: [
        {
          type: 'upsert',
          entityId: 'items',
          id: 'child',
          values: { title: 'Ссылка вперёд', folder: 'parent' },
        },
        { type: 'upsert', entityId: 'folders', id: 'parent', values: { name: 'Родитель' } },
      ],
    });
    await assert.rejects(
      c.handle('records.batch', {
        appId: app.id,
        operations: [
          { type: 'delete', entityId: 'folders', id: 'parent' },
          { type: 'upsert', entityId: 'items', values: { title: 'Не должно сохраниться' } },
        ],
      }),
      /недоступна/,
    );
    assert.equal((await c.handle('records.list', { appId: app.id, entityId: 'items' })).total, 1);
    const next = definition();
    next.entities[1].fields.push({
      id: 'uniqueDefault',
      name: 'Номер',
      type: 'text',
      unique: true,
      default: 'same',
    });
    await c.handle('records.upsert', {
      appId: app.id,
      entityId: 'items',
      values: { title: 'Вторая' },
    });
    await assert.rejects(
      c.handle('definitions.prepare', { appId: app.id, definition: next }),
      /уникальным/,
    );
  }));

test('definition themes accept only supported palette and radius tokens', () =>
  fixture(async (c) => {
    const valid = definition();
    valid.theme = { mode: 'dark', primaryColor: 'teal', density: 'compact', radius: 'lg' };
    const app = await c.handle('apps.create', { definition: valid });
    assert.equal(app.definition.theme.primaryColor, 'teal');
    for (const theme of [
      { primaryColor: '#ff0000' },
      { primaryColor: 'unknown' },
      { radius: 'enormous' },
    ]) {
      const invalid = definition();
      invalid.theme = theme;
      await assert.rejects(
        c.handle('definitions.prepare', { appId: app.id, definition: invalid }),
        /theme/,
      );
    }
    assert.equal((await c.handle('apps.get', { appId: app.id })).version, 1);
  }));
