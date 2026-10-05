import { createHash, randomUUID } from 'node:crypto';
import { version } from '../../package.json';
/** Protocol adapters deliberately depend only on fetch; no provider SDK crosses the runtime boundary. */
export type ProviderConfig = { type: 'openai' | 'anthropic'; endpoint: string; model: string };
export type ToolSpec = { name: string; description: string; inputSchema: Record<string, unknown> };
export type ToolCall = { id: string; name: string; input: Record<string, unknown> };
export type ChatMessage = {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string;
  calls?: ToolCall[];
  callId?: string;
  /** Provider protocol metadata; never shown as the assistant's answer. */
  reasoningContent?: string;
};
export type Completion = {
  text: string;
  calls: ToolCall[];
  reasoningContent?: string;
  usage: { inputTokens: number; outputTokens: number };
};
export type ProviderProgressPhase = 'waiting' | 'thinking' | 'generating_action' | 'answering';
/** Safe completion metadata only; raw model arguments and private reasoning stay out of errors. */
export class ProviderCompletionError extends Error {
  constructor(
    readonly code: 'output_limit' | 'invalid_tool_arguments' | 'incomplete_response',
    message: string,
    readonly usage: Completion['usage'],
  ) {
    super(message);
    this.name = 'ProviderCompletionError';
  }
}
export type Fetcher = typeof fetch;
export const DEFAULT_ENDPOINTS = {
  openai: 'https://api.openai.com/v1',
  anthropic: 'https://api.anthropic.com/v1',
};
export function validateProvider(value: unknown): ProviderConfig {
  const p = value as ProviderConfig;
  if (
    !p ||
    !['openai', 'anthropic'].includes(p.type) ||
    typeof p.model !== 'string' ||
    p.model.length > 200
  )
    throw new Error('Некорректная конфигурация провайдера');
  const endpoint = (p.endpoint || DEFAULT_ENDPOINTS[p.type]).replace(/\/+$/, '');
  const url = new URL(endpoint);
  if (
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    (url.protocol !== 'https:' &&
      !(url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)))
  )
    throw new Error('Endpoint требует HTTPS (HTTP разрешён только для локального сервера)');
  return { type: p.type, endpoint, model: p.model };
}
function headers(
  config: ProviderConfig,
  secret: string,
  sessionId: string = randomUUID(),
): Record<string, string> {
  const result: Record<string, string> =
    config.type === 'anthropic'
      ? {
          'content-type': 'application/json',
          'x-api-key': secret,
          'anthropic-version': '2023-06-01',
        }
      : { 'content-type': 'application/json', authorization: `Bearer ${secret}` };
  result['user-agent'] = `polka/${version}`;
  // Go routes coding-agent conversations by this header. Do not expose local IDs or
  // send provider-specific routing metadata to unrelated endpoints.
  if (new URL(config.endpoint).hostname === 'opencode.ai')
    result['x-opencode-session'] = createHash('sha256').update(sessionId).digest('hex');
  return result;
}
function requestHint(error: any): string | undefined {
  const details = error?.error || error;
  const type = details?.type || details?.code;
  const message = typeof details?.message === 'string' ? details.message : '';
  if (type === 'MissingSessionID' || /missing x-opencode-session/i.test(message))
    return 'OpenCode Go требует идентификатор разговора. Обновите приложение и повторите запрос.';
  if (/reasoning_content/i.test(message))
    return 'Провайдеру не хватает служебного контекста предыдущего ответа. Начните новый разговор в обновлённом приложении.';
  if (['model_not_found', 'invalid_model'].includes(type))
    return 'Модель недоступна. Получите список моделей в настройках и выберите доступную модель.';
  const parameter = details?.param;
  if (
    ['max_tokens', 'max_completion_tokens', 'tool_choice', 'tools', 'stream_options'].includes(
      parameter,
    )
  )
    return `Провайдер не принял параметр ${parameter}. Проверьте совместимость выбранной модели с API.`;
}
async function errorHint(response: Response): Promise<string | undefined> {
  const reader = response.body?.getReader();
  if (!reader) return;
  let size = 0;
  const chunks: Uint8Array[] = [];
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 8192) return;
      chunks.push(value);
    }
    return requestHint(JSON.parse(Buffer.concat(chunks).toString('utf8')));
  } catch {
    return;
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
async function checked(response: Response): Promise<Response> {
  if (response.ok) return response;
  if ([400, 404, 422].includes(response.status)) {
    const hint = await errorHint(response);
    if (hint) throw new Error(`Ошибка провайдера HTTP ${response.status}. ${hint}`);
  }
  await response.body?.cancel();
  if ([401, 403].includes(response.status))
    throw new Error('Провайдер отклонил ключ или доступ к модели');
  if (response.status === 429) throw new Error('Достигнут лимит провайдера. Повторите позже');
  throw new Error(`Ошибка провайдера HTTP ${response.status}. Проверьте endpoint и модель`);
}
/** Bounded streaming parser handles arbitrary byte and CRLF boundaries. */
export async function* readSSE(response: Response, signal: AbortSignal): AsyncGenerator<any> {
  if (!response.body) throw new Error('Провайдер вернул пустой поток');
  const reader = response.body.getReader(),
    decoder = new TextDecoder();
  const cancelOnAbort = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener('abort', cancelOnAbort, { once: true });
  let buffer = '',
    total = 0;
  try {
    while (true) {
      if (signal.aborted) throw new Error('Запрос отменён');
      const { value, done } = await reader.read();
      if (signal.aborted) throw new Error('Запрос отменён');
      if (done) {
        buffer += decoder.decode();
        if (buffer.trim()) buffer += '\n\n';
      } else {
        total += value.byteLength;
        if (total > 8 * 1024 * 1024) throw new Error('Ответ модели превысил лимит 8 МБ');
        buffer += decoder.decode(value, { stream: true });
      }
      buffer = buffer.replace(/\r\n/g, '\n');
      let boundary: number;
      while ((boundary = buffer.indexOf('\n\n')) >= 0) {
        const event = buffer.slice(0, boundary);
        buffer = buffer.slice(boundary + 2);
        const data = event
          .split('\n')
          .filter((line) => line.startsWith('data:'))
          .map((line) => line.slice(5).trimStart())
          .join('\n');
        if (data === '[DONE]') return;
        if (!data) continue;
        let parsed: any;
        try {
          parsed = JSON.parse(data);
        } catch {
          throw new Error('Некорректный поток ответа провайдера');
        }
        if (parsed.type === 'error' || parsed.error)
          throw new Error('Провайдер завершил поток с ошибкой');
        yield parsed;
      }
      if (done) break;
    }
  } finally {
    signal.removeEventListener('abort', cancelOnAbort);
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
export class ProviderAdapter {
  constructor(private readonly fetcher: Fetcher = fetch) {}
  async models(
    config: ProviderConfig,
    secret: string,
    signal: AbortSignal,
  ): Promise<{ id: string; name: string }[]> {
    const response = await checked(
      await this.fetcher(`${config.endpoint}/models`, { headers: headers(config, secret), signal }),
    );
    const json = (await response.json()) as any;
    if (!Array.isArray(json.data))
      throw new Error('Endpoint не поддерживает список моделей; введите идентификатор вручную');
    return json.data
      .slice(0, 2000)
      .filter((x: any) => typeof x.id === 'string')
      .map((x: any) => ({ id: x.id, name: x.display_name || x.id }));
  }
  async complete(
    config: ProviderConfig,
    secret: string,
    messages: ChatMessage[],
    tools: ToolSpec[],
    signal: AbortSignal,
    onText: (delta: string) => void = () => {},
    forceTool?: string,
    sessionId?: string,
    onProgress: (phase: ProviderProgressPhase) => void = () => {},
  ): Promise<Completion> {
    const endpoint = config.type === 'anthropic' ? '/messages' : '/chat/completions';
    let body: any;
    if (config.type === 'openai') {
      const deepSeek = /(?:^|\/)deepseek[-/]/i.test(config.model);
      body = {
        model: config.model,
        stream: true,
        stream_options: { include_usage: true },
        messages: messages.map((m) => ({
          role: m.role,
          content: m.content || (m.calls?.length && !deepSeek ? null : ''),
          ...(deepSeek && m.role === 'assistant' && m.reasoningContent !== undefined
            ? { reasoning_content: m.reasoningContent }
            : {}),
          ...(m.calls?.length
            ? {
                tool_calls: m.calls.map((c) => ({
                  id: c.id,
                  type: 'function',
                  function: { name: c.name, arguments: JSON.stringify(c.input) },
                })),
              }
            : {}),
          ...(m.callId ? { tool_call_id: m.callId } : {}),
        })),
        ...(deepSeek ? { max_tokens: 8192 } : { max_completion_tokens: 8192 }),
      };
      if (tools.length) {
        body.tools = tools.map((t) => ({
          type: 'function',
          function: { name: t.name, description: t.description, parameters: t.inputSchema },
        }));
        // DeepSeek thinking mode rejects forced/named tool choices. The explicit
        // probe prompt still verifies the returned call instead of assuming support.
        if (forceTool)
          body.tool_choice = deepSeek
            ? 'auto'
            : { type: 'function', function: { name: forceTool } };
      }
    } else {
      const converted: any[] = [];
      for (const m of messages.filter((m) => m.role !== 'system')) {
        const content: any[] =
          m.role === 'tool'
            ? [{ type: 'tool_result', tool_use_id: m.callId, content: m.content }]
            : [
                ...(m.content ? [{ type: 'text', text: m.content }] : []),
                ...(m.calls || []).map((c) => ({
                  type: 'tool_use',
                  id: c.id,
                  name: c.name,
                  input: c.input,
                })),
              ];
        const role = m.role === 'tool' ? 'user' : m.role;
        if (converted.at(-1)?.role === role) converted.at(-1).content.push(...content);
        else converted.push({ role, content });
      }
      body = {
        model: config.model,
        max_tokens: 8192,
        stream: true,
        system: messages
          .filter((m) => m.role === 'system')
          .map((m) => m.content)
          .join('\n'),
        messages: converted,
      };
      if (tools.length) {
        body.tools = tools.map((t) => ({
          name: t.name,
          description: t.description,
          input_schema: t.inputSchema,
        }));
        if (forceTool) body.tool_choice = { type: 'tool', name: forceTool };
      }
    }
    const response = await checked(
      await this.fetcher(config.endpoint + endpoint, {
        method: 'POST',
        headers: headers(config, secret, sessionId),
        body: JSON.stringify(body),
        signal,
      }),
    );
    onProgress('waiting');
    const result: Completion = { text: '', calls: [], usage: { inputTokens: 0, outputTokens: 0 } };
    let stopReason: string | undefined;
    const calls = new Map<number, { id: string; name: string; arguments: string; input?: any }>();
    for await (const chunk of readSSE(response, signal)) {
      if (config.type === 'openai') {
        const choice = chunk.choices?.[0];
        const delta = choice?.delta;
        if (typeof choice?.finish_reason === 'string') stopReason = choice.finish_reason;
        if (typeof delta?.reasoning_content === 'string') {
          result.reasoningContent = (result.reasoningContent || '') + delta.reasoning_content;
          if (delta.reasoning_content) onProgress('thinking');
        }
        if (typeof delta?.content === 'string') {
          result.text += delta.content;
          if (delta.content) onProgress('answering');
          onText(delta.content);
        }
        for (const c of delta?.tool_calls || []) {
          onProgress('generating_action');
          const call = calls.get(c.index) || { id: '', name: '', arguments: '' };
          call.id += c.id || '';
          call.name += c.function?.name || '';
          call.arguments += c.function?.arguments || '';
          calls.set(c.index, call);
        }
        if (chunk.usage) {
          result.usage.inputTokens = chunk.usage.prompt_tokens || 0;
          result.usage.outputTokens = chunk.usage.completion_tokens || 0;
        }
      } else {
        if (chunk.type === 'message_start')
          result.usage.inputTokens = chunk.message?.usage?.input_tokens || 0;
        if (chunk.type === 'message_delta') {
          result.usage.outputTokens = chunk.usage?.output_tokens || result.usage.outputTokens;
          if (typeof chunk.delta?.stop_reason === 'string') stopReason = chunk.delta.stop_reason;
        }
        if (chunk.type === 'content_block_start' && chunk.content_block?.type === 'tool_use') {
          onProgress('generating_action');
          calls.set(chunk.index, {
            id: chunk.content_block.id,
            name: chunk.content_block.name,
            arguments: '',
            input: chunk.content_block.input,
          });
        }
        if (chunk.type === 'content_block_delta') {
          if (chunk.delta?.type === 'text_delta') {
            result.text += chunk.delta.text;
            if (chunk.delta.text) onProgress('answering');
            onText(chunk.delta.text);
          }
          if (chunk.delta?.type === 'thinking_delta' || chunk.delta?.type === 'signature_delta')
            onProgress('thinking');
          if (chunk.delta?.type === 'input_json_delta') {
            onProgress('generating_action');
            const call = calls.get(chunk.index);
            if (call) call.arguments += chunk.delta.partial_json;
          }
        }
        if (chunk.type === 'message_stop') break;
      }
    }
    if (stopReason === 'length' || stopReason === 'max_tokens')
      throw new ProviderCompletionError(
        'output_limit',
        'Ответ модели не поместился в один запрос. Изменения из этого ответа не применены. Попробуйте выполнить задачу по частям.',
        { ...result.usage },
      );
    const completedReasons =
      config.type === 'openai' ? ['stop', 'tool_calls'] : ['end_turn', 'tool_use', 'stop_sequence'];
    if (stopReason && !completedReasons.includes(stopReason))
      throw new ProviderCompletionError(
        'incomplete_response',
        'Провайдер не завершил ответ. Изменения из этого ответа не применены. Попробуйте ещё раз.',
        { ...result.usage },
      );
    for (const call of calls.values()) {
      let input;
      try {
        input = call.arguments ? JSON.parse(call.arguments) : call.input || {};
      } catch {
        throw new ProviderCompletionError(
          'invalid_tool_arguments',
          'Модель вернула некорректные параметры инструмента',
          { ...result.usage },
        );
      }
      if (!input || Array.isArray(input) || typeof input !== 'object')
        throw new ProviderCompletionError(
          'invalid_tool_arguments',
          'Параметры инструмента должны быть объектом',
          { ...result.usage },
        );
      result.calls.push({ id: call.id, name: call.name, input });
    }
    return result;
  }
  async test(config: ProviderConfig, secret: string, signal: AbortSignal) {
    const result = await this.complete(
      config,
      secret,
      [
        {
          role: 'user',
          content:
            'Call connection_probe with ok=true. This is a connection and tool capability check.',
        },
      ],
      [
        {
          name: 'connection_probe',
          description: 'Connection verification',
          inputSchema: {
            type: 'object',
            properties: { ok: { type: 'boolean' } },
            required: ['ok'],
            additionalProperties: false,
          },
        },
      ],
      signal,
      () => {},
      'connection_probe',
    );
    const supported = result.calls.some(
      (c) => c.name === 'connection_probe' && c.input.ok === true,
    );
    return {
      ok: supported,
      tools: supported,
      structuredOutput: supported,
      message: supported
        ? 'Подключение и вызов инструментов работают'
        : 'Модель не выполнила проверочный вызов инструмента. Выберите модель с поддержкой инструментов',
      usage: result.usage,
    };
  }
}
