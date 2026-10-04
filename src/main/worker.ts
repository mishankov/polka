import { CUSTOM_APPS_ENABLED, FROZEN_FEATURE_MESSAGE } from '../shared/features';
import { parentPort, workerData } from 'node:worker_threads';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { PackageTasks } from '../core/package-tasks';
import { transforms } from '../services/transforms';
import { FormatRunner } from '../services/formatRunner';
import { CoreService } from '../core/service';
import { DocumentService } from '../services/documents';
import { compileExtension, runHandler, buildComponent } from '../extensions/host';
import { RuntimeService } from '../runtime/service';
import { createBuiltinAdapters } from '../extensions/adapters';
const port = parentPort!,
  core = new CoreService(workerData.root),
  docs = new DocumentService(core);
const parentCalls = new Map<string, { resolve: (v: any) => void; reject: (e: Error) => void }>();
function host(method: string, params: any = {}) {
  const id = randomUUID();
  return new Promise<any>((resolve, reject) => {
    parentCalls.set(id, { resolve, reject });
    port.postMessage({ kind: 'host', id, method, params });
  });
}
const emit = (type: string, payload: any = {}) =>
  port.postMessage({
    kind: 'event',
    event: {
      type,
      payload,
      ...(!Array.isArray(payload) && payload && typeof payload === 'object' ? payload : {}),
    },
  });
const packageTasks = new PackageTasks(core, join(__dirname, 'package-worker.js'), emit);
const formats = new FormatRunner(join(__dirname, 'transformWorker.js'));
const adapters = createBuiltinAdapters({
  ensurePermission,
  readConnection: (appId, connectionId, origin) =>
    host('connection.read', { appId, connectionId, origin }),
});
async function ensurePermission(appId: string, permission: string) {
  const app = await core.handle('apps.get', { appId });
  if (app.status !== 'running') throw Error('Приложение остановлено');
  const permissions = await core.handle('permissions.list', { appId });
  if (!permissions.some((p: any) => p.permission === permission))
    throw Error(`Требуется разрешение: ${permission}`);
}
async function scoped(appId: string, method: string, params: any = {}, signal?: AbortSignal) {
  signal?.throwIfAborted();
  if (params.appId && params.appId !== appId) throw Error('Доступ к другому экземпляру запрещён');
  await core.handle('apps.get', { appId });
  if (method === 'transforms.list') return transforms;
  if (method === 'transforms.run') return formats.run(params.operation, params.input, signal);
  if (method === 'adapters.list') return adapters.registry.catalog();
  if (method === 'actions.run') return dispatch('actions.run', { ...params, appId });
  if (method === 'jobs.list') return runtime!.handle('jobs.list', { appId });
  if (method === 'jobs.cancel') {
    const jobs = await runtime!.handle('jobs.list', { appId });
    if (!jobs.some((job: any) => job.id === params.jobId))
      throw Error('Задание не принадлежит приложению');
    return runtime!.handle('jobs.cancel', { jobId: params.jobId });
  }
  if (
    method.startsWith('records.') ||
    method === 'links.query' ||
    ['attachments.list', 'attachments.read'].includes(method)
  )
    return core.callScoped(appId, method, params);
  if (['docs.list', 'docs.get', 'docs.create', 'docs.draft', 'docs.revert'].includes(method)) {
    if (params.appId && params.appId !== appId) throw Error('Доступ к другому экземпляру запрещён');
    return dispatch(method, { ...params, appId });
  }
  if (method === 'clipboard.read' || method === 'clipboard.write') {
    await ensurePermission(appId, method);
    return host(method, { text: params.text });
  }
  if (method === 'notifications.show') {
    await ensurePermission(appId, 'notifications');
    return host(method, { title: params.title, body: params.body });
  }
  if (method === 'system.media') {
    await ensurePermission(appId, 'system.media');
    return host(method);
  }
  if (adapters.registry.has(method)) return adapters.registry.invoke(method, appId, params, signal);
  throw Error('Расширению недоступна эта операция');
}
async function extension(appId: string, extensionId: string) {
  const app = await core.handle('apps.get', { appId });
  if (app.status !== 'running') throw Error('Приложение остановлено');
  const ext = app.definition.extensions.find((e: any) => e.id === extensionId);
  if (!ext) throw Error('Расширение не найдено');
  return ext;
}
async function executeAction(
  appId: string,
  actionId: string,
  input: any,
  signal: AbortSignal,
  onProgress: (v: number) => void,
) {
  const app = await core.handle('apps.get', { appId });
  if (app.status !== 'running') throw Error('Приложение остановлено');
  const action = app.definition.actions.find((a: any) => a.id === actionId);
  if (!action) throw Error('Действие не найдено');
  if (action.permission) await ensurePermission(appId, action.permission);
  signal.throwIfAborted();
  onProgress(0.1);
  const cfg = action.config || {};
  let result;
  if (action.type === 'transform')
    result = await formats.run(cfg.operation, input ?? cfg.input, signal);
  else if (action.type === 'extension') {
    const ext = await extension(appId, cfg.extensionId);
    result = await runHandler(
      await compileExtension(ext.source, 'handler', ext.dependencies),
      input,
      (m, p) => scoped(appId, m, p, signal),
      signal,
    );
  } else if (action.type === 'records.upsert')
    result = await core.callScoped(appId, 'records.upsert', {
      entityId: cfg.entityId,
      values: input || cfg.values,
    });
  else if (action.type === 'records.list')
    result = await core.callScoped(appId, 'records.list', { entityId: cfg.entityId, ...cfg });
  else result = await scoped(appId, action.type, { ...cfg, ...input }, signal);
  onProgress(1);
  return result;
}
const customAppsEnabled = workerData.customAppsEnabled ?? CUSTOM_APPS_ENABLED;
const runtime = customAppsEnabled
  ? new RuntimeService({ handle: (method: string, p: any) => dispatch(method, p) } as any, {
      readSecret: (id: string) => host('secret.read', { id }),
      writeSecret: (id: string, value: string) => host('secret.write', { id, value }),
      emit,
      executeAction,
      clipboardRead: () => host('clipboard.read'),
      notify: (title: string, body: string) => {
        void host('notifications.show', { title, body });
      },
      call: (m: string, p: any) => dispatch(m, p),
    })
  : undefined;
