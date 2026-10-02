import test from 'node:test';
import assert from 'node:assert/strict';
import { RuntimeService } from '../src/runtime/service';

async function until(check: () => boolean | Promise<boolean>) {
  for (let i = 0; i < 400; i++) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail('Timed out waiting for the mock agent');
}

test('each streaming draft belongs only to the current provider response and commits atomically', async () => {
  const state = new Map<string, any>();
  const events: any[] = [];
  const streams: ReadableStreamDefaultController<Uint8Array>[] = [];
  const encoder = new TextEncoder();
  const send = (index: number, delta: Record<string, unknown>) =>
    streams[index].enqueue(encoder.encode(`data: ${JSON.stringify({ choices: [{ delta }] })}\n\n`));
  const finish = (index: number, tool?: string) => {
    if (tool)
      send(index, {
        tool_calls: [{ index: 0, id: `call-${index}`, function: { name: tool, arguments: '{}' } }],
      });
    streams[index].enqueue(encoder.encode('data: [DONE]\n\n'));
    streams[index].close();
  };
  const runtime = new RuntimeService(
    {
      async handle(method: string, p: any = {}) {
        if (method === 'state.get') return structuredClone(state.get(p.key));
        if (method === 'state.set') {
          state.set(p.key, structuredClone(p.value));
          return p.value;
        }
        if (method === 'apps.list' || method === 'permissions.list') return [];
        throw Error(`Unexpected core call: ${method}`);
      },
    },
    {
      fetch: async () =>
        new Response(
          new ReadableStream({
            start: (controller) => {
              streams.push(controller);
            },
          }),
          {
            headers: { 'content-type': 'text/event-stream' },
          },
        ),
      readSecret: async () => 'mock-only',
      writeSecret: async () => {},
      executeAction: async () => {
        throw Error('Unexpected side effect');
      },
      emit: (type, payload) => {
        if (type === 'agent.updated') events.push(structuredClone(payload));
      },
    },
  );
  try {
    await runtime.handle('provider.save', {
      type: 'openai',
      endpoint: 'https://mock.example/v1',
      model: 'mock',
    });
    const run = await runtime.handle('agent.run', { message: 'Check the platform' });
    const status = () => runtime.handle('agent.status', { runId: run.id });
    const repeated = 'Проверяю возможности.';
    for (let round = 0; round < 2; round++) {
      await until(() => streams.length === round + 1);
      assert.equal((await status()).streamingText, '');
      send(round, { content: repeated });
      await until(async () => (await status()).streamingText === repeated);
      const live = await status();
      assert.equal(live.messages.filter((m: any) => m.role === 'assistant').length, round);
      assert.equal(events.at(-1).streamingText, repeated);
      finish(round, round === 0 ? 'platform_capabilities' : 'definition_schema');
      await until(() => streams.length === round + 2);
      const committed = await status();
      assert.equal(committed.streamingText, '');
      assert.deepEqual(
        committed.messages.filter((m: any) => m.role === 'assistant').map((m: any) => m.content),
        Array(round + 1).fill(repeated),
      );
    }
    send(2, { content: 'Проверка ' });
    await until(async () => (await status()).streamingText === 'Проверка ');
    send(2, { content: 'завершена.' });
    await until(async () => (await status()).streamingText === 'Проверка завершена.');
    finish(2);
    await until(async () => (await status()).status === 'completed');
    const completed = await status();
    assert.equal(completed.streamingText, '');
    assert.equal(completed.output, `${repeated}\n${repeated}\nПроверка завершена.`);
    assert.deepEqual(
      completed.messages.filter((m: any) => m.role === 'assistant').map((m: any) => m.content),
      [repeated, repeated, 'Проверка завершена.'],
    );
    assert(events.some((event) => event.steps.some((step: any) => step.status === 'running')));
    for (const event of events) {
      const committedCount = event.messages.filter((m: any) => m.role === 'assistant').length;
      if (
        event.steps.some((step: any) => step.status === 'running') ||
        event.status === 'completed'
      )
        assert.equal(
          event.streamingText,
          '',
          'Committed messages must not remain in the live draft',
        );
      if (event.streamingText) {
        if (committedCount < 2) assert.equal(event.streamingText, repeated);
        else assert(['Проверка ', 'Проверка завершена.'].includes(event.streamingText));
      }
    }
  } finally {
    // Release any held mock response even when an assertion fails.
    for (const stream of streams) {
      try {
        stream.close();
      } catch {
        /* Already closed. */
      }
    }
    await runtime.shutdown();
  }
});
