import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CoreService } from '../src/core/service';
import { RuntimeService } from '../src/runtime/service';
import { emptyDefinition } from '../src/core/schema';
function reply(name?: string, input?: any) {
  const delta = name
    ? {
        tool_calls: [
          { index: 0, id: `call_${name}`, function: { name, arguments: JSON.stringify(input) } },
        ],
      }
    : { content: 'Готово' };
  return new Response(
    `data: ${JSON.stringify({ choices: [{ delta }], usage: { prompt_tokens: 12, completion_tokens: 8 } })}\n\ndata: [DONE]\n\n`,
    { headers: { 'content-type': 'text/event-stream' } },
  );
}
async function finish(runtime: RuntimeService, id: string) {
  for (let i = 0; i < 300; i++) {
    const run = await runtime.handle('agent.status', { runId: id });
    if (run.status === 'completed') return run;
    if (['failed', 'waiting_approval'].includes(run.status)) throw Error(JSON.stringify(run));
    await new Promise((r) => setTimeout(r, 5));
  }
  throw Error('Mock provider journey timed out');
}
test('mock provider creates and changes a real persisted app while preserving user records', async () => {
  const root = mkdtempSync(join(tmpdir(), 'everything-provider-journey-'));
  const core = new CoreService(root);
  let runtime: RuntimeService;
  let phase = 'create',
    request = 0,
    draftId = '';
  const base = emptyDefinition('Книги');
  base.entities = [
    {
      id: 'books',
      name: 'Книги',
      fields: [{ id: 'title', name: 'Название', type: 'text', required: true }],
    },
  ];
  base.screens = [{ id: 'books', name: 'Книги', type: 'table', entityId: 'books' }];
  const changed = structuredClone(base);
  changed.entities[0].fields.push({
    id: 'read',
    name: 'Прочитано',
    type: 'boolean',
    default: false,
  });
  changed.entities.push({
    id: 'authors',
    name: 'Авторы',
    fields: [{ id: 'name', name: 'Имя', type: 'text', required: true }],
  });
  changed.entities[0].fields.push({
    id: 'author',
    name: 'Автор',
    type: 'relation',
    targetEntity: 'authors',
  });
  changed.screens.push({ id: 'authors', name: 'Авторы', type: 'table', entityId: 'authors' });
  runtime = new RuntimeService(
    {
      handle: async (method, p) => {
        const result = await core.handle(method, p);
        if (method === 'definitions.prepare') draftId = result.draftId;
        return result;
      },
    },
    {
      readSecret: async () => 'MOCK_ONLY',
      writeSecret: async () => {},
      executeAction: async () => ({}),
      fetch: async () => {
        const n = request++;
        if (phase === 'create')
          return n === 0 ? reply('app_create', { name: 'Книги', definition: base }) : reply();
        if (n === 0) return reply('app_inspect', {});
        if (n === 1) return reply('definition_prepare', { definition: changed });
        if (n === 2) return reply('definition_activate', { draftId });
        return reply();
      },
    },
  );
  try {
    await runtime.handle('provider.save', {
      type: 'openai',
      endpoint: 'https://mock.invalid/v1',
      model: 'fixture',
    });
    const created = await finish(
      runtime,
      (await runtime.handle('agent.run', { message: 'Создай список книг' })).id,
    );
    const appId = created.appId;
    assert(appId);
    const row = await core.handle('records.upsert', {
      appId,
      entityId: 'books',
      values: { title: 'Моя книга' },
    });
    phase = 'edit';
    request = 0;
    await finish(
      runtime,
      (
        await runtime.handle('agent.run', {
          appId,
          message: 'Добавь авторов и отметку прочитано, сохрани книги',
        })
      ).id,
    );
    const app = await core.handle('apps.get', { appId });
    assert.equal(app.definition.entities.length, 2);
    assert.equal(app.definition.screens.length, 2);
    const rows = await core.handle('records.list', { appId, entityId: 'books' });
    assert.equal(rows.records[0].id, row.id);
    assert.equal(rows.records[0].values.title, 'Моя книга');
    assert.equal(rows.records[0].values.read, false);
    await runtime.handle('provider.save', {
      type: 'openai',
      endpoint: 'https://mock.invalid/v1',
      model: '',
    });
    assert.equal((await core.handle('records.list', { appId, entityId: 'books' })).total, 1);
  } finally {
    await runtime.shutdown();
    core.close();
    rmSync(root, { recursive: true, force: true });
  }
});
