import test from 'node:test';
import assert from 'node:assert/strict';
import { RuntimeService } from '../src/runtime/service';

async function until(check: () => Promise<boolean> | boolean) {
  for (let i = 0; i < 300; i++) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail('Mock agent did not reach expected state');
}

test('provider progress is safe, failed-response usage is retained, explicit retry preserves completed tools', async () => {
  const state = new Map<string, any>();
  const requests: any[] = [];
  const streams: ReadableStreamDefaultController<Uint8Array>[] = [];
  const events: any[] = [];
  const send = (round: number, chunk: unknown) =>
    streams[round].enqueue(new TextEncoder().encode(`data: ${JSON.stringify(chunk)}\n\n`));
  const delta = (round: number, value: unknown) => send(round, { choices: [{ delta: value }] });
  const finish = (round: number) =>
    streams[round].enqueue(new TextEncoder().encode('data: [DONE]\n\n'));
  const runtime = new RuntimeService(
    {
      async handle(method: string, p: any = {}) {
        if (method === 'state.get') return structuredClone(state.get(p.key));
        if (method === 'state.set') {
          state.set(p.key, structuredClone(p.value));
          return p.value;
        }
        if (method === 'apps.list' || method === 'permissions.list') return [];
        throw Error(`Unexpected mutation or core request: ${method}`);
      },
    },
    {
      fetch: async (_url, init) => {
        requests.push(JSON.parse(String(init?.body)));
        return new Response(
          new ReadableStream({
            start: (controller) => {
              streams.push(controller);
            },
          }),
        );
      },
      readSecret: async () => 'mock-only',
      writeSecret: async () => {},
      executeAction: async () => {
        throw Error('Unexpected action');
      },
      emit: (type, value) => {
        if (type === 'agent.updated') events.push(structuredClone(value));
      },
    },
  );
  try {
    await runtime.handle('provider.save', {
      type: 'openai',
      endpoint: 'https://mock.example/v1',
      model: 'mock',
    });
    const run = await runtime.handle('agent.run', {
      message: 'Проверь возможности и обнови приложение',
    });
    const status = () => runtime.handle('agent.status', { runId: run.id });
    await until(() => streams.length === 1);
    assert.equal((await status()).progress.phase, 'waiting');
    delta(0, { reasoning_content: 'PRIVATE_REASONING_MUST_STAY_PRIVATE' });
    await until(async () => (await status()).progress.phase === 'thinking');
    delta(0, {
      tool_calls: [
        { index: 0, id: 'read-1', function: { name: 'platform_capabilities', arguments: '{}' } },
      ],
    });
    await until(async () => (await status()).progress.phase === 'preparing');
    send(0, { usage: { prompt_tokens: 100, completion_tokens: 10 } });
    finish(0);
    await until(() => streams.length === 2);
    assert.equal((await status()).steps[0].status, 'completed');
    delta(1, {
      tool_calls: [
        { index: 0, id: 'broken', function: { name: 'app_create', arguments: '{"definition":' } },
      ],
    });
    await until(async () => (await status()).progress.phase === 'preparing');
    const before = (await status()).progress.lastActivityAt;
    await new Promise((resolve) => setTimeout(resolve, 10));
    delta(1, { tool_calls: [{ index: 0, function: { arguments: '{' } }] });
    await until(async () => (await status()).progress.lastActivityAt !== before);
    send(1, { usage: { prompt_tokens: 1000, completion_tokens: 8192 } });
    send(1, { choices: [{ delta: {}, finish_reason: 'length' }] });
    finish(1);
    await until(async () => (await status()).status === 'failed');
    const failed = await status();
    assert.equal(failed.failureReason, 'incomplete_response');
    assert.deepEqual(failed.usage, { inputTokens: 1100, outputTokens: 8202 });
    assert.equal(failed.steps.length, 1, 'incomplete tool never executes');
    assert.equal(JSON.stringify(events).includes('PRIVATE_REASONING_MUST_STAY_PRIVATE'), false);
    assert.equal(JSON.stringify(failed).includes('"id":"broken"'), false);

    const retry = await runtime.handle('agent.run', {
      message: 'Продолжи с сохранённых результатов',
      conversationId: run.conversationId,
    });
    await until(() => streams.length === 3);
    assert(
      requests[2].messages.some(
        (m: any) => m.role === 'user' && m.content === 'Проверь возможности и обнови приложение',
      ),
    );
    assert(requests[2].messages.some((m: any) => m.role === 'tool' && m.tool_call_id === 'read-1'));
    assert(
      !requests[2].messages.some((m: any) => m.tool_calls?.some((c: any) => c.id === 'broken')),
    );
    delta(2, { content: 'Готово' });
    finish(2);
    await until(
      async () =>
        (await runtime.handle('agent.status', { runId: retry.id })).status === 'completed',
    );
  } finally {
    for (const stream of streams) {
      try {
        stream.close();
      } catch {}
    }
    await runtime.shutdown();
  }
});
