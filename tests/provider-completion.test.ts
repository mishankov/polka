import assert from 'node:assert/strict';
import test from 'node:test';
import {
  ProviderAdapter,
  ProviderCompletionError,
  type ProviderConfig,
  type ProviderProgressPhase,
} from '../src/runtime/providers';

const config: ProviderConfig = {
  type: 'openai',
  endpoint: 'https://provider.invalid/v1',
  model: 'mock',
};
function stream(events: unknown[], holdOpen = false) {
  let cancelled = false;
  const response = new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        for (const event of events)
          controller.enqueue(
            new TextEncoder().encode(
              `data: ${typeof event === 'string' ? event : JSON.stringify(event)}\n\n`,
            ),
          );
        if (!holdOpen) controller.close();
      },
      cancel() {
        cancelled = true;
      },
    }),
  );
  const adapter = new ProviderAdapter(async () => response);
  return { adapter, cancelled: () => cancelled };
}
const openAITool = (argumentsText: string) => ({
  choices: [
    {
      delta: {
        tool_calls: [
          { index: 0, id: 'call-1', function: { name: 'app_update', arguments: argumentsText } },
        ],
      },
    },
  ],
});
const usage = { prompt_tokens: 12, completion_tokens: 8192 };
function failure(code: ProviderCompletionError['code']) {
  return (error: unknown) => {
    assert.ok(error instanceof ProviderCompletionError);
    assert.equal(error.code, code);
    assert.deepEqual(error.usage, { inputTokens: 12, outputTokens: 8192 });
    assert.equal(error.message.includes('private-content'), false);
    return true;
  };
}

test('OpenAI token exhaustion rejects both malformed and valid partial tool arguments, preserving usage', async () => {
  for (const argumentsText of ['{"value":"private-content', '{"value":"private-content"}']) {
    const { adapter } = stream([
      openAITool(argumentsText),
      { choices: [{ delta: {}, finish_reason: 'length' }] },
      { choices: [], usage },
      '[DONE]',
    ]);
    await assert.rejects(
      adapter.complete(config, '', [], [], new AbortController().signal),
      failure('output_limit'),
    );
  }
});

test('Anthropic max_tokens rejects tools before parsing and preserves usage', async () => {
  for (const argumentsText of ['{"value":"private-content', '{"value":"private-content"}']) {
    const { adapter } = stream([
      { type: 'message_start', message: { usage: { input_tokens: 12 } } },
      {
        type: 'content_block_start',
        index: 0,
        content_block: { type: 'tool_use', id: 'call-1', name: 'app_update', input: {} },
      },
      {
        type: 'content_block_delta',
        index: 0,
        delta: { type: 'input_json_delta', partial_json: argumentsText },
      },
      {
        type: 'message_delta',
        delta: { stop_reason: 'max_tokens' },
        usage: { output_tokens: 8192 },
      },
      { type: 'message_stop' },
    ]);
    await assert.rejects(
      adapter.complete({ ...config, type: 'anthropic' }, '', [], [], new AbortController().signal),
      failure('output_limit'),
    );
  }
});

test('malformed and non-object tool arguments have a distinct typed failure', async () => {
  for (const argumentsText of ['{"private-content"', '[]', 'null', '"private-content"']) {
    const { adapter } = stream([
      openAITool(argumentsText),
      { choices: [{ finish_reason: 'tool_calls' }], usage },
      '[DONE]',
    ]);
    await assert.rejects(
      adapter.complete(config, '', [], [], new AbortController().signal),
      failure('invalid_tool_arguments'),
    );
  }
});

test('an explicit incomplete finish does not return valid tool calls', async () => {
  const { adapter } = stream([
    openAITool('{}'),
    { choices: [{ finish_reason: 'content_filter' }], usage },
    '[DONE]',
  ]);
  await assert.rejects(
    adapter.complete(config, '', [], [], new AbortController().signal),
    failure('incomplete_response'),
  );
});

test(
  'DONE terminates a still-open OpenAI transport and cancels the reader',
  { timeout: 2000 },
  async () => {
    const fixture = stream(
      [openAITool('{"ok":true}'), { choices: [{ finish_reason: 'tool_calls' }], usage }, '[DONE]'],
      true,
    );
    const result = await fixture.adapter.complete(config, '', [], [], new AbortController().signal);
    assert.deepEqual(result.calls, [{ id: 'call-1', name: 'app_update', input: { ok: true } }]);
    assert.equal(fixture.cancelled(), true);
  },
);

test('Anthropic message_stop terminates a still-open transport', { timeout: 2000 }, async () => {
  const fixture = stream(
    [
      { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Done' } },
      { type: 'message_delta', delta: { stop_reason: 'end_turn' } },
      { type: 'message_stop' },
    ],
    true,
  );
  const result = await fixture.adapter.complete(
    { ...config, type: 'anthropic' },
    '',
    [],
    [],
    new AbortController().signal,
  );
  assert.equal(result.text, 'Done');
  assert.equal(fixture.cancelled(), true);
});

test(
  'abort cancels an idle stream rather than accepting partial calls',
  { timeout: 2000 },
  async () => {
    const fixture = stream([openAITool('{}')], true);
    const controller = new AbortController();
    const completion = fixture.adapter.complete(config, '', [], [], controller.signal);
    setTimeout(() => controller.abort(), 10);
    await assert.rejects(completion, /отменён/);
    assert.equal(fixture.cancelled(), true);
  },
);

test('progress contains safe phases for every relevant chunk and supports legacy missing finish reasons', async () => {
  const fixture = stream([
    { choices: [{ delta: { reasoning_content: 'private-content' } }] },
    { choices: [{ delta: { reasoning_content: 'private-content' } }] },
    { choices: [{ delta: { content: 'Answer' } }] },
    openAITool('{}'),
    '[DONE]',
  ]);
  const phases: ProviderProgressPhase[] = [];
  const result = await fixture.adapter.complete(
    config,
    '',
    [],
    [],
    new AbortController().signal,
    () => {},
    undefined,
    undefined,
    (phase) => phases.push(phase),
  );
  assert.deepEqual(phases, ['waiting', 'thinking', 'thinking', 'answering', 'generating_action']);
  assert.equal(result.calls.length, 1);
});