const importPreviews = new Map<string, any>();
async function validateExtensions(definition: any) {
  for (const ext of definition?.extensions || [])
    await compileExtension(ext.source, ext.kind, ext.dependencies);
}
async function dispatch(method: string, p: any = {}, documentLock = false): Promise<any> {
  if (!customAppsEnabled && !/^(settings|state)\./.test(method))
    throw Error(FROZEN_FEATURE_MESSAGE);
  if (
    !documentLock &&
    (method.startsWith('docs.') ||
      [
        'packages.importCommit',
        'apps.delete',
        'apps.duplicate',
        'apps.splitCommit',
        'apps.mergeCommit',
      ].includes(method))
  ) {
    const next = documentQueue.then(() => dispatch(method, p, true));
    documentQueue = next.then(
      () => {},
      () => {},
    );
    return next;
  }
  if (
    method.startsWith('provider.') ||
    method.startsWith('agent.') ||
    method.startsWith('jobs.') ||
    method.startsWith('automations.') ||
    method.startsWith('watchers.') ||
    method.startsWith('capabilities.') ||
    method === 'runtime.signal' ||
    method === 'runtime.stopApp' ||
    method === 'runtime.syncApp'
  )
    return runtime!.handle(method, p);
  if (method.startsWith('docs.')) return docs.handle(method, p);
  if (method === 'packages.taskCancel') return packageTasks.cancel(p.taskId);
  if (method === 'packages.taskStatus') return packageTasks.status(p.taskId);
  if (method === 'packages.export') return packageTasks.export(p, p.taskId);
  if (method === 'transforms.list') return transforms;
  if (method === 'transforms.run') return formats.run(p.operation, p.input);
  if (method === 'adapters.list') return adapters.registry.catalog();
  if (method === 'actions.run') return runtime!.handle('jobs.enqueue', p);
  if (method === 'extensions.build') {
    const ext = await extension(p.appId, p.extensionId);
    return ext.kind === 'component'
      ? buildComponent(ext.source, ext.dependencies || {})
      : { kind: 'handler', code: await compileExtension(ext.source, 'handler', ext.dependencies) };
  }
  if (method === 'extensions.run') {
    const ext = await extension(p.appId, p.extensionId);
    if (ext.kind !== 'handler') throw Error('Выберите обработчик');
    return runHandler(
      await compileExtension(ext.source, 'handler', ext.dependencies),
      p.input,
      (m, params) => scoped(p.appId, m, params),
    );
  }
  if (method === 'extensions.call') {
    await extension(p.appId, p.extensionId);
    return scoped(p.appId, p.method, p.params);
  }
  if (method === 'definitions.prepare' || method === 'apps.create')
    await validateExtensions(p.definition);
  if (method === 'packages.importPreview' || method === 'packages.updatePreview') {
    const preview =
      method === 'packages.importPreview'
        ? await packageTasks.importPreview(p.path, p.taskId)
        : await packageTasks.updatePreview(p.appId, p.path, p.taskId);
    await validateExtensions(preview.definition);
    importPreviews.set(preview.previewId, preview);
    return preview;
  }
  if (
    (method === 'packages.importCommit' || method === 'packages.updateCommit') &&
    !importPreviews.has(p.previewId)
  )
    throw Error('Сначала проверьте пакет');
  if (
    (method === 'apps.updateMeta' && ['stopped', 'archived'].includes(p.status)) ||
    (method === 'apps.delete' && p.confirm) ||
    method === 'permissions.revoke'
  ) {
    adapters.abortApp(p.appId);
    await runtime!.handle('runtime.stopApp', { appId: p.appId });
  }
  const result = await core.handle(method, p);
  if (
    [
      'apps.create',
      'apps.duplicate',
      'definitions.activate',
      'snapshots.restore',
      'packages.importCommit',
      'packages.updateCommit',
      'apps.splitCommit',
      'apps.mergeCommit',
    ].includes(method)
  ) {
    const appId = result?.app?.id || result?.id;
    if (appId) await runtime!.handle('runtime.syncApp', { appId });
  }
  if (
    /^(apps|definitions|permissions|records|packages|snapshots)\./.test(method) &&
    !/\.(list|get|history|preview|importPreview)$/.test(method)
  )
    emit('workspace.changed', { method, appId: p.appId });
  return result;
}
let documentQueue = Promise.resolve();
port.on('message', async (message: any) => {
  if (message.kind === 'hostResult') {
    const pending = parentCalls.get(message.id);
    if (pending) {
      parentCalls.delete(message.id);
      message.error ? pending.reject(Error(message.error)) : pending.resolve(message.result);
    }
    return;
  }
  if (message.kind === 'shutdown') {
    formats.close();
    await packageTasks.shutdown();
    await runtime?.shutdown();
    core.close();
    process.exit(0);
  }
  if (message.kind !== 'call') return;
  try {
    const result = await dispatch(message.method, message.params);
    port.postMessage({ kind: 'result', id: message.id, result });
  } catch (error) {
    port.postMessage({
      kind: 'result',
      id: message.id,
      error: error instanceof Error ? error.message : 'Ошибка выполнения',
    });
  }
});
port.postMessage({ kind: 'ready' });
