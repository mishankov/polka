import { z } from 'zod';
/** Registration is trusted distribution code, never part of an .everyapp file. */
export interface TrustedAdapter {
  id: string;
  version: string;
  description: string;
  inputSchema: Record<string, unknown>;
  outputSchema: Record<string, unknown>;
  effects: string[];
  permissions: string[];
  scope: string;
  platforms: string[];
  errors: string[];
  retry: 'safe' | 'never';
  cancellation: boolean;
  progress: boolean;
  limits: Record<string, number>;
  examples: unknown[];
  execute: (appId: string, input: unknown, signal?: AbortSignal) => Promise<unknown>;
}
export class AdapterRegistry {
  private adapters = new Map<string, TrustedAdapter>();
  register(adapter: TrustedAdapter) {
    if (this.adapters.has(adapter.id)) throw Error(`Адаптер ${adapter.id} уже зарегистрирован`);
    this.adapters.set(adapter.id, Object.freeze({ ...adapter }));
  }
  has(id: string) {
    return this.adapters.has(id);
  }
  catalog() {
    return [...this.adapters.values()].map(({ execute: _execute, ...metadata }) => metadata);
  }
  async invoke(id: string, appId: string, input: unknown, signal?: AbortSignal) {
    const adapter = this.adapters.get(id);
    if (!adapter) throw Error('Неизвестный доверенный адаптер');
    signal?.throwIfAborted();
    return adapter.execute(appId, input, signal);
  }
}
const requestSchema = z
  .object({
    url: z.string().max(4096),
    method: z.enum(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE']).default('GET'),
    headers: z.record(z.string().max(100), z.string().max(4096)).default({}),
    body: z
      .string()
      .max(1024 * 1024)
      .optional(),
    json: z.unknown().optional(),
    responseType: z.enum(['text', 'json']).default('text'),
    connectionId: z
      .string()
      .regex(/^[a-zA-Z][a-zA-Z0-9_-]{0,99}$/)
      .optional(),
  })
  .strict();
export function createBuiltinAdapters(options: {
  ensurePermission: (appId: string, permission: string) => Promise<void>;
  readConnection?: (
    appId: string,
    connectionId: string,
    origin: string,
  ) => Promise<{ bearer: string }>;
  fetch?: typeof fetch;
}) {
  const registry = new AdapterRegistry(),
    calls = new Map<string, Set<AbortController>>();
  const request = async (appId: string, input: unknown, signal?: AbortSignal) => {
    const p = requestSchema.parse(input),
      url = new URL(p.url);
    if (url.protocol !== 'https:' || url.username || url.password)
      throw Error('Разрешён только HTTPS без пароля в URL');
    await options.ensurePermission(appId, `network:${url.origin}`);
    const headers = new Headers();
    for (const [name, value] of Object.entries(p.headers)) {
      if (
        /^(authorization|proxy-authorization|cookie|host|connection|content-length|origin|referer|sec-.*|proxy-.*)$/i.test(
          name,
        )
      )
        throw Error(`Заголовок ${name} управляется платформой`);
      headers.set(name, value);
    }
    if (p.connectionId) {
      if (!options.readConnection) throw Error('Подключения с ключом недоступны');
      const connection = await options.readConnection(appId, p.connectionId, url.origin);
      headers.set('authorization', `Bearer ${connection.bearer}`);
    }
    if (p.json !== undefined && p.body !== undefined) throw Error('Выберите body или json');
    let body = p.body;
    if (p.json !== undefined) {
      body = JSON.stringify(p.json);
      headers.set('content-type', 'application/json');
    }
    if (body && ['GET', 'HEAD'].includes(p.method))
      throw Error('GET и HEAD не принимают тело запроса');
    if (body && Buffer.byteLength(body) > 1024 * 1024) throw Error('Запрос превышает 1 МБ');
    await options.ensurePermission(appId, `network:${url.origin}`);
    if ((calls.get(appId)?.size || 0) >= 8)
      throw Error('Не более восьми сетевых запросов одновременно');
    const controller = new AbortController(),
      active = calls.get(appId) || new Set<AbortController>();
    active.add(controller);
    calls.set(appId, active);
    try {
      const response = await (options.fetch || fetch)(url, {
        method: p.method,
        headers,
        body,
        redirect: 'error',
        credentials: 'omit',
        signal: AbortSignal.any([
          controller.signal,
          AbortSignal.timeout(10000),
          ...(signal ? [signal] : []),
        ]),
      });
      const reader = response.body?.getReader(),
        chunks: Uint8Array[] = [];
      let size = 0;
      if (reader)
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.length;
          if (size > 2 * 1024 * 1024) {
            await reader.cancel();
            throw Error('Ответ превышает 2 МБ');
          }
          chunks.push(value);
        }
      await options.ensurePermission(appId, `network:${url.origin}`);
      signal?.throwIfAborted();
      controller.signal.throwIfAborted();
      const text = Buffer.concat(chunks).toString('utf8');
      return {
        status: response.status,
        ok: response.ok,
        contentType: response.headers.get('content-type'),
        body: p.responseType === 'json' && text ? JSON.parse(text) : text,
      };
    } finally {
      active.delete(controller);
      if (!active.size) calls.delete(appId);
    }
  };
  const metadata = {
    version: '1.0.0',
    inputSchema: z.toJSONSchema(requestSchema),
    outputSchema: {
      type: 'object',
      required: ['status', 'ok', 'body'],
      properties: {
        status: { type: 'number' },
        ok: { type: 'boolean' },
        contentType: { type: ['string', 'null'] },
        body: {},
      },
    },
    permissions: ['network:<exact HTTPS origin>'],
    scope: 'current-instance; exact-origin',
    platforms: ['darwin'],
    errors: ['VALIDATION', 'PERMISSION_DENIED', 'TIMEOUT', 'RESPONSE_LIMIT', 'NETWORK'],
    cancellation: true,
    progress: false,
    limits: { requestBytes: 1024 * 1024, responseBytes: 2 * 1024 * 1024, timeoutMs: 10000 },
  };
  registry.register({
    ...metadata,
    id: 'network.request',
    description:
      'Вызов JSON API или HTTPS webhook. Ключи только через подключение текущего приложения; редиректы запрещены.',
    effects: ['network-read', 'network-write'],
    retry: 'never',
    examples: [
      {
        url: 'https://api.example.com/items',
        method: 'POST',
        json: { title: 'Пример' },
        responseType: 'json',
      },
    ],
    execute: request,
  });
  registry.register({
    ...metadata,
    id: 'network.fetch',
    description: 'GET к разрешённому HTTPS origin; ответ до 2 МБ.',
    effects: ['network-read'],
    retry: 'safe',
    examples: [{ url: 'https://api.example.com/items' }],
    execute: (appId, input, signal) => {
      const p = requestSchema.parse(input);
      if (p.method !== 'GET') throw Error('network.fetch поддерживает только GET');
      return request(appId, p, signal);
    },
  });
  return {
    registry,
    abortApp(appId: string) {
      for (const call of calls.get(appId) || []) call.abort();
    },
  };
}

export const builtinAdapterCatalog = createBuiltinAdapters({
  ensurePermission: async () => {
    throw Error('Metadata only');
  },
}).registry.catalog();
