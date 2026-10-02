import { z } from 'zod';
import { definitionSchema } from '../core/schema';
import { transforms } from '../services/transforms';
import { extensionDependencies } from '../extensions/dependencies';
import { builtinAdapterCatalog } from '../extensions/adapters';
import { randomUUID } from 'node:crypto';
import { ExecutionService, type CoreLike, type RuntimeDependencies } from './execution';
import {
  ProviderAdapter,
  ProviderCompletionError,
  validateProvider,
  type ProviderConfig,
  type ChatMessage,
  type ToolCall,
} from './providers';
import { catalog, searchCapabilities, SYSTEM_PROMPT } from './catalog';
import { platformCapabilities } from './platformCapabilities';
export interface AgentRun {
  id: string;
  conversationId: string;
  appId?: string;
  status: 'running' | 'waiting_approval' | 'completed' | 'failed' | 'cancelled';
  messages: ChatMessage[];
  steps: {
    id: string;
    tool: string;
    status: 'running' | 'completed' | 'failed' | 'waiting_approval';
    input?: unknown;
    result?: unknown;
    error?: string;
  }[];
  output: string;
  /** Only the response currently arriving; committed responses live in messages. */
  streamingText?: string;
  error?: string;
  stopReason?: 'token_budget' | 'turn_limit';
  failureReason?: 'incomplete_response' | 'invalid_tool_arguments' | 'timeout';
  progress?: {
    phase: 'waiting' | 'thinking' | 'preparing' | 'answering' | 'tool';
    startedAt: string;
    lastActivityAt: string;
  };
  approval?: { tool: string; input: unknown; description: string };
  usage: { inputTokens: number; outputTokens: number };
  createdAt: string;
  updatedAt: string;
  pending: ToolCall[];
  inspected: boolean;
  draftIds: string[];
  turns: number;
  maxTurns: number;
  maxTokens: number;
  startedAt: number;
}
const stamp = () => new Date().toISOString();
const workspaceTools = new Set([
  'platform_capabilities',
  'capabilities_search',
  'definition_schema',
  'adapters_list',
  'app_create',
]);
const bounded = (value: unknown, max = 64000) => {
  const s = JSON.stringify(value);
  return s.length > max ? s.slice(0, max) + '… [данные сокращены]' : s;
};
export class RuntimeService {
  readonly execution: ExecutionService;
  private adapter: ProviderAdapter;
  private config?: ProviderConfig;
  private runs: AgentRun[] = [];
  private controllers = new Map<string, AbortController>();
  private activeLoops = new Set<Promise<void>>();
  private ready: Promise<void>;
  private closed = false;
  constructor(
    private core: CoreLike,
    private deps: RuntimeDependencies,
  ) {
    this.execution = new ExecutionService(core, deps);
    this.adapter = new ProviderAdapter(deps.fetch);
    this.ready = this.init();
  }
  private async init() {
    this.config = await this.core.handle('state.get', { key: 'runtime.provider' });
    this.runs = (await this.core.handle('state.get', { key: 'runtime.runs' })) || [];
    for (const run of this.runs) {
      if (
        run.status === 'failed' &&
        run.error === 'Модель вернула некорректные параметры инструмента'
      )
        run.failureReason ||= 'invalid_tool_arguments';
      if (run.status === 'failed' && run.error?.startsWith('Достигнут бюджет агента.'))
        run.stopReason ||= run.turns >= run.maxTurns ? 'turn_limit' : 'token_budget';
      if (run.status === 'running' || run.status === 'waiting_approval') {
        run.status = 'failed';
        run.error =
          'Сеанс прерван перезапуском. Завершённые изменения сохранены; повторите запрос после проверки результатов';
        delete run.approval;
        run.updatedAt = stamp();
      }
    }
    await this.saveRuns();
    await this.execution.init();
  }
  private async saveRuns() {
    await this.core.handle('state.set', { key: 'runtime.runs', value: this.runs });
  }
  private async update(run: AgentRun) {
    run.updatedAt = stamp();
    await this.saveRuns();
    this.deps.emit?.('agent.updated', this.publicRun(run));
  }
  private async secret() {
    if (!this.config) throw new Error('Подключите AI-провайдера в настройках');
    return (
      (await this.deps.readSecret(`provider:${this.config.type}:${this.config.endpoint}`)) || ''
    );
  }
  async handle(method: string, p: any = {}): Promise<any> {
    await this.ready;
    if (this.closed) throw new Error('Платформа завершает работу');
    p = p || {};
    switch (method) {
      case 'provider.get':
      case 'agent.config':
        return this.config ? { ...this.config, hasKey: !!(await this.secret()) } : null;
      case 'provider.save': {
        const config = validateProvider(p);
        if (p.apiKey !== undefined) {
          if (typeof p.apiKey !== 'string' || p.apiKey.length > 20000)
            throw new Error('Некорректный API-ключ');
          await this.deps.writeSecret(`provider:${config.type}:${config.endpoint}`, p.apiKey);
        }
        this.config = config;
        await this.core.handle('state.set', { key: 'runtime.provider', value: config });
        return { ...config, hasKey: !!(await this.secret()) };
      }
      case 'provider.models': {
        const secret = await this.secret();
        return {
          models: await this.adapter.models(this.config!, secret, AbortSignal.timeout(30000)),
        };
      }
      case 'provider.test': {
        const secret = await this.secret();
        return this.adapter.test(this.config!, secret, AbortSignal.timeout(30000));
      }
      case 'capabilities.list':
        return catalog;
      case 'runtime.definitionSchema':
        return this.definitionSchema();
      case 'runtime.platformCapabilities':
        return platformCapabilities;
      case 'capabilities.search':
        return searchCapabilities(p.query || '');
      case 'agent.run':
        return this.run(p);
      case 'agent.history':
        return this.runs
          .filter((r) => !p.appId || r.appId === p.appId)
          .map((r) => this.publicRun(r));
      case 'agent.status':
        return this.publicRun(this.findRun(p.runId));
      case 'agent.cancel': {
        const run = this.findRun(p.runId);
        this.controllers.get(run.id)?.abort();
        if (['running', 'waiting_approval'].includes(run.status)) {
          run.status = 'cancelled';
          delete run.approval;
          await this.update(run);
        }
        return this.publicRun(run);
      }
      case 'agent.approve': {
        const run = this.findRun(p.runId);
        if (run.status !== 'waiting_approval' || !run.approval)
          throw new Error('Нет ожидающего подтверждения');
        if (!p.approved) {
          run.status = 'cancelled';
          delete run.approval;
          await this.update(run);
          return this.publicRun(run);
        }
        const approved = run.pending[0]?.id;
        run.status = 'running';
        delete run.approval;
        await this.update(run);
        this.startLoop(run, approved);
        return this.publicRun(run);
      }
      case 'jobs.enqueue':
        return this.execution.enqueue(p);
      case 'jobs.list':
        return this.execution.jobs.filter((j) => !p.appId || j.appId === p.appId);
      case 'jobs.cancel':
        return this.execution.cancel(p.jobId);
      case 'automations.list':
        return this.execution.automations.filter((a) => !p.appId || a.appId === p.appId);
      case 'automations.save':
        return this.execution.saveAutomation(p);
      case 'automations.delete':
        return this.execution.deleteAutomation(p.id);
      case 'automations.setEnabled':
        return this.execution.setEnabled(p);
      case 'runtime.stopApp':
        return this.execution.stopApp(p.appId);
      case 'runtime.syncApp':
        return this.execution.syncApp(p.appId);
      case 'runtime.signal':
        return this.execution.signal(p.event, p.data);
      default:
        throw new Error(`Неизвестная операция runtime: ${method}`);
    }
  }
  private publicRun(run: AgentRun) {
    const { pending, inspected, draftIds, startedAt, maxTokens, maxTurns, turns, ...publicRun } =
      run;
    return {
      ...publicRun,
      messages: publicRun.messages.map(({ reasoningContent: _reasoning, ...message }) => message),
    };
  }
  private findRun(id: string) {
    const run = this.runs.find((r) => r.id === id);
    if (!run) throw new Error('Сеанс агента не найден');
    return run;
  }
  private async run(p: any) {
    await this.secret();
    if (typeof p.message !== 'string' || !p.message.trim() || p.message.length > 32000)
      throw new Error('Введите запрос до 32 000 символов');
    if (this.runs.some((r) => r.status === 'running' || r.status === 'waiting_approval'))
      throw new Error('Дождитесь или отмените текущую работу агента');
    const conversationId = p.conversationId || randomUUID(),
      previous = this.runs
        .filter(
          (r) =>
            r.conversationId === conversationId &&
            (!p.appId || r.appId === p.appId) &&
            (r.status === 'completed' ||
              (r.status === 'failed' &&
                (r.stopReason ||
                  r.failureReason === 'incomplete_response' ||
                  r.failureReason === 'invalid_tool_arguments'))),
        )
        .at(-1);
    const appId = p.appId || previous?.appId;
    if (appId) await this.core.handle('apps.get', { appId });
    const messages: ChatMessage[] = [
      {
        role: 'system',
        content:
          SYSTEM_PROMPT +
          '\nКонтекст: ' +
          bounded(
            { appId: appId || null, pageId: p.pageId || null, selection: p.selection || null },
            8000,
          ),
      },
    ];
    if (previous) {
      const history = previous.messages.filter((m) => m.role !== 'system');
      // Keep recent complete user rounds, including assistant protocol metadata and
      // tool results. Cutting in the middle produces orphan tool messages or loses
      // reasoning_content required by DeepSeek on the next user turn.
      let start = Math.max(0, history.length - 48);
      while (start > 0 && history[start]?.role !== 'user') start--;
      messages.push(...history.slice(start));
    }
    messages.push({ role: 'user', content: p.message });
    const run: AgentRun = {
      id: randomUUID(),
      conversationId,
      appId,
      status: 'running',
      messages,
      steps: [],
      output: '',
      streamingText: '',
      usage: { inputTokens: 0, outputTokens: 0 },
      createdAt: stamp(),
      updatedAt: stamp(),
      pending: [],
      inspected: false,
      draftIds: [],
      turns: 0,
      maxTurns: Math.max(1, Math.min(24, p.maxTurns || 12)),
      // This is cumulative provider usage: tool schemas and conversation context
      // are billed again on every call, not just once per user message.
      maxTokens: Math.max(1000, Math.min(1000000, p.maxTokens || 250000)),
      startedAt: Date.now(),
    };
    this.runs.push(run);
    await this.update(run);
    this.startLoop(run);
    return this.publicRun(run);
  }
  private async approvalReason(run: AgentRun, call: ToolCall): Promise<string | undefined> {
    if (call.name === 'records_delete')
      return 'Удалить выбранную запись? Это изменит данные приложения.';
    if (call.name === 'app_create' || call.name === 'definition_prepare') {
      const definition = call.input.definition as any;
      const previous =
        call.name === 'definition_prepare' && run.appId
          ? (await this.core.handle('apps.get', { appId: run.appId })).definition
          : undefined;
      if (Array.isArray(definition?.permissions)) {
        const added = definition.permissions.filter(
          (p: string) => !previous?.permissions?.includes(p),
        );
        if (added.length)
          return `Приложению нужен доступ: ${added.map((permission: string) => (permission === 'system.media' ? 'активность камеры и микрофона' : permission)).join(', ')}. После создания разрешите нужный доступ в свойствах приложения.`;
      }
      if (
        Array.isArray(definition?.extensions) &&
        definition.extensions.some(
          (ext: any) =>
            !previous?.extensions?.some(
              (old: any) =>
                old.id === ext.id &&
                old.source === ext.source &&
                JSON.stringify(old.dependencies) === JSON.stringify(ext.dependencies),
            ),
        )
      )
        return 'Добавить или изменить программируемое расширение? Код будет выполняться в изолированной среде с ограниченными API.';
    }
    if (call.name === 'action_run') {
      const app = await this.core.handle('apps.get', { appId: run.appId });
      const action = app.definition.actions.find((a: any) => a.id === call.input.actionId);
      if (
        action &&
        !['transform', 'records.query', 'records.list', 'records.upsert'].includes(action.type)
      )
        return `Выполнить действие «${action.name}» (${action.type})? Оно может изменить данные или вызвать внешний эффект.`;
    }
    if (call.name === 'automation_save' && call.input.enabled)
      return 'Включить фоновую автоматизацию? Она будет выполнять выбранное действие, пока платформа запущена.';
    return undefined;
  }
  private async tool(run: AgentRun, call: ToolCall): Promise<any> {
    const spec = catalog.find((c) => c.name === call.name);
    if (!spec) throw new Error('Инструмент отсутствует в каталоге');
    validateToolInput(call.input, spec.inputSchema);
    if (call.name === 'capabilities_search')
      return searchCapabilities(String(call.input.query || ''));
    if (call.name === 'definition_schema') return this.definitionSchema();
    if (call.name === 'platform_capabilities') return platformCapabilities;
    if (call.name === 'adapters_list') return builtinAdapterCatalog;
    if (call.name === 'app_create') {
      const created = await this.core.handle('apps.create', call.input);
      const app = await this.core.handle('apps.updateMeta', {
        appId: created.id,
        status: 'running',
      });
      run.appId = app.id;
      run.inspected = true;
      return app;
    }
    if (!run.appId) throw new Error('Сначала создайте или откройте приложение');
    const params = { ...call.input, appId: run.appId };
    if (call.name === 'app_inspect') {
      const app = await this.core.handle('apps.get', params);
      run.inspected = true;
      return app;
    }
    if (['definition_prepare', 'definition_activate'].includes(call.name) && !run.inspected)
      throw new Error('Перед изменением прочитайте app_inspect');
    if (call.name === 'definition_prepare') {
      const result = await this.core.handle('definitions.prepare', params);
      run.draftIds.push(result.draftId);
      return result;
    }
    if (call.name === 'definition_activate' && !run.draftIds.includes(String(call.input.draftId)))
      throw new Error('Активация разрешена только для версии, подготовленной этим сеансом');
    if (call.name === 'documents_list') {
      const docs = await this.core.handle('docs.list', params);
      return docs.map(({ content, ...metadata }: any) => metadata);
    }
    if (call.name === 'action_run') return this.execution.enqueue(params);
    if (call.name === 'automation_save') return this.execution.saveAutomation(params);
    if (call.name === 'diagnostics_read')
      return this.execution.jobs.filter((j) => j.appId === run.appId).slice(-30);
    return this.core.handle(spec.rpc, params);
  }
  private definitionSchema() {
    return {
      platformCapabilities,
      definition: z.toJSONSchema(definitionSchema, { unrepresentable: 'any' }),
      transforms,
      actions: {
        transform: { operation: 'json.format', options: {} },
        pipeline: { steps: [{ operation: 'json.format' }] },
        extension: { extensionId: 'handlerId' },
        'records.upsert': { entityId: 'items', values: {} },
        'records.list': { entityId: 'items' },
        'clipboard.read': {},
        'clipboard.write': { text: 'Текст' },
        'notifications.show': { title: 'Готово', body: 'Задание завершено' },
        'system.media': {},
        'network.fetch': { url: 'https://example.org' },
        'network.request': {
          url: 'https://api.example.org/items',
          method: 'POST',
          json: { title: 'Пример' },
          responseType: 'json',
        },
      },
      sdk: {
        screenBinding: {
          screen: {
            id: 'canvas',
            name: 'Холст',
            type: 'custom',
            config: { extensionId: 'canvasScreen' },
          },
          extension: {
            id: 'canvasScreen',
            name: 'Холст',
            kind: 'component',
            source: 'export default function Screen({sdk}) { return <div>Холст</div>; }',
          },
          rule: 'Каждый custom-экран обязан ссылаться через config.extensionId на существующее расширение kind: component. Совпадение имён или entityId не связывает экран с кодом. Для action.type=extension нужен config.extensionId расширения kind: handler.',
        },
        records: {
          list: {
            method: 'records.list',
            params: { entityId: 'items' },
            result: {
              records: [{ id: 'record-id', entityId: 'items', values: { title: 'Название' } }],
              total: 1,
            },
          },
          readFields:
            'Поля записи находятся в record.values: например record.values.title, а не record.title. records.list возвращает {records,total}; records.upsert принимает {entityId,id?,values} и возвращает запись с id и values. Сохраняйте возвращённый id для повторного изменения.',
        },
        handler:
          'export default function(input) { return {value: input, operations: [{method: \"records.list\", params: {entityId: \"items\"}}]}; }',
        component:
          'export default function Screen({sdk}) { /* React; sdk.call(method, params) */ return <div>Приложение</div> }',
        permissions: [
          'clipboard.read',
          'clipboard.write',
          'notifications',
          'system.media',
          'background',
          'network:https://example.org',
        ],
        limits: { handlerMemoryMiB: 32, handlerTimeMs: 3000, handlerOperations: 32 },
        dependencies: extensionDependencies,
        components: [
          'EntityForm',
          'RecordTable',
          'RelatedRecordSelect',
          'Card',
          'ActionButton',
          'JobProgress',
          'HistoryList',
          'ErrorView',
          'Board',
          'CalendarView',
          'useSDK',
        ],
        libraries:
          'Импортируйте компоненты платформы из @everything/ui; Mantine из @mantine/core, хуки из @mantine/hooks, графики из recharts, схемы из zod. React/JSX встроены. Нужны точные версии зависимостей. Установка пакетов, Node.js, внешний код и прямая сеть недоступны.',
        componentExample: `import { RecordTable } from '@everything/ui'; export default function Screen() { return <RecordTable entity={{id:'items',name:'Записи',fields:[{id:'title',name:'Название',type:'text'}]}} />; }`,
        adapters: builtinAdapterCatalog,
      },
    };
  }
  private startLoop(run: AgentRun, approvedCall?: string) {
    const task = this.loop(run, approvedCall).finally(() => this.activeLoops.delete(task));
    this.activeLoops.add(task);
  }
  private async loop(run: AgentRun, approvedCall?: string) {
    const ctrl = new AbortController();
    this.controllers.set(run.id, ctrl);
    let timedOut = false;
    const timeout = setTimeout(() => {
      timedOut = true;
      ctrl.abort();
    }, 300000);
    let lastProgressEmit = 0;
    const progress = (phase: NonNullable<AgentRun['progress']>['phase']) => {
      if (run.status !== 'running' || ctrl.signal.aborted) return;
      const now = stamp();
      const changed = run.progress?.phase !== phase;
      run.progress = {
        phase,
        startedAt: changed ? now : run.progress!.startedAt,
        lastActivityAt: now,
      };
      if (changed || Date.now() - lastProgressEmit > 250) {
        this.deps.emit?.('agent.updated', this.publicRun(run));
        lastProgressEmit = Date.now();
      }
    };
    try {
      const config = { ...this.config! },
        secret = await this.secret();
      while (run.status === 'running' && !ctrl.signal.aborted) {
        while (run.pending.length) {
          if (ctrl.signal.aborted || run.status !== 'running') break;
          const call = run.pending[0];
          let step = run.steps.find((s) => s.id === call.id);
          if (!step) {
            if (run.steps.length >= 128) throw new Error('Достигнут лимит 128 действий за сеанс');
            step = { id: call.id, tool: call.name, input: call.input, status: 'running' };
            run.steps.push(step);
          }
          const reason =
            approvedCall === call.id ? undefined : await this.approvalReason(run, call);
          if (reason) {
            step.status = 'waiting_approval';
            run.status = 'waiting_approval';
            run.approval = { tool: call.name, input: call.input, description: reason };
            await this.update(run);
            return;
          }
          step.status = 'running';
          progress('tool');
          await this.update(run);
          try {
            const result = await this.tool(run, call);
            step.status = 'completed';
            step.result = JSON.parse(JSON.stringify(result ?? null));
            run.messages.push({ role: 'tool', callId: call.id, content: bounded(result ?? null) });
          } catch (e) {
            step.status = 'failed';
            step.error = (e as Error).message;
            run.messages.push({
              role: 'tool',
              callId: call.id,
              content: JSON.stringify({ error: step.error }),
            });
          }
          run.pending.shift();
          approvedCall = undefined;
          await this.update(run);
        }
        if (ctrl.signal.aborted || run.status !== 'running') break;
        if (run.turns >= run.maxTurns) {
          run.stopReason = 'turn_limit';
          throw new Error(
            `Достигнут лимит ${run.maxTurns} обращений к модели за запрос. Изменения сохранены; можно продолжить работу.`,
          );
        }
        if (run.usage.inputTokens + run.usage.outputTokens >= run.maxTokens) {
          run.stopReason = 'token_budget';
          throw new Error(
            `Достигнут лимит ${run.maxTokens.toLocaleString('ru-RU')} токенов за запрос, включая повторную передачу контекста. Изменения сохранены; можно продолжить работу.`,
          );
        }
        run.turns++;
        run.streamingText = '';
        progress('waiting');
        await this.update(run);
        let lastEmit = 0;
        const response = await this.adapter.complete(
          config,
          secret,
          run.messages,
          run.appId ? catalog : catalog.filter((tool) => workspaceTools.has(tool.name)),
          ctrl.signal,
          (delta) => {
            run.output += delta;
            run.streamingText = (run.streamingText || '') + delta;
            if (Date.now() - lastEmit > 100) {
              this.deps.emit?.('agent.updated', this.publicRun(run));
              lastEmit = Date.now();
            }
          },
          undefined,
          run.conversationId,
          (phase) => progress(phase === 'generating_action' ? 'preparing' : phase),
        );
        if (response.calls.length > 32)
          throw new Error('Модель запросила слишком много действий за один шаг (максимум 32)');
        run.usage.inputTokens += response.usage.inputTokens;
        run.usage.outputTokens += response.usage.outputTokens;
        run.messages.push({
          role: 'assistant',
          content: response.text,
          calls: response.calls.length ? response.calls : undefined,
          ...(response.reasoningContent !== undefined
            ? { reasoningContent: response.reasoningContent }
            : {}),
        });
        // Move the response from the live draft to the transcript as one state
        // change. Aggregate output includes earlier rounds and must not be used
        // as the draft, nor can text equality identify a committed message.
        run.streamingText = '';
        // Consuming the execution queue must not mutate the assistant's tool-call
        // history, which the provider needs when receiving the tool results.
        run.pending = [...response.calls];
        if (!response.calls.length) run.status = 'completed';
        else run.output += '\n';
        await this.update(run);
      }
      if (ctrl.signal.aborted && run.status === 'running') {
        run.status = timedOut ? 'failed' : 'cancelled';
        if (timedOut) run.failureReason = 'timeout';
        run.error = timedOut ? 'Запрос превысил 5 минут' : 'Сеанс отменён';
        await this.update(run);
      }
    } catch (e) {
      if (run.status !== 'cancelled') {
        run.status = ctrl.signal.aborted && !timedOut ? 'cancelled' : 'failed';
        if (timedOut) run.failureReason = 'timeout';
        if (e instanceof ProviderCompletionError) {
          run.failureReason =
            e.code === 'invalid_tool_arguments' ? 'invalid_tool_arguments' : 'incomplete_response';
          run.usage.inputTokens += e.usage.inputTokens;
          run.usage.outputTokens += e.usage.outputTokens;
        }
        run.error = timedOut
          ? 'Запрос превысил 5 минут'
          : ctrl.signal.aborted
            ? 'Сеанс отменён'
            : (e as Error).message;
        await this.update(run);
      }
    } finally {
      clearTimeout(timeout);
      this.controllers.delete(run.id);
    }
  }
  async shutdown() {
    await this.ready;
    this.closed = true;
    for (const ctrl of this.controllers.values()) ctrl.abort();
    await Promise.allSettled([...this.activeLoops]);
    await this.execution.shutdown();
    await this.saveRuns();
  }
}
export type { RuntimeDependencies } from './execution';

