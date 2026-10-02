import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CoreService } from '../src/core/service';
import { RuntimeService } from '../src/runtime/service';
import { emptyDefinition } from '../src/core/schema';
const deps = {
  readSecret: async () => null,
  writeSecret: async () => {},
  executeAction: async (_appId: string, _actionId: string, input: unknown) =>
    input ?? 'configured default',
};
async function completed(runtime: RuntimeService, id: string) {
  for (let i = 0; i < 100; i++) {
    const job = (await runtime.handle('jobs.list')).find((j: any) => j.id === id);
    if (job.status === 'completed') return job;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw Error('Timed out');
}
test('real SQLite and runtime retain job results and independently import paused automation definitions', async () => {
  const root = mkdtempSync(join(tmpdir(), 'everything-runtime-'));
  let core = new CoreService(root);
  let runtime = new RuntimeService(core, deps);
  try {
    const definition = emptyDefinition('Локальная обработка');
    definition.permissions = ['background'];
    definition.actions = [
      {
        id: 'format',
        name: 'Форматирование',
        type: 'transform',
        config: { operation: 'json.format', input: '{}' },
      },
    ];
    definition.automations = [
      {
        id: 'timer',
        name: 'По расписанию',
        actionId: 'format',
        trigger: 'interval',
        intervalMs: 60000,
        enabled: true,
      },
    ];
    const app = await core.handle('apps.create', { definition });
    await core.handle('apps.updateMeta', { appId: app.id, status: 'running' });
    await runtime.handle('runtime.syncApp', { appId: app.id });
    await core.handle('permissions.grant', { appId: app.id, permission: 'background' });
    const originalRules = await runtime.handle('automations.list', { appId: app.id });
    assert.equal(originalRules[0].enabled, false);
    await runtime.handle('automations.setEnabled', { id: originalRules[0].id, enabled: true });
    const job = await runtime.handle('jobs.enqueue', {
      appId: app.id,
      actionId: 'format',
      idempotencyKey: 'once',
    });
    assert.equal((await completed(runtime, job.id)).result, 'configured default');
    const path = join(root, 'copy.everyapp');
    await core.handle('packages.export', { appId: app.id, mode: 'template', path });
    const preview = await core.handle('packages.importPreview', { path });
    const imported = await core.handle('packages.importCommit', { previewId: preview.previewId });
    await runtime.handle('runtime.syncApp', { appId: imported.app.id });
    const copiedRules = await runtime.handle('automations.list', { appId: imported.app.id });
    assert.equal(copiedRules.length, 1);
    assert.equal(copiedRules[0].enabled, false);
    assert.notEqual(copiedRules[0].id, originalRules[0].id);
    assert.deepEqual(await core.handle('permissions.list', { appId: imported.app.id }), []);
    await runtime.shutdown();
    core.close();
    core = new CoreService(root);
    runtime = new RuntimeService(core, deps);
    const restored = (await runtime.handle('jobs.list')).find((j: any) => j.id === job.id);
    assert.equal(restored.status, 'completed');
    assert.equal(restored.result, 'configured default');
    assert.equal((await runtime.handle('automations.list')).length, 2);
    assert.equal(
      (
        await runtime.handle('jobs.enqueue', {
          appId: app.id,
          actionId: 'format',
          idempotencyKey: 'once',
        })
      ).id,
      job.id,
    );
  } finally {
    await runtime.shutdown();
    core.close();
    rmSync(root, { recursive: true, force: true });
  }
});
test('dispatch-backed RuntimeService initializes without recursive lock and syncs agent-created app', async () => {
  const root = mkdtempSync(join(tmpdir(), 'everything-runtime-dispatch-'));
  const core = new CoreService(root);
  let runtime: RuntimeService;
  async function dispatch(method: string, p: any) {
    if (method.startsWith('runtime.')) return runtime.handle(method, p);
    const result = await core.handle(method, p);
    if (method === 'apps.create') await runtime.handle('runtime.syncApp', { appId: result.id });
    return result;
  }
  runtime = new RuntimeService({ handle: dispatch }, deps);
  try {
    assert.deepEqual(await runtime.handle('jobs.list'), []);
    const d = emptyDefinition('Проверка');
    d.actions = [{ id: 'x', name: 'x', type: 'transform' }];
    d.automations = [{ id: 'a', name: 'a', trigger: 'interval', actionId: 'x' }];
    const app = await dispatch('apps.create', { definition: d });
    assert.equal((await runtime.handle('automations.list', { appId: app.id })).length, 1);
  } finally {
    await runtime.shutdown();
    core.close();
    rmSync(root, { recursive: true, force: true });
  }
});
