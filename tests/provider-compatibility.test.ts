import test from 'node:test';
import assert from 'node:assert/strict';
import { ProviderAdapter, type ChatMessage, type ProviderConfig } from '../src/runtime/providers';
import { RuntimeService } from '../src/runtime/service';

const openCode: ProviderConfig = {
  type: 'openai',
  endpoint: 'https://opencode.ai/zen/v1',
  model: 'deepseek-v3.2',
};
const signal = () => AbortSignal.timeout(5000);
function sse(deltas: any[]) {
  const bytes = new TextEncoder().encode(
    deltas.map((delta) => `data: ${JSON.stringify({ choices: [{ delta }] })}\r\n\r\n`).join('') +
      'data: [DONE]\r\n\r\n',
  );
  return new Response(
    new ReadableStream({
      start(controller) {
        for (let i = 0; i < bytes.length; i += 13) controller.enqueue(bytes.slice(i, i + 13));
        controller.close();
      },
    }),
    { headers: { 'content-type': 'text/event-stream' } },
  );
}
function tool(name = 'capabilities_search', id = 'lookup') {
  return {
    tool_calls: [
      {
        index: 0,
        id,
        function: {
          name,
          arguments: JSON.stringify(
            name === 'connection_probe' ? { ok: true } : { query: 'records' },
          ),
        },
      },
    ],
  };
}
function strictHeaders(init?: RequestInit) {
  const headers = new Headers(init?.headers),
    ua = headers.get('user-agent'),
    session = headers.get('x-opencode-session');
  return !!ua && /everything/i.test(ua) && !!session;
}
function fixture(fetcher: typeof fetch) {
  const state = new Map<string, any>(),
    events: any[] = [];
  let secret = '';
  const core = {
    handle: async (method: string, p: any = {}) => {
      if (method === 'state.get') return structuredClone(state.get(p.key));
      if (method === 'state.set') {
        state.set(p.key, structuredClone(p.value));
        return p.value;
      }
      if (method === 'apps.list') return [];
      if (method === 'permissions.list') return [];
      throw Error(`Unexpected mock core call: ${method}`);
    },
  };
  const runtime = new RuntimeService(core, {
    fetch: fetcher,
    readSecret: async () => secret,
    writeSecret: async (_id, value) => {
      secret = value;
    },
    executeAction: async () => {
      throw Error('Unexpected side effect');
    },
    emit: (type, payload) => events.push(structuredClone({ type, payload })),
  });
  return { runtime, state, events };
}
async function waitForRun(runtime: RuntimeService, runId: string) {
  for (let i = 0; i < 200; i++) {
    const run = await runtime.handle('agent.status', { runId });
    if (run.status === 'completed') return run;
    if (['failed', 'cancelled', 'waiting_approval'].includes(run.status))
      assert.fail(
        `Agent ${run.status}: ${run.error || run.approval?.description || 'unexpected stop'}`,
      );
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail('Agent did not complete');
}

test('strict OpenCode models and connection probe accept authentic UA and generated session', async () => {
  const received: { url: string; headers: Headers }[] = [];
  const strictFetch: typeof fetch = async (url, init) => {
    if (!strictHeaders(init))
      return new Response('Missing required OpenCode headers', { status: 400 });
    received.push({ url: String(url), headers: new Headers(init?.headers) });
    return String(url).endsWith('/models')
      ? Response.json({ data: [{ id: 'deepseek-v3.2' }] })
      : sse([tool('connection_probe')]);
  };
  // The mock reproduces the original server-side 400 instead of accepting any request.
  assert.equal(
    (
      await strictFetch(openCode.endpoint + '/models', {
        headers: { authorization: 'Bearer mock' },
      })
    ).status,
    400,
  );
  const adapter = new ProviderAdapter(strictFetch);
  assert.deepEqual(await adapter.models(openCode, 'mock-key', signal()), [
    { id: 'deepseek-v3.2', name: 'deepseek-v3.2' },
  ]);
  assert.equal((await adapter.test(openCode, 'mock-key', signal())).ok, true);
  assert.equal(received.length, 2);
  assert.notEqual(
    received[0].headers.get('x-opencode-session'),
    received[1].headers.get('x-opencode-session'),
  );
  for (const request of received) {
    assert.match(request.headers.get('user-agent')!, /everything/i);
    assert(request.headers.get('x-opencode-session'));
    assert.equal(request.headers.get('authorization'), 'Bearer mock-key');
  }
});

test('OpenCode session is stable across tool requests and follow-up user messages but distinct across chats', async () => {
  const sessions: string[] = [];
  let requests = 0;
  const { runtime } = fixture(async (_url, init) => {
    if (!strictHeaders(init)) return new Response('Missing header', { status: 400 });
    sessions.push(new Headers(init?.headers).get('x-opencode-session')!);
    return ++requests === 1 ? sse([tool()]) : sse([{ content: 'Done' }]);
  });
  try {
    await runtime.handle('provider.save', { ...openCode, apiKey: 'mock-key' });
    const first = await runtime.handle('agent.run', { message: 'Inspect available capabilities' });
    await waitForRun(runtime, first.id);
    const next = await runtime.handle('agent.run', {
      message: 'Continue this chat',
      conversationId: first.conversationId,
    });
    await waitForRun(runtime, next.id);
    const independent = await runtime.handle('agent.run', { message: 'A separate chat' });
    await waitForRun(runtime, independent.id);
    assert.equal(requests, 4);
    assert.equal(sessions[0], sessions[1]);
    assert.equal(sessions[0], sessions[2]);
    assert.notEqual(sessions[0], sessions[3]);
    assert.notEqual(sessions[0], first.conversationId);
    assert(sessions[0].length >= 16);
  } finally {
    await runtime.shutdown();
  }
});

test('OpenCode-specific session header is never sent to unrelated or lookalike hosts', async () => {
  for (const endpoint of [
    'https://api.openai.com/v1',
    'https://api.deepseek.com/v1',
    'https://opencode.ai.attacker.test/v1',
    'https://evilopencode.ai/v1',
  ]) {
    const adapter = new ProviderAdapter(async (_url, init) => {
      const headers = new Headers(init?.headers);
      assert.equal(headers.has('x-opencode-session'), false);
      assert.match(headers.get('user-agent')!, /everything/i);
      return sse([{ content: 'Done' }]);
    });
    await adapter.complete(
      { ...openCode, endpoint },
      'mock-key',
      [{ role: 'user', content: 'Hi' }],
      [],
      signal(),
      () => {},
      undefined,
      'private-conversation-id',
    );
  }
});

test('DeepSeek streams private reasoning separately and replays it with tool calls using max_tokens', async () => {
  const bodies: any[] = [];
  const visible: string[] = [];
  const adapter = new ProviderAdapter(async (_url, init) => {
    const body = JSON.parse(String(init?.body));
    bodies.push(body);
    if (!('max_tokens' in body) || 'max_completion_tokens' in body)
      return new Response('Unsupported token parameter', { status: 400 });
    return bodies.length === 1
      ? sse([
          { reasoning_content: 'PRIVATE_REASONING_' },
          { reasoning_content: 'TAIL', ...tool() },
          { content: 'Visible explanation' },
        ])
      : sse([{ content: 'Done' }]);
  });
  const first = await adapter.complete(
    openCode,
    'mock-key',
    [{ role: 'user', content: 'Find tools' }],
    [],
    signal(),
    (delta) => visible.push(delta),
    undefined,
    'same-chat',
  );
  assert.equal(first.reasoningContent, 'PRIVATE_REASONING_TAIL');
  assert.equal(first.text, 'Visible explanation');
  assert.deepEqual(visible, ['Visible explanation']);
  assert.equal(first.calls[0].name, 'capabilities_search');
  const continuation: ChatMessage[] = [
    { role: 'user', content: 'Find tools' },
    {
      role: 'assistant',
      content: first.text,
      calls: first.calls,
      reasoningContent: first.reasoningContent,
    },
    { role: 'tool', content: '[]', callId: first.calls[0].id },
  ];
  await adapter.complete(
    openCode,
    'mock-key',
    continuation,
    [],
    signal(),
    () => {},
    undefined,
    'same-chat',
  );
  const assistant = bodies[1].messages.find((message: any) => message.role === 'assistant');
  assert.equal(assistant.reasoning_content, 'PRIVATE_REASONING_TAIL');
  assert.equal(assistant.tool_calls[0].id, first.calls[0].id);
  assert.equal(bodies[1].messages.at(-1).tool_call_id, first.calls[0].id);
  assert.equal(bodies[0].max_tokens, 8192);
  assert.equal('max_completion_tokens' in bodies[1], false);
});

test('runtime retains DeepSeek reasoning for tool loops and later user turns while keeping public history/events clean', async () => {
  const bodies: any[] = [];
  const { runtime, state, events } = fixture(async (_url, init) => {
    const body = JSON.parse(String(init?.body));
    bodies.push(body);
    if (!strictHeaders(init) || !('max_tokens' in body) || 'max_completion_tokens' in body)
      return new Response('Incompatible request', { status: 400 });
    if (bodies.length === 1)
      return sse([{ reasoning_content: 'PRIVATE_TOOL_REASONING', ...tool() }]);
    if (bodies.length === 2) {
      const assistant = body.messages.find((message: any) => message.tool_calls?.length);
      assert.equal(assistant.reasoning_content, 'PRIVATE_TOOL_REASONING');
      return sse([{ reasoning_content: 'PRIVATE_FINAL_REASONING' }, { content: 'Finished' }]);
    }
    const retained = body.messages.find(
      (message: any) => message.role === 'assistant' && message.content === 'Finished',
    );
    assert.equal(retained?.reasoning_content, 'PRIVATE_FINAL_REASONING');
    return sse([
      { reasoning_content: 'PRIVATE_FOLLOWUP_REASONING' },
      { content: 'Follow-up finished' },
    ]);
  });
  try {
    await runtime.handle('provider.save', { ...openCode, apiKey: 'mock-key' });
    const first = await runtime.handle('agent.run', { message: 'Use available tools' });
    const firstDone = await waitForRun(runtime, first.id);
    assert.equal(firstDone.steps[0].status, 'completed');
    const next = await runtime.handle('agent.run', {
      message: 'Continue',
      conversationId: first.conversationId,
    });
    const nextDone = await waitForRun(runtime, next.id);
    assert.equal(bodies.length, 3);
    assert.equal(nextDone.output, 'Follow-up finished');
    const persisted = state.get('runtime.runs');
    assert(JSON.stringify(persisted).includes('PRIVATE_TOOL_REASONING'));
    assert(JSON.stringify(persisted).includes('PRIVATE_FINAL_REASONING'));
    const publicHistory = await runtime.handle('agent.history');
    for (const output of [first, firstDone, next, nextDone, publicHistory, events]) {
      assert.equal(JSON.stringify(output).includes('PRIVATE_'), false);
      assert.equal(JSON.stringify(output).includes('reasoningContent'), false);
      assert.equal(JSON.stringify(output).includes('reasoning_content'), false);
    }
  } finally {
    await runtime.shutdown();
  }
});

test('MissingSessionID diagnostics are actionable fixed text and never echo provider payloads', async () => {
  const privateText = 'PRIVATE_SERVER_PAYLOAD sk-mock-secret';
  const bodies = [
    { type: 'MissingSessionID', message: privateText },
    { error: { type: 'MissingSessionID', message: privateText } },
    { error: { code: 'MissingSessionID', message: privateText } },
    { error: { message: `Missing x-opencode-session: ${privateText}` } },
  ];
  for (const body of bodies) {
    const adapter = new ProviderAdapter(async () => Response.json(body, { status: 400 }));
    await assert.rejects(adapter.models(openCode, 'mock-key', signal()), (error) => {
      assert(error instanceof Error);
      assert.match(error.message, /HTTP 400/);
      assert.match(error.message, /OpenCode Go требует идентификатор разговора/);
      assert.match(error.message, /Обновите приложение/);
      assert.equal(error.message.includes(privateText), false);
      return true;
    });
  }
});

test('arbitrary HTTP400 response bodies and unrecognized parameter names are not exposed', async () => {
  const secret = 'PRIVATE_UNTRUSTED_BODY sk-mock-secret';
  for (const body of [
    secret,
    JSON.stringify({ error: { message: secret } }),
    JSON.stringify({ error: { param: secret, message: 'invalid request' } }),
  ]) {
    const adapter = new ProviderAdapter(async () => new Response(body, { status: 400 }));
    await assert.rejects(adapter.models(openCode, 'mock-key', signal()), (error) => {
      assert(error instanceof Error);
      assert.equal(error.message, 'Ошибка провайдера HTTP 400. Проверьте endpoint и модель');
      assert.equal(error.message.includes(secret), false);
      return true;
    });
  }
});

test('oversized provider error streams are cancelled at the 8KiB parsing budget', async () => {
  let pulls = 0,
    cancelled = false;
  const stream = new ReadableStream<Uint8Array>(
    {
      pull(controller) {
        pulls++;
        // Two chunks fit exactly; the next byte crosses the limit. Never finish the body.
        controller.enqueue(new TextEncoder().encode(pulls <= 2 ? ' '.repeat(4096) : '{'));
      },
      cancel() {
        cancelled = true;
      },
    },
    { highWaterMark: 0 },
  );
  const adapter = new ProviderAdapter(async () => new Response(stream, { status: 400 }));
  await assert.rejects(adapter.models(openCode, 'mock-key', signal()), /HTTP 400/);
  assert.equal(pulls, 3);
  assert.equal(cancelled, true);
});

test('DeepSeek connection probes use auto tools and assistant tool-call content is an empty string rather than null', async () => {
  let requests = 0;
  const adapter = new ProviderAdapter(async (_url, init) => {
    const body = JSON.parse(String(init?.body));
    requests++;
    if (requests === 1) {
      assert.equal(body.tool_choice, 'auto');
      assert.equal(body.tools[0].function.name, 'connection_probe');
      assert.equal(body.max_tokens, 8192);
      assert.equal('max_completion_tokens' in body, false);
      return sse([
        { reasoning_content: 'PRIVATE_PROBE_REASONING', ...tool('connection_probe', 'probe') },
      ]);
    }
    const assistant = body.messages.find((message: any) => message.role === 'assistant');
    assert.equal(assistant.content, '');
    assert.equal(assistant.reasoning_content, 'PRIVATE_TOOL_REASONING');
    assert.equal(assistant.tool_calls[0].id, 'lookup');
    return sse([{ content: 'Done' }]);
  });
  assert.equal((await adapter.test(openCode, 'mock-key', signal())).ok, true);
  await adapter.complete(
    openCode,
    'mock-key',
    [
      { role: 'user', content: 'Lookup' },
      {
        role: 'assistant',
        content: '',
        reasoningContent: 'PRIVATE_TOOL_REASONING',
        calls: [{ id: 'lookup', name: 'capabilities_search', input: { query: 'records' } }],
      },
      { role: 'tool', callId: 'lookup', content: '[]' },
    ],
    [],
    signal(),
  );
});
