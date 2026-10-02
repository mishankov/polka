import test from 'node:test';
import assert from 'node:assert/strict';
import { catalog, searchCapabilities } from '../src/runtime/catalog';
import { RuntimeService } from '../src/runtime/service';

function fixture(fetcher?: typeof fetch) {
  const state = new Map<string, any>();
  const calls: string[] = [];
  const runtime = new RuntimeService(
    {
      async handle(method: string, params: any = {}) {
        calls.push(method);
        if (method === 'state.get') return structuredClone(state.get(params.key));
        if (method === 'state.set') {
          state.set(params.key, structuredClone(params.value));
          return params.value;
        }
        throw Error(`Discovery must not need an app, permission grant, or native call: ${method}`);
      },
    },
    {
      fetch: fetcher,
      readSecret: async () => 'mock-only',
      writeSecret: async () => {},
      executeAction: async () => {
        throw Error('Discovery must not execute actions');
      },
    },
  );
  return { runtime, calls };
}

test('natural language camera, microphone, and overlay searches discover platform guidance', () => {
  for (const query of [
    'камера',
    'камеры и микрофона',
    'поверх всех окон',
    'camera microphone activity',
    'always on top',
    'overlay',
    'system.media',
  ]) {
    assert(
      searchCapabilities(query).some((capability) => capability.name === 'platform_capabilities'),
      `Missing native capability guidance for: ${query}`,
    );
  }
  assert.equal(searchCapabilities('not-a-real-capability-xyz').length, 0);
  assert.deepEqual(searchCapabilities(''), catalog);
});

test('platform guide is available before app creation and included in definition schema', async () => {
  const { runtime, calls } = fixture();
  try {
    const guide = await runtime.handle('runtime.platformCapabilities');
    const schema = await runtime.handle('runtime.definitionSchema');
    assert.deepEqual(schema.platformCapabilities, guide);
    assert(guide.windows.modes.includes('overlay'));
    assert.equal(guide.windows.open.via, 'app-menu');
    assert.equal(guide.windows.open.label, 'Панель поверх окон');
    assert.equal(guide.windows.allWorkspaces, true);
    assert.equal(guide.windows.visibleOnFullScreen, true);
    assert.equal(guide.media.method, 'system.media');
    assert.equal(guide.media.permission, 'system.media');
    assert.deepEqual(guide.media.states, ['active', 'inactive', 'unknown', 'unsupported']);
    assert(guide.windows.limitations.length > 0);
    assert(guide.media.limitations.length > 0);
    assert(guide.indicator);
    assert(calls.every((method) => method.startsWith('state.')));
  } finally {
    await runtime.shutdown();
  }
});

test('workspace assistant can discover native capabilities without creating an app or granting permissions', async () => {
  const requested = [
    { name: 'capabilities_search', input: { query: 'камера микрофон поверх окон' } },
    { name: 'platform_capabilities', input: {} },
    { name: 'definition_schema', input: {} },
  ];
  let round = 0;
  let guide: any;
  const { runtime, calls } = fixture(async (_url, init) => {
    const body = JSON.parse(String(init?.body));
    assert(body.tools.some((tool: any) => tool.function.name === 'platform_capabilities'));
    if (round > 0) {
      const result = JSON.parse(body.messages.at(-1).content);
      if (round === 1) {
        assert(result.some((entry: any) => entry.name === 'platform_capabilities'));
      } else if (round === 2) {
        guide = result;
        assert.equal(guide.media.method, 'system.media');
        assert.equal(guide.windows.open.via, 'app-menu');
      } else {
        assert.deepEqual(result.platformCapabilities, guide);
      }
    }
    const tool = requested[round++];
    const delta = tool
      ? {
          tool_calls: [
            {
              index: 0,
              id: `discovery-${round}`,
              function: { name: tool.name, arguments: JSON.stringify(tool.input) },
            },
          ],
        }
      : { content: 'Можно создать индикатор с учётом ограничений определения активности.' };
    return new Response(`data: ${JSON.stringify({ choices: [{ delta }] })}\n\ndata: [DONE]\n\n`, {
      headers: { 'content-type': 'text/event-stream' },
    });
  });
  try {
    await runtime.handle('provider.save', {
      type: 'openai',
      endpoint: 'https://mock.example/v1',
      model: 'mock',
    });
    const initial = await runtime.handle('agent.run', {
      message: 'Можно сделать индикатор камеры и микрофона поверх окон?',
    });
    let done: any;
    for (let i = 0; i < 200; i++) {
      done = await runtime.handle('agent.status', { runId: initial.id });
      if (done.status !== 'running') break;
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    assert.equal(done.status, 'completed', done.error);
    assert.equal(done.appId, undefined);
    assert.equal(round, 4);
    assert(done.steps.every((step: any) => step.status === 'completed'));
    assert(calls.every((method) => method.startsWith('state.')));
  } finally {
    await runtime.shutdown();
  }
});