function validateToolInput(input: unknown, schema: Record<string, any>, path = 'input') {
  if (schema.type === 'object') {
    if (!input || typeof input !== 'object' || Array.isArray(input))
      throw new Error(`Параметр ${path} должен быть объектом`);
    const values = input as Record<string, unknown>;
    for (const required of schema.required || [])
      if (values[required] === undefined) throw new Error(`Не указан параметр ${path}.${required}`);
    if (schema.additionalProperties === false)
      for (const key of Object.keys(values))
        if (!schema.properties?.[key]) throw new Error(`Неизвестный параметр ${path}.${key}`);
    for (const [key, value] of Object.entries(values))
      if (schema.properties?.[key])
        validateToolInput(value, schema.properties[key], `${path}.${key}`);
  } else if (schema.type === 'array') {
    if (!Array.isArray(input)) throw new Error(`Параметр ${path} должен быть массивом`);
    if (input.length > 1000) throw new Error(`Слишком много элементов ${path}`);
    for (const value of input) validateToolInput(value, schema.items || {}, path);
  } else if (schema.type === 'integer') {
    if (
      !Number.isSafeInteger(input) ||
      (schema.minimum !== undefined && (input as number) < schema.minimum) ||
      (schema.maximum !== undefined && (input as number) > schema.maximum)
    )
      throw new Error(`Неверное число ${path}`);
  } else if (schema.type && typeof input !== schema.type) throw new Error(`Неверный тип ${path}`);
  if (schema.enum && !schema.enum.includes(input)) throw new Error(`Неизвестное значение ${path}`);
}
