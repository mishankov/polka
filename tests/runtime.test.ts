import test from 'node:test';
import assert from 'node:assert/strict';
import { ProviderAdapter, readSSE, validateProvider } from '../src/runtime/providers';
import { ExecutionService, nextDaily, type RuntimeDependencies } from '../src/runtime/execution';
import { RuntimeService } from '../src/runtime/service';
function sse(chunks: unknown[], chunkSize = 7) {
  const encoded = new TextEncoder().encode(
    chunks.map((x) => `data: ${JSON.stringify(x)}\r\n\r\n`).join('') + 'data: [DONE]\r\n\r\n',
  );
  return new Response(
    new ReadableStream({
      start(controller) {
        for (let i = 0; i < encoded.length; i += chunkSize)
          controller.enqueue(encoded.slice(i, i + chunkSize));
        controller.close();
      },
    }),
  );
}
function coreMock() {
  const state: Record<string, any> = {},
    permissions = [{ permission: 'background' }, { permission: 'clipboard.read' }],
    apps: Record<string, any> = {
      one: {
        id: 'one',
        status: 'running',
        definition: {
          actions: [
            { id: 'query', name: 'Query', type: 'records.list' },
            { id: 'notify', name: 'Notify', type: 'notification' },
          ],
          permissions: [],
        },
      },
    };
  return {
    state,
    permissions,
    apps,
    handle: async (method: string, p: any) => {
      switch (method) {
        case 'state.get':
          return structuredClone(state[p.key]);
        case 'state.set':
          state[p.key] = structuredClone(p.value);
          return p.value;
        case 'apps.get':
          if (!apps[p.appId]) throw new Error('Missing app');
          return apps[p.appId];
        case 'apps.updateMeta':
          apps[p.appId] = { ...apps[p.appId], ...p };
          return apps[p.appId];
        case 'apps.create': {
          const app = { ...p, id: 'created' };
          apps.created = app;
          return app;
        }
        case 'permissions.list':
          return permissions;
        case 'records.delete':
          return { deleted: true };
        default:
          throw new Error(method);
      }
    },
  };
}
function dependencies(extra: Partial<RuntimeDependencies> = {}): RuntimeDependencies {
  return {
    readSecret: async () => null,
    writeSecret: async () => {},
    executeAction: async () => ({ ok: true }),
    ...extra,
  };
}
async function eventually(predicate: () => boolean) {
  for (let i = 0; i < 100; i++) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error('Timed out');
}
test('OpenAI streams UTF8 and assembles partial tool arguments with usage', async () => {
  let request: any;
  const adapter = new ProviderAdapter(async (_url, init) => {
    request = JSON.parse(String(init?.body));
    return sse([
      { choices: [{ delta: { content: 'Привет ' } }] },
      {
        choices: [
          {
            delta: {
              tool_calls: [
                { index: 0, id: 'c1', function: { name: 'inspect', arguments: '{"ok":' } },
              ],
            },
          },
        ],
      },
      { choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: 'true}' } }] } }] },
      { usage: { prompt_tokens: 9, completion_tokens: 5 } },
    ]);
  });
  const result = await adapter.complete(
    { type: 'openai', endpoint: 'https://example.test/v1', model: 'test' },
    'secret',
    [{ role: 'user', content: 'Hi' }],
    [{ name: 'inspect', description: 'x', inputSchema: { type: 'object' } }],
    new AbortController().signal,
  );
  assert.equal(result.text, 'Привет ');
  assert.deepEqual(result.calls, [{ id: 'c1', name: 'inspect', input: { ok: true } }]);
  assert.deepEqual(result.usage, { inputTokens: 9, outputTokens: 5 });
  assert.equal(request.stream, true);
});
test('Anthropic translates tools and assistant/tool message pairs', async () => {
  let request: any;
  const adapter = new ProviderAdapter(async (_url, init) => {
    request = JSON.parse(String(init?.body));
    return sse([
      { type: 'message_start', message: { usage: { input_tokens: 12 } } },
      {
        type: 'content_block_start',
        index: 0,
        content_block: { type: 'tool_use', id: 'abc', name: 'probe', input: {} },
      },
      {
        type: 'content_block_delta',
        index: 0,
        delta: { type: 'input_json_delta', partial_json: '{"ok":true}' },
      },
      { type: 'message_delta', usage: { output_tokens: 8 } },
    ]);
  });
  const result = await adapter.complete(
    { type: 'anthropic', endpoint: 'https://example.test/v1', model: 'test' },
    'secret',
    [
      { role: 'system', content: 'rules' },
      { role: 'user', content: 'test' },
      { role: 'assistant', content: '', calls: [{ id: 'old', name: 'probe', input: {} }] },
      { role: 'tool', content: 'ok', callId: 'old' },
    ],
    [],
    new AbortController().signal,
  );
  assert.equal(request.system, 'rules');
  assert.equal(request.messages[2].content[0].type, 'tool_result');
  assert.deepEqual(result.calls[0], { id: 'abc', name: 'probe', input: { ok: true } });
  assert.equal(result.usage.outputTokens, 8);
});
test('provider capability test fails when model ignores tool request', async () => {
  const adapter = new ProviderAdapter(async () =>
    sse([{ choices: [{ delta: { content: 'hello' } }] }]),
  );
  const result = await adapter.test(
    { type: 'openai', endpoint: 'https://example.test', model: 'm' },
    '',
    AbortSignal.timeout(1000),
  );
  assert.equal(result.tools, false);
});
test('provider refuses plaintext remote endpoints and hides response body on auth error', async () => {
  assert.throws(() =>
    validateProvider({ type: 'openai', endpoint: 'http://remote.test', model: 'm' }),
  );
  const adapter = new ProviderAdapter(async () => new Response('secret-key-leak', { status: 401 }));
  await assert.rejects(
    adapter.models(
      { type: 'openai', endpoint: 'https://example.test', model: 'm' },
      'secret',
      AbortSignal.timeout(1000),
    ),
    /отклонил ключ/,
  );
});
test('malformed SSE is rejected', async () => {
  const response = new Response('data: nope\n\n');
  await assert.rejects(async () => {
    for await (const _ of readSSE(response, AbortSignal.timeout(1000))) {
    }
  }, /Некорректный поток/);
});
test('queue persists completion and idempotency suppresses duplicate side effect', async () => {
  const core = coreMock();
  let count = 0;
  const execution = new ExecutionService(
    core,
    dependencies({
      executeAction: async () => {
        count++;
        return 42;
      },
    }),
  );
  await execution.init();
  const first = await execution.enqueue({
    appId: 'one',
    actionId: 'query',
    idempotencyKey: 'same',
  });
  await eventually(() => first.status === 'completed');
  const second = await execution.enqueue({
    appId: 'one',
    actionId: 'query',
    idempotencyKey: 'same',
  });
  assert.equal(second.id, first.id);
  assert.equal(count, 1);
  assert.equal(core.state['runtime.jobs'][0].result, 42);
  await execution.shutdown();
});
test('crash recovery marks ambiguous running effects interrupted and does not retry', async () => {
  const core = coreMock();
  core.state['runtime.jobs'] = [{ id: 'old', status: 'running', appId: 'one', actionId: 'notify' }];
  let count = 0;
  const execution = new ExecutionService(
    core,
    dependencies({
      executeAction: async () => {
        count++;
      },
    }),
  );
  await execution.init();
  assert.equal(execution.jobs[0].status, 'interrupted');
  assert.equal(count, 0);
  await execution.shutdown();
});
test('external effects ignore caller claimed retry safety', async () => {
  const core = coreMock();
  let count = 0;
  const execution = new ExecutionService(
    core,
    dependencies({
      executeAction: async () => {
        count++;
        throw new Error('network');
      },
    }),
  );
  await execution.init();
  const job = await execution.enqueue({
    appId: 'one',
    actionId: 'notify',
    maxAttempts: 3,
    retrySafe: true,
  });
  await eventually(() => job.status === 'failed');
  assert.equal(count, 1);
  assert.equal(job.maxAttempts, 1);
  await execution.shutdown();
});
test('running cancellation signals the common action executor', async () => {
  const core = coreMock();
  let aborted = false;
  const execution = new ExecutionService(
    core,
    dependencies({
      executeAction: async (_a, _b, _c, signal) =>
        new Promise((resolve) =>
          signal.addEventListener('abort', () => {
            aborted = true;
            resolve(null);
          }),
        ),
    }),
  );
  await execution.init();
  const job = await execution.enqueue({ appId: 'one', actionId: 'query' });
  await eventually(() => job.status === 'running');
  await new Promise((r) => setTimeout(r, 5));
  await execution.cancel(job.id);
  assert.equal(aborted, true);
  assert.equal(job.status, 'cancelled');
  await execution.shutdown();
});
test('daily schedule respects timezone and daylight saving transition', () => {
  const start = Date.parse('2026-03-07T15:00:00Z');
  assert.equal(
    new Date(nextDaily(start, { timezone: 'America/New_York', hour: 9, minute: 0 })).toISOString(),
    '2026-03-08T13:00:00.000Z',
  );
  assert.equal(
    new Date(
      nextDaily(Date.parse('2026-10-02T05:00:00Z'), {
        timezone: 'Europe/Moscow',
        hour: 9,
        minute: 0,
      }),
    ).toISOString(),
    '2026-10-02T06:00:00.000Z',
  );
});
test('permission revocation disables clipboard watcher before clipboard read', async () => {
  const core = coreMock();
  let reads = 0;
  const execution = new ExecutionService(
    core,
    dependencies({
      clipboardRead: async () => {
        reads++;
        return 'private';
      },
    }),
  );
  await execution.init();
  await execution.saveAutomation({
    appId: 'one',
    name: 'watch',
    trigger: 'clipboard',
    actionId: 'query',
    enabled: true,
  });
  core.permissions.splice(0);
  await execution.tick();
  assert.equal(reads, 0);
  assert.equal(execution.automations[0].enabled, false);
  await execution.shutdown();
});
test('agent creates local app through real tool loop and keeps key out of persisted state', async () => {
  const core = coreMock();
  let requests = 0,
    secret = '';
  const runtime = new RuntimeService(
    core,
    dependencies({
      writeSecret: async (_id, value) => {
        secret = value;
      },
      readSecret: async () => secret,
      fetch: async () =>
        ++requests === 1
          ? sse([
              {
                choices: [
                  {
                    delta: {
                      content: 'Создам приложение.',
                      tool_calls: [
                        {
                          index: 0,
                          id: 'create1',
                          function: {
                            name: 'app_create',
                            arguments: JSON.stringify({
                              name: 'Работа',
                              definition: {
                                schemaVersion: 1,
                                entities: [],
                                screens: [],
                                actions: [],
                                automations: [],
                                extensions: [],
                                permissions: [],
                              },
                            }),
                          },
                        },
                      ],
                    },
                  },
                ],
              },
            ])
          : sse([{ choices: [{ delta: { content: 'Готово' } }] }]),
    }),
  );
  await runtime.handle('provider.save', {
    type: 'openai',
    endpoint: 'https://example.test',
    model: 'm',
    apiKey: 'PRIVATE_TEST_KEY',
  });
  const run = await runtime.handle('agent.run', { message: 'Создай приложение' });
  await eventually(() => core.state['runtime.runs']?.[0]?.status === 'completed');
  const status = await runtime.handle('agent.status', { runId: run.id });
  assert.equal(status.appId, 'created');
  assert.equal(status.steps[0].status, 'completed');
  assert.ok(!JSON.stringify(core.state).includes('PRIVATE_TEST_KEY'));
  await runtime.shutdown();
});
test('destructive agent call waits for explicit approval and stays bound to current app', async () => {
  const core = coreMock();
  let requests = 0;
  const runtime = new RuntimeService(
    core,
    dependencies({
      fetch: async () =>
        ++requests === 1
          ? sse([
              {
                choices: [
                  {
                    delta: {
                      tool_calls: [
                        {
                          index: 0,
                          id: 'delete1',
                          function: {
                            name: 'records_delete',
                            arguments: '{"entityId":"e","id":"r","appId":"foreign"}',
                          },
                        },
                      ],
                    },
                  },
                ],
              },
            ])
          : sse([{ choices: [{ delta: { content: 'Отменено' } }] }]),
    }),
  );
  await runtime.handle('provider.save', {
    type: 'openai',
    endpoint: 'https://example.test',
    model: 'm',
  });
  const run = await runtime.handle('agent.run', { message: 'Удалить запись', appId: 'one' });
  await eventually(() => core.state['runtime.runs']?.[0]?.status === 'waiting_approval');
  const status = await runtime.handle('agent.status', { runId: run.id });
  assert.equal(status.approval.tool, 'records_delete');
  assert.equal(status.steps[0].status, 'waiting_approval');
  await runtime.handle('agent.approve', { runId: run.id, approved: false });
  assert.equal((await runtime.handle('agent.status', { runId: run.id })).status, 'cancelled');
  await runtime.shutdown();
});
test('definition automation sync installs paused rules, preserves local settings, and never revives disabled rules', async () => {
  const core = coreMock();
  core.apps.one.definition.automations = [
    {
      id: 'daily',
      name: 'Daily',
      trigger: 'interval',
      actionId: 'query',
      intervalMs: 60000,
      enabled: true,
    },
  ];
  const execution = new ExecutionService(core, dependencies());
  await execution.init();
  await execution.syncApp('one');
  assert.equal(execution.automations.length, 1);
  assert.equal(execution.automations[0].enabled, false);
  await execution.saveAutomation({ ...execution.automations[0], name: 'Local name' });
  await execution.syncApp('one');
  assert.equal(execution.automations[0].name, 'Local name');
  core.apps.one.definition.automations[0].intervalMs = 90000;
  await execution.syncApp('one');
  assert.equal(execution.automations.length, 1);
  assert.equal(execution.automations[0].enabled, false);
  assert.equal(execution.automations[0].name, 'Local name');
  await execution.shutdown();
});
test('missed interval policy skips late work and limits catch-up', async () => {
  const core = coreMock();
  const execution = new ExecutionService(core, dependencies());
  await execution.init();
  const skip = await execution.saveAutomation({
    appId: 'one',
    name: 'skip',
    trigger: 'interval',
    actionId: 'query',
    enabled: true,
    intervalMs: 1000,
    config: { missed: 'skip' },
  });
  const catchup = await execution.saveAutomation({
    appId: 'one',
    name: 'catchup',
    trigger: 'interval',
    actionId: 'query',
    enabled: true,
    intervalMs: 1000,
    config: { missed: 'catchup', catchupLimit: 2 },
  });
  const time = Date.now();
  skip.nextRunAt = time - 10000;
  catchup.nextRunAt = time - 10000;
  await execution.tick(time);
  assert.equal(skip.history.length, 0);
  assert.equal(catchup.history.length, 2);
  assert.ok(skip.nextRunAt > time);
  assert.ok(catchup.nextRunAt > time);
  await execution.shutdown();
});
test('automation conditions filter event input before dispatching action', async () => {
  const core = coreMock();
  const execution = new ExecutionService(core, dependencies());
  await execution.init();
  await execution.saveAutomation({
    appId: 'one',
    name: 'conditional',
    trigger: 'event',
    actionId: 'query',
    enabled: true,
    config: {
      event: 'media',
      conditions: [{ path: 'data.state', operator: 'eq', value: 'active' }],
    },
  });
  await execution.signal('media', { state: 'inactive' });
  assert.equal(execution.jobs.length, 0);
  await execution.signal('media', { state: 'active' });
  assert.equal(execution.jobs.length, 1);
  await execution.shutdown();
});
