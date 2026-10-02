import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { strFromU8, strToU8, unzipSync, zipSync } from 'fflate';
import { emptyDefinition, validateDefinition } from '../src/core/schema';
import { CoreService } from '../src/core/service';
import type { AppDefinition } from '../src/shared/types';

function definition(): AppDefinition {
  return {
    ...emptyDefinition('Рисовалка'),
    entities: [
      { id: 'drawings', name: 'Рисунки', fields: [{ id: 'name', name: 'Имя', type: 'text' }] },
    ],
    screens: [
      { id: 'canvas', name: 'Холст', type: 'custom', config: { extensionId: 'canvasScreen' } },
    ],
    actions: [
      { id: 'save', name: 'Сохранить', type: 'extension', config: { extensionId: 'saveDrawing' } },
    ],
    extensions: [
      { id: 'canvasScreen', name: 'Холст', kind: 'component', source: 'export default () => null' },
      {
        id: 'saveDrawing',
        name: 'Сохранить',
        kind: 'handler',
        source: 'export default () => ({ ok: true })',
      },
    ],
  };
}

async function fixture(fn: (core: CoreService, root: string) => Promise<void>) {
  const root = mkdtempSync(join(tmpdir(), 'everything-definition-references-'));
  const core = new CoreService(root);
  try {
    await fn(core, root);
  } finally {
    core.close();
    rmSync(root, { recursive: true, force: true });
  }
}

test('custom screens require explicit references to existing component extensions', () => {
  assert.doesNotThrow(() => validateDefinition(definition()));
  for (const config of [
    undefined,
    {},
    { extensionId: '' },
    { extensionId: ' ' },
    { extensionId: 1 },
    { extensionId: 'missing' },
    { extensionId: 'saveDrawing' },
  ]) {
    const invalid = definition();
    invalid.screens[0].config = config;
    assert.throws(
      () => validateDefinition(invalid),
      /Экран canvas:.*config\.extensionId.*component.*canvasScreen/,
    );
  }
  const noExtensions = definition();
  noExtensions.extensions = [];
  assert.throws(() => validateDefinition(noExtensions), /Сначала добавьте расширение.*component/);
});

test('extension actions require handler references while built-in actions need no extension', () => {
  for (const config of [
    undefined,
    {},
    { extensionId: '' },
    { extensionId: ' ' },
    { extensionId: false },
    { extensionId: 'missing' },
    { extensionId: 'canvasScreen' },
  ]) {
    const invalid = definition();
    invalid.actions[0].config = config;
    assert.throws(
      () => validateDefinition(invalid),
      /Действие save:.*config\.extensionId.*handler.*saveDrawing/,
    );
  }
  const builtIn = definition();
  builtIn.screens = [{ id: 'drawings', name: 'Рисунки', type: 'table', entityId: 'drawings' }];
  builtIn.actions = [
    { id: 'notify', name: 'Уведомить', type: 'notification', config: { title: 'Готово' } },
  ];
  builtIn.extensions = [];
  assert.doesNotThrow(() => validateDefinition(builtIn));
});

test('invalid extension references cannot create partial apps or replace a working definition', () =>
  fixture(async (core) => {
    const invalid = definition();
    delete invalid.screens[0].config;
    await assert.rejects(
      core.handle('apps.create', { definition: invalid }),
      /Экран canvas:.*config\.extensionId/,
    );
    assert.deepEqual(await core.handle('apps.list'), []);
    assert.equal(core.db.prepare('SELECT count(*) AS count FROM definitions').get()?.count, 0);
    assert.equal(core.db.prepare('SELECT count(*) AS count FROM origins').get()?.count, 0);

    const app = await core.handle('apps.create', { definition: definition() });
    const drawing = await core.handle('records.upsert', {
      appId: app.id,
      entityId: 'drawings',
      values: { name: 'Мой рисунок' },
    });
    const before = await core.handle('apps.get', { appId: app.id });
    for (const extensionId of ['canvasScreen', 'saveDrawing']) {
      const next = definition();
      next.extensions = next.extensions.filter((extension) => extension.id !== extensionId);
      await assert.rejects(
        core.handle('definitions.prepare', { appId: app.id, definition: next }),
        /config\.extensionId/,
      );
    }
    assert.deepEqual(await core.handle('apps.get', { appId: app.id }), before);
    assert.deepEqual(
      (await core.handle('records.list', { appId: app.id, entityId: 'drawings' })).records,
      [drawing],
    );
    assert.equal(core.db.prepare('SELECT count(*) AS count FROM drafts').get()?.count, 0);
  }));

test('import rejects a correctly hashed package with an unbound custom screen without installing it', () =>
  fixture(async (core, root) => {
    const app = await core.handle('apps.create', { definition: definition() });
    const path = join(root, 'broken.everyapp');
    await core.handle('packages.export', { appId: app.id, mode: 'template', path });
    const files = unzipSync(readFileSync(path));
    const invalid = definition();
    invalid.screens[0].config = {};
    files['definition.json'] = strToU8(JSON.stringify(invalid));
    const manifest = JSON.parse(strFromU8(files['manifest.json']));
    manifest.hashes['definition.json'] = createHash('sha256')
      .update(files['definition.json'])
      .digest('hex');
    files['manifest.json'] = strToU8(JSON.stringify(manifest));
    writeFileSync(path, zipSync(files));
    await assert.rejects(
      core.handle('packages.importPreview', { path }),
      /Экран canvas:.*config\.extensionId/,
    );
    assert.equal((await core.handle('apps.list')).length, 1);
    assert.deepEqual((await core.handle('apps.get', { appId: app.id })).definition, app.definition);
  }));
