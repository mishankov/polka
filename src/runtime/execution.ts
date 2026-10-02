import { randomUUID, createHash } from 'node:crypto';
export interface CoreLike {
  handle(method: string, params?: any): Promise<any> | any;
}
export interface RuntimeDependencies {
  readSecret(id: string): Promise<string | null>;
  writeSecret(id: string, value: string): Promise<void>;
  emit?(event: string, payload: unknown): void;
  executeAction(
    appId: string,
    actionId: string,
    input: unknown,
    signal: AbortSignal,
    onProgress: (progress: number) => void,
  ): Promise<unknown>;
  clipboardRead?(): Promise<string>;
  notify?(title: string, body: string): void | Promise<void>;
  call?(method: string, params: any): Promise<any>;
  fetch?: typeof fetch;
}
export type JobStatus = 'queued' | 'running' | 'completed' | 'failed' | 'cancelled' | 'interrupted';
export interface Job {
  id: string;
  definitionVersion?: number;
  appId: string;
  actionId: string;
  input: unknown;
  status: JobStatus;
  progress: number;
  result?: unknown;
  error?: string;
  createdAt: string;
  updatedAt: string;
  timeoutMs: number;
  idempotencyKey?: string;
  attempt: number;
  maxAttempts: number;
  retrySafe: boolean;
}
export interface Automation {
  id: string;
  definitionId?: string;
  definitionFingerprint?: string;
  appId: string;
  name: string;
  trigger: 'interval' | 'schedule' | 'clipboard' | 'event';
  actionId: string;
  enabled: boolean;
  intervalMs?: number;
  config: Record<string, any>;
  nextRunAt?: number;
  lastRunAt?: number;
  lastError?: string;
  history: { at: string; jobId?: string; error?: string }[];
}
const now = () => new Date().toISOString();
export class ExecutionService {
  jobs: Job[] = [];
  automations: Automation[] = [];
  private controllers = new Map<string, AbortController>();
  private runningTasks = new Set<Promise<void>>();
  private active = 0;
  private timer?: ReturnType<typeof setInterval>;
  private ticking = false;
  private closed = false;
  private clipboardHash?: string;
  private suspended = false;
  private automationDigest = '';
  constructor(
    private core: CoreLike,
    private deps: RuntimeDependencies,
  ) {}
  async init() {
    this.jobs = (await this.core.handle('state.get', { key: 'runtime.jobs' })) || [];
    this.automations = (await this.core.handle('state.get', { key: 'runtime.automations' })) || [];
    for (const job of this.jobs)
      if (job.status === 'running') {
        job.status = 'interrupted';
        job.error =
          'Платформа завершилась во время выполнения. Эффект мог произойти; автоматический повтор отключён';
        job.updatedAt = now();
      }
    await this.saveJobs();
    this.timer = setInterval(() => void this.tick().catch(() => {}), 1000);
    this.timer.unref?.();
    void this.pump();
  }
  private saveJobs() {
    this.deps.emit?.('jobs.updated', this.jobs);
    return this.core.handle('state.set', { key: 'runtime.jobs', value: this.jobs });
  }
  private saveAutomations() {
    const digest = JSON.stringify(this.automations);
    if (digest === this.automationDigest) return Promise.resolve();
    this.automationDigest = digest;
    this.deps.emit?.('automations.updated', this.automations);
    return this.core.handle('state.set', { key: 'runtime.automations', value: this.automations });
  }
  async enqueue(p: any): Promise<Job> {
    if (typeof p.appId !== 'string' || typeof p.actionId !== 'string')
      throw new Error('Не указано приложение или действие');
    const app = await this.core.handle('apps.get', { appId: p.appId });
    if (app.status !== 'running') throw new Error('Приложение остановлено');
    const action = app.definition.actions.find((a: any) => a.id === p.actionId);
    if (!action) throw new Error('Действие не найдено');
    if (p.idempotencyKey) {
      const previous = this.jobs.find(
        (j) =>
          j.appId === p.appId && j.actionId === p.actionId && j.idempotencyKey === p.idempotencyKey,
      );
      if (previous) return previous;
    }
    if (this.jobs.filter((j) => j.status === 'queued' || j.status === 'running').length >= 100)
      throw new Error('Очередь заполнена (100 заданий)');
    // Retry policy is derived from the registered action, never accepted from a caller.
    const safe = ['transform', 'records.query', 'records.list'].includes(action.type);
    const job: Job = {
      id: randomUUID(),
      definitionVersion: app.version,
      appId: p.appId,
      actionId: p.actionId,
      input: p.input,
      status: 'queued',
      progress: 0,
      createdAt: now(),
      updatedAt: now(),
      timeoutMs: Math.max(1000, Math.min(300000, p.timeoutMs || 60000)),
      idempotencyKey: p.idempotencyKey,
      attempt: 0,
      maxAttempts: safe ? Math.max(1, Math.min(3, p.maxAttempts || 1)) : 1,
      retrySafe: safe,
    };
    if ((JSON.stringify(job.input)?.length || 0) > 16 * 1024 * 1024)
      throw new Error('Вход задания превышает 16 МБ');
    this.jobs.push(job);
    await this.saveJobs();
    void this.pump();
    return job;
  }
  private async pump() {
    if (this.closed || this.suspended) return;
    while (this.active < 2) {
      const job = this.jobs.find((j) => j.status === 'queued');
      if (!job) break;
      this.active++;
      job.status = 'running';
      job.attempt++;
      job.updatedAt = now();
      await this.saveJobs();
      const task = this.execute(job).finally(() => {
        this.active--;
        this.runningTasks.delete(task);
        void this.pump();
      });
      this.runningTasks.add(task);
    }
  }
  private async execute(job: Job) {
    if (job.status !== 'running') return;
    const ctrl = new AbortController();
    this.controllers.set(job.id, ctrl);
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      ctrl.abort();
    }, job.timeoutMs);
    try {
      const app = await this.core.handle('apps.get', { appId: job.appId });
      if (app.status !== 'running') throw new Error('Приложение остановлено');
      if (app.version !== job.definitionVersion)
        throw new Error(
          'Определение приложения изменилось после постановки задания. Запустите действие заново',
        );
      const aborted = new Promise<never>((_, reject) => {
        ctrl.signal.addEventListener(
          'abort',
          () => reject(new Error(timedOut ? 'Превышено время выполнения' : 'Задание отменено')),
          { once: true },
        );
      });
      const result = await Promise.race([
        this.deps.executeAction(job.appId, job.actionId, job.input, ctrl.signal, (p) => {
          if (ctrl.signal.aborted) return;
          job.progress = Math.max(0, Math.min(1, p));
          job.updatedAt = now();
          void this.saveJobs();
        }),
        aborted,
      ]);
      if (ctrl.signal.aborted) throw new Error('Задание отменено');
      job.result = result;
      job.progress = 1;
      job.status = 'completed';
    } catch (error) {
      job.error = String((error as Error).message || error);
      job.status = ctrl.signal.aborted && !timedOut ? 'cancelled' : 'failed';
      if (!ctrl.signal.aborted && job.retrySafe && job.attempt < job.maxAttempts)
        job.status = 'queued';
    } finally {
      clearTimeout(timer);
      this.controllers.delete(job.id);
      job.updatedAt = now();
      await this.saveJobs();
    }
  }
  async cancel(id: string) {
    const job = this.jobs.find((j) => j.id === id);
    if (!job) throw new Error('Задание не найдено');
    if (['running', 'queued'].includes(job.status)) {
      this.controllers.get(id)?.abort();
      job.status = 'cancelled';
      job.updatedAt = now();
      await this.saveJobs();
    }
    return job;
  }
  async stopApp(appId: string) {
    for (const job of this.jobs.filter(
      (j) => j.appId === appId && ['queued', 'running'].includes(j.status),
    ))
      await this.cancel(job.id);
    for (const a of this.automations.filter((a) => a.appId === appId)) a.enabled = false;
    await this.saveAutomations();
  }
  async saveAutomation(p: any) {
    const app = await this.core.handle('apps.get', { appId: p.appId });
    if (!app.definition.actions.some((a: any) => a.id === p.actionId))
      throw new Error('Действие автоматизации не найдено');
    if (!['interval', 'schedule', 'clipboard', 'event'].includes(p.trigger))
      throw new Error('Неизвестный триггер');
    if (p.enabled) await this.checkBackground(p.appId, p.trigger);
    const existing = p.id
      ? this.automations.find((a) => a.id === p.id && a.appId === p.appId)
      : undefined;
    if (p.id && !existing) throw new Error('Автоматизация не найдена');
    if (
      !existing &&
      (this.automations.length >= 1000 ||
        this.automations.filter((a) => a.appId === p.appId).length >= 100)
    )
      throw new Error('Лимит: 100 автоматизаций на приложение, 1000 в рабочем пространстве');
    const config = p.config || {};
    if (config.conditions !== undefined) {
      if (!Array.isArray(config.conditions) || config.conditions.length > 20)
        throw new Error('Не более 20 условий');
      for (const c of config.conditions)
        if (
          !c ||
          typeof c.path !== 'string' ||
          c.path.length > 200 ||
          !['eq', 'neq', 'contains', 'gt', 'lt'].includes(c.operator)
        )
          throw new Error('Некорректное условие автоматизации');
    }
    if (p.trigger === 'schedule') {
      new Intl.DateTimeFormat('en', { timeZone: config.timezone || 'Europe/Moscow' });
      if (
        !Number.isInteger(config.hour) ||
        config.hour < 0 ||
        config.hour > 23 ||
        !Number.isInteger(config.minute) ||
        config.minute < 0 ||
        config.minute > 59
      )
        throw new Error('Укажите час 0–23 и минуту 0–59');
    }
    if (config.missed && !['skip', 'once', 'catchup'].includes(config.missed))
      throw new Error('Неизвестная политика пропуска');
    const a: Automation = {
      id: existing?.id || randomUUID(),
      definitionId: existing?.definitionId,
      definitionFingerprint: existing?.definitionFingerprint,
      appId: p.appId,
      name: String(p.name || 'Автоматизация').slice(0, 200),
      trigger: p.trigger,
      actionId: p.actionId,
      enabled: !!p.enabled,
      intervalMs: Math.max(1000, Math.min(86400000, p.intervalMs || 60000)),
      config,
      history: existing?.history || [],
      nextRunAt: Date.now() + (p.intervalMs || 60000),
    };
    a.nextRunAt = Date.now() + a.intervalMs!;
    if (a.trigger === 'schedule') a.nextRunAt = nextDaily(Date.now(), config);
    if (existing) this.automations.splice(this.automations.indexOf(existing), 1, a);
    else this.automations.push(a);
    await this.saveAutomations();
    return a;
  }
  async syncApp(appId: string) {
    const app = await this.core.handle('apps.get', { appId }),
      declared = app.definition.automations || [];
    for (const previous of this.automations.filter((a) => a.appId === appId && a.definitionId))
      if (!declared.some((d: any) => d.id === previous.definitionId)) {
        previous.enabled = false;
        previous.lastError = 'Правило удалено из определения приложения';
      }
    for (const definition of declared) {
      const fingerprint = JSON.stringify(definition),
        existing = this.automations.find(
          (a) => a.appId === appId && a.definitionId === definition.id,
        );
      if (existing?.definitionFingerprint === fingerprint) continue;
      // Definition upgrades retain explicit local edits and disabled state. A changed declaration is staged disabled for review.
      if (existing) {
        existing.definitionFingerprint = fingerprint;
        existing.lastError =
          'Определение правила изменилось. Проверьте локальные настройки перед включением';
        existing.enabled = false;
        continue;
      }
      const created = await this.saveAutomation({
        ...definition,
        id: undefined,
        appId,
        enabled: false,
      });
      created.definitionId = definition.id;
      created.definitionFingerprint = fingerprint;
    }
    await this.saveAutomations();
    return this.automations.filter((a) => a.appId === appId);
  }
  private async checkBackground(appId: string, trigger: string) {
    const permissions = await this.core.handle('permissions.list', { appId });
    const has = (id: string) => permissions.some((p: any) => p.permission === id);
    if (!has('background')) throw new Error('Разрешите фоновую работу в настройках приложения');
    if (trigger === 'clipboard' && !has('clipboard.read'))
      throw new Error('Разрешите чтение буфера в настройках приложения');
  }
  async setEnabled(p: any) {
    const a = this.automations.find((a) => a.id === p.id);
    if (!a) throw new Error('Автоматизация не найдена');
    if (p.enabled) await this.checkBackground(a.appId, a.trigger);
    a.enabled = !!p.enabled;
    await this.saveAutomations();
    return a;
  }
  async deleteAutomation(id: string) {
    this.automations = this.automations.filter((a) => a.id !== id);
    await this.saveAutomations();
    return { deleted: true };
  }
  async signal(event: string, data: unknown = {}) {
    if (event === 'suspend') {
      this.suspended = true;
      return;
    }
    if (event === 'resume') {
      this.suspended = false;
      this.clipboardHash = undefined;
      await this.tick();
      void this.pump();
    }
    for (const a of this.automations.filter(
      (a) => a.enabled && a.trigger === 'event' && a.config.event === event,
    ))
      await this.fire(a, { event, data });
  }
  async tick(time = Date.now()) {
    if (this.ticking || this.closed || this.suspended) return;
    this.ticking = true;
    try {
      const clip = this.automations.some((a) => a.enabled && a.trigger === 'clipboard');
      let clipboard: string | undefined;
      if (clip && this.deps.clipboardRead) {
        const permitted = [];
        for (const a of this.automations.filter((a) => a.enabled && a.trigger === 'clipboard'))
          try {
            await this.checkBackground(a.appId, a.trigger);
            permitted.push(a);
          } catch (e) {
            a.enabled = false;
            a.lastError = (e as Error).message;
          }
        if (permitted.length)
          try {
            clipboard = await this.deps.clipboardRead();
            for (const a of permitted) a.lastError = undefined;
          } catch (e) {
            for (const a of permitted)
              a.lastError = 'Источник временно недоступен: ' + (e as Error).message;
          }
      }
      const hash =
        clipboard !== undefined ? createHash('sha256').update(clipboard).digest('hex') : undefined;
      for (const a of this.automations.filter((a) => a.enabled)) {
        try {
          const app = await this.core.handle('apps.get', { appId: a.appId });
          if (app.status !== 'running') {
            a.enabled = false;
            continue;
          }
          await this.checkBackground(a.appId, a.trigger);
          if (
            a.trigger === 'clipboard' &&
            hash &&
            this.clipboardHash &&
            hash !== this.clipboardHash
          )
            await this.fire(a, { text: clipboard });
          if (['interval', 'schedule'].includes(a.trigger) && a.nextRunAt && a.nextRunAt <= time) {
            const due = a.nextRunAt,
              interval = a.intervalMs || 60000;
            const missed = a.config.missed || 'once';
            let count = 1;
            if (a.trigger === 'interval') count = Math.floor((time - due) / interval) + 1;
            else {
              let next = nextDaily(due, a.config);
              while (next <= time && count < 100) {
                count++;
                next = nextDaily(next, a.config);
              }
            }
            const runs =
              count === 1 && time - due <= 5000
                ? 1
                : missed === 'skip'
                  ? 0
                  : missed === 'catchup'
                    ? Math.min(count, Math.max(1, Math.min(10, a.config.catchupLimit || 3)))
                    : 1;
            for (let i = 0; i < runs; i++)
              await this.fire(
                a,
                { scheduledAt: new Date(due).toISOString() },
                `${a.id}:${due}:${i}`,
              );
            a.nextRunAt =
              a.trigger === 'interval' ? due + count * interval : nextDaily(time, a.config);
          }
        } catch (e) {
          a.lastError = (e as Error).message;
          a.enabled = false;
          a.history.unshift({ at: now(), error: a.lastError });
        }
      }
      this.clipboardHash = hash || this.clipboardHash;
      await this.saveAutomations();
    } finally {
      this.ticking = false;
    }
  }
  private async fire(a: Automation, input: unknown, idempotencyKey?: string) {
    if (!matchesConditions(input, a.config.conditions || [])) return;
    await this.checkBackground(a.appId, a.trigger);
    const job = await this.enqueue({ appId: a.appId, actionId: a.actionId, input, idempotencyKey });
    a.lastRunAt = Date.now();
    a.lastError = undefined;
    a.history.unshift({ at: now(), jobId: job.id });
    a.history = a.history.slice(0, 100);
    await this.saveAutomations();
  }
  async shutdown() {
    this.closed = true;
    if (this.timer) clearInterval(this.timer);
    for (const ctrl of this.controllers.values()) ctrl.abort();
    await Promise.allSettled([...this.runningTasks]);
    await this.saveJobs();
    await this.saveAutomations();
  }
}
/** Daily wall-clock time in a named IANA timezone; spring gaps skip and fall folds run once. */
export function nextDaily(after: number, config: Record<string, any>): number {
  const formatter = new Intl.DateTimeFormat('en-CA', {
    timeZone: config.timezone || 'Europe/Moscow',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  });
  const parts = (t: number) =>
    Object.fromEntries(formatter.formatToParts(t).map((p) => [p.type, p.value]));
  const before = parts(after);
  for (let t = Math.floor(after / 60000) * 60000 + 60000; t <= after + 72 * 3600000; t += 60000) {
    const p = parts(t);
    if (+p.hour === config.hour && +p.minute === config.minute) {
      const sameDate = p.year === before.year && p.month === before.month && p.day === before.day;
      const alreadyRan =
        sameDate && +before.hour === config.hour && +before.minute >= config.minute;
      if (!alreadyRan) return t;
    }
  }
  throw new Error('Не удалось вычислить следующий запуск');
}

export function matchesConditions(
  input: unknown,
  conditions: { path: string; operator: string; value: unknown }[],
): boolean {
  return conditions.every((c) => {
    let value: any = input;
    for (const key of c.path.split('.')) {
      if (
        ['__proto__', 'prototype', 'constructor'].includes(key) ||
        !value ||
        typeof value !== 'object' ||
        !Object.prototype.hasOwnProperty.call(value, key)
      )
        return false;
      value = value[key];
    }
    switch (c.operator) {
      case 'eq':
        return JSON.stringify(value) === JSON.stringify(c.value);
      case 'neq':
        return JSON.stringify(value) !== JSON.stringify(c.value);
      case 'contains':
        return typeof value === 'string' && value.includes(String(c.value));
      case 'gt':
        return typeof value === 'number' && typeof c.value === 'number' && value > c.value;
      case 'lt':
        return typeof value === 'number' && typeof c.value === 'number' && value < c.value;
      default:
        return false;
    }
  });
}
