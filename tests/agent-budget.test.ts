import test from 'node:test';
import assert from 'node:assert/strict';
import { RuntimeService } from '../src/runtime/service';

const provider = { type: 'openai', endpoint: 'https://mock.example/v1', model: 'mock' };
const definition = {
  schemaVersion: 1,
  name: 'Created app',
  entities: [],
  screens: [],
  actions: [],
  automations: [],
  extensions: [],
  permissions: [],
};
function response(delta: Record<string, unknown>, inputTokens = 20, outputTokens = 10) {
  return new Response(
    `data: ${JSON.stringify({ choices: [{ delta }] })}\n\n` +
      `data: ${JSON.stringify({ usage: { prompt_tokens: inputTokens, completion_tokens: outputTokens } })}\n\n` +
      'data: [DONE]\n\n',
    { headers: { 'content-type': 'text/event-stream' } },
  );
}
function call(name: string, id: string, input: Record<string, unknown> = {}) {
  return {
    tool_calls: [{ index: 0, id, function: { name, arguments: JSON.stringify(input) } }],
  };
}
function fixture(fetcher: typeof fetch) {
  const state = new Map<string, any>();
  const apps = new Map<string, any>([
    ['other', { id: 'other', name: 'Other app', status: 'running', definition }],
  ]);
  const effects: string[] = [];
  const core = {
    async handle(method: string, p: any = {}) {
      switch (method) {
        case 'state.get':
          return structuredClone(state.get(p.key));
        case 'state.set':
          state.set(p.key, structuredClone(p.value));
          return p.value;
        case 'apps.list':
          return [...apps.values()];
        case 'apps.get':
          assert(apps.has(p.appId), `Unknown app ${p.appId}`);
          return structuredClone(apps.get(p.appId));
        case 'apps.create': {
          effects.push('create');
          const app = { ...p, id: 'created', status: 'running' };
          apps.set(app.id, app);
          return structuredClone(app);
        }
        case 'apps.updateMeta': {
          const app = { ...apps.get(p.appId), ...p };
          apps.set(p.appId, app);
          return structuredClone(app);
        }
        case 'permissions.list':
          return [];
        default:
          throw Error(`Unexpected core call: ${method}`);
      }
    },
  };
  const createRuntime = () =>
    new RuntimeService(core, {
      fetch: fetcher,
      readSecret: async () => 'mock-key',
      writeSecret: async () => {},
      executeAction: async () => {
        throw Error('Unexpected action');
      },
    });
  return { runtime: createRuntime(), createRuntime, state, apps, effects };
}
async function stopped(runtime: RuntimeService, id: string) {
  for (let i = 0; i < 200; i++) {
    const run = await runtime.handle('agent.status', { runId: id });
    if (!['running', 'waiting_approval'].includes(run.status)) return run;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail('Mock agent did not stop');
}
function assertCompleteToolPairs(messages: any[]) {
  const pending = new Set<string>();
  for (const message of messages) {
    if (message.role !== 'tool') assert.equal(pending.size, 0, 'Missing tool result');
    for (const tool of message.tool_calls || []) pending.add(tool.id);
    if (message.role === 'tool') {
      assert(pending.delete(message.tool_call_id), 'Orphan or duplicate tool result');
    }
  }
  assert.equal(pending.size, 0);
}

test('one app-creation message finishes after the reported 46,884 input and 5,012 output tokens', async () => {
  const rounds = [
    { delta: call('definition_schema', 'schema'), input: 8000, output: 1000 },
    { delta: call('capabilities_search', 'search'), input: 9000, output: 1000 },
    { delta: call('documents_list', 'documents'), input: 9000, output: 1000 },
    {
      delta: call('app_create', 'create', { name: definition.name, definition }),
      input: 10000,
      output: 1500,
    },
    { delta: call('app_inspect', 'inspect'), input: 10884, output: 512 },
    { delta: { content: 'Приложение готово.' }, input: 1000, output: 100 },
  ];
  let requests = 0;
  const { runtime, effects } = fixture(async (_url, init) => {
    const body = JSON.parse(String(init?.body));
    assertCompleteToolPairs(body.messages);
    assert.equal(
      body.tools.some((tool: any) => tool.function.name === 'documents_list'),
      requests >= 4,
      'App-scoped tools must only be offered after app creation',
    );
    const round = rounds[requests++];
    assert(round, 'Unexpected additional model request');
    return response(round.delta, round.input, round.output);
  });
  try {
    await runtime.handle('provider.save', provider);
    const initial = await runtime.handle('agent.run', { message: 'Создай приложение' });
    const done = await stopped(runtime, initial.id);
    assert.equal(done.status, 'completed', done.error);
    assert.equal(done.stopReason, undefined);
    assert.equal(done.messages.at(-1).content, 'Приложение готово.');
    assert.deepEqual(done.usage, { inputTokens: 47884, outputTokens: 5112 });
    assert.equal(done.steps[2].status, 'failed');
    assert.equal(done.steps[4].status, 'completed');
    assert.deepEqual(effects, ['create']);
    assert.equal(requests, 6);
  } finally {
    await runtime.shutdown();
  }
});

test('explicit token budget stops after saving effects and continuation inherits the created app and complete tool history', async () => {
  const requests: any[] = [];
  const { runtime, effects } = fixture(async (_url, init) => {
    const body = JSON.parse(String(init?.body));
    requests.push(body);
    assertCompleteToolPairs(body.messages);
    if (requests.length === 1)
      return response(
        call('app_create', 'create', { name: definition.name, definition }),
        900,
        100,
      );
    if (requests.length === 2) {
      assert.match(body.messages[0].content, /"appId":"created"/);
      assert(body.messages.some((m: any) => m.role === 'user' && m.content === 'Create once'));
      assert(body.messages.some((m: any) => m.role === 'tool' && m.tool_call_id === 'create'));
      assert.equal(body.messages.at(-1).content, 'Continue');
      return response(call('app_inspect', 'inspect'));
    }
    return response({ content: 'Existing app verified.' });
  });
  try {
    await runtime.handle('provider.save', provider);
    const first = await runtime.handle('agent.run', { message: 'Create once', maxTokens: 1000 });
    const limited = await stopped(runtime, first.id);
    assert.equal(limited.status, 'failed');
    assert.equal(limited.stopReason, 'token_budget');
    assert.equal(limited.appId, 'created');
    assert.equal(limited.steps[0].status, 'completed');
    assert.equal(requests.length, 1);
    const next = await runtime.handle('agent.run', {
      message: 'Continue',
      conversationId: first.conversationId,
    });
    const done = await stopped(runtime, next.id);
    assert.equal(done.status, 'completed', done.error);
    assert.equal(done.appId, 'created');
    assert.equal(done.steps[0].tool, 'app_inspect');
    assert.equal(done.steps[0].status, 'completed');
    assert.deepEqual(effects, ['create']);
    assert.equal(requests.length, 3);
  } finally {
    await runtime.shutdown();
  }
});

test('turn limit has a distinct stop reason and retains successful tool results', async () => {
  let requests = 0;
  const { runtime } = fixture(async () => {
    requests++;
    return response(call('capabilities_search', 'search'));
  });
  try {
    await runtime.handle('provider.save', provider);
    const first = await runtime.handle('agent.run', { message: 'Inspect tools', maxTurns: 1 });
    const limited = await stopped(runtime, first.id);
    assert.equal(limited.status, 'failed');
    assert.equal(limited.stopReason, 'turn_limit');
    assert.equal(limited.steps[0].status, 'completed');
    assert.equal(requests, 1);
  } finally {
    await runtime.shutdown();
  }
});

test('explicitly selecting a different app does not inherit the stopped app context or history', async () => {
  let requests = 0;
  const { runtime, effects } = fixture(async (_url, init) => {
    const body = JSON.parse(String(init?.body));
    if (++requests === 1)
      return response(
        call('app_create', 'create', { name: definition.name, definition }),
        900,
        100,
      );
    assertCompleteToolPairs(body.messages);
    assert.match(body.messages[0].content, /"appId":"other"/);
    assert.equal(body.messages.length, 2);
    assert.equal(body.messages.at(-1).content, 'Work in other app');
    return response({ content: 'Other app selected.' });
  });
  try {
    await runtime.handle('provider.save', provider);
    const first = await runtime.handle('agent.run', { message: 'Create once', maxTokens: 1000 });
    const limited = await stopped(runtime, first.id);
    assert.equal(limited.stopReason, 'token_budget');
    const next = await runtime.handle('agent.run', {
      message: 'Work in other app',
      conversationId: first.conversationId,
      appId: 'other',
    });
    const done = await stopped(runtime, next.id);
    assert.equal(done.status, 'completed', done.error);
    assert.equal(done.appId, 'other');
    assert.deepEqual(effects, ['create']);
  } finally {
    await runtime.shutdown();
  }
});

test('legacy persisted budget stops gain a continuation reason after restart', async () => {
  const { runtime, createRuntime, state } = fixture(async () =>
    response(call('app_create', 'create', { name: definition.name, definition }), 900, 100),
  );
  let restarted: RuntimeService | undefined;
  try {
    await runtime.handle('provider.save', provider);
    const first = await runtime.handle('agent.run', { message: 'Create once', maxTokens: 1000 });
    await stopped(runtime, first.id);
    await runtime.shutdown();
    const saved = state.get('runtime.runs');
    delete saved[0].stopReason;
    saved[0].error =
      'Достигнут бюджет агента. Результаты сохранены; можно продолжить новым сообщением';
    state.set('runtime.runs', saved);
    restarted = createRuntime();
    const history = await restarted.handle('agent.history');
    assert.equal(history[0].stopReason, 'token_budget');
    assert.equal(history[0].appId, 'created');
    assert.equal(history[0].steps[0].status, 'completed');
  } finally {
    if (restarted) await restarted.shutdown();
    else await runtime.shutdown();
  }
});
