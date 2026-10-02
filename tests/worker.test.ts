import test from 'node:test';
import assert from 'node:assert/strict';
import { Worker } from 'node:worker_threads';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import type { AppDefinition } from '../src/shared/types';

// This suite intentionally runs the distributed worker bundle, not a replacement dispatch mock.
// `npm run build && npm test` exercises it. A source-only checkout reports the skip explicitly.
const workerPath = fileURLToPath(new URL('../out/main/worker.js', import.meta.url));
const options = {
  skip: existsSync(workerPath) ? false : 'Built worker absent; run npm run build before npm test',
  timeout: 20000,
};
const definition = (): AppDefinition => ({
  schemaVersion: 1,
  name: 'Worker integration',
  entities: [
    {
      id: 'items',
      name: 'Items',
      fields: [{ id: 'title', name: 'Title', type: 'text', required: true }],
    },
  ],
  screens: [{ id: 'items', name: 'Items', type: 'table', entityId: 'items' }],
  actions: [
    {
      id: 'notify',
      name: 'Notify',
      type: 'notifications.show',
      config: { title: 'Task', body: 'Finished' },
    },
  ],
  automations: [],
  extensions: [
    {
      id: 'handler',
      name: 'Scoped handler',
      kind: 'handler',
      source:
        'export default function(input) { return {value: "done", operations: [{method: input.method, params: input.params}]}; }',
    },
  ],
  permissions: ['notifications', 'background', 'clipboard.read'],
});
async function until(check: () => Promise<boolean> | boolean) {
  for (let i = 0; i < 300; i++) {
    if (await check()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw Error('Worker state did not settle within three seconds');
}
async function fixture(
  run: (ctx: {
    call: (method: string, params?: any) => Promise<any>;
    hostCalls: { method: string; params: any }[];
    holdNotifications: () => void;
    releaseNotifications: () => void;
  }) => Promise<void>,
) {
  const root = mkdtempSync(join(tmpdir(), 'everything-worker-')),
    worker = new Worker(workerPath, { workerData: { root } });
  const pending = new Map<string, { resolve: (v: any) => void; reject: (e: Error) => void }>(),
    hostCalls: { method: string; params: any }[] = [],
    held: any[] = [];
  let hold = false,
    exited = false;
  let readyResolve!: () => void, readyReject!: (error: Error) => void;
  const ready = new Promise<void>((resolve, reject) => {
    readyResolve = resolve;
    readyReject = reject;
  });
  const exit = new Promise<void>((resolve) =>
    worker.once('exit', () => {
      exited = true;
      resolve();
    }),
  );
  worker.on('error', (error) => {
    const failure = error instanceof Error ? error : Error(String(error));
    readyReject(failure);
    for (const request of pending.values()) request.reject(failure);
    pending.clear();
  });
  worker.on('message', (message) => {
    if (message.kind === 'ready') readyResolve();
    if (message.kind === 'result') {
      const request = pending.get(message.id);
      if (request) {
        pending.delete(message.id);
        message.error ? request.reject(Error(message.error)) : request.resolve(message.result);
      }
    }
    if (message.kind === 'host') {
      hostCalls.push({ method: message.method, params: message.params });
      if (message.method === 'notifications.show' && hold) held.push(message);
      else
        worker.postMessage({
          kind: 'hostResult',
          id: message.id,
          error: 'Unexpected host capability in integration test',
        });
    }
  });
  const call = (method: string, params: any = {}) =>
    new Promise<any>((resolve, reject) => {
      const id = randomUUID();
      pending.set(id, { resolve, reject });
      worker.postMessage({ kind: 'call', id, method, params });
    });
  const releaseNotifications = () => {
    hold = false;
    for (const message of held.splice(0))
      worker.postMessage({ kind: 'hostResult', id: message.id, result: true });
  };
  try {
    await ready;
    await run({
      call,
      hostCalls,
      holdNotifications: () => {
        hold = true;
      },
      releaseNotifications,
    });
  } finally {
    releaseNotifications();
    if (!exited) worker.postMessage({ kind: 'shutdown' });
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([
      exit,
      new Promise<void>((resolve) => {
        timer = setTimeout(resolve, 1500);
      }),
    ]);
    if (timer) clearTimeout(timer);
    if (!exited) await worker.terminate();
    rmSync(root, { recursive: true, force: true });
  }
}

test(
  'built worker creates/stops instances and executes an extension against only its own records',
  options,
  () =>
    fixture(async ({ call, hostCalls }) => {
      const app = await call('apps.create', { definition: definition() }),
        other = await call('apps.create', { definition: definition() });
      assert.equal(app.status, 'stopped');
      await assert.rejects(
        call('extensions.run', {
          appId: app.id,
          extensionId: 'handler',
          input: { method: 'records.list', params: { entityId: 'items' } },
        }),
        /остановлено/,
      );
      await call('apps.updateMeta', { appId: app.id, status: 'running' });
      await call('apps.updateMeta', { appId: other.id, status: 'running' });
      const result = await call('extensions.run', {
        appId: app.id,
        extensionId: 'handler',
        input: {
          method: 'records.upsert',
          params: { entityId: 'items', values: { title: 'Own value' } },
        },
      });
      assert.equal(result.results[0].values.title, 'Own value');
      await assert.rejects(
        call('extensions.run', {
          appId: app.id,
          extensionId: 'handler',
          input: { method: 'records.list', params: { appId: other.id, entityId: 'items' } },
        }),
        /запрещён/,
      );
      assert.equal((await call('records.list', { appId: other.id, entityId: 'items' })).total, 0);
      assert.equal((await call('records.list', { appId: app.id, entityId: 'items' })).total, 1);
      assert.equal(hostCalls.length, 0);
    }),
);

test(
  'built worker denies extension access to state, secrets, files, clipboard and ungranted network',
  options,
  () =>
    fixture(async ({ call, hostCalls }) => {
      const app = await call('apps.create', { definition: definition() });
      await call('apps.updateMeta', { appId: app.id, status: 'running' });
      for (const [method, params] of [
        ['state.get', { key: 'runtime.provider' }],
        ['secret.read', { id: 'provider:openai' }],
        ['settings.get', {}],
        ['docs.openPath', { path: '/etc/passwd' }],
        ['packages.export', { path: '/tmp/forbidden.everyapp' }],
        ['clipboard.read', {}],
        ['clipboard.write', { text: 'forbidden' }],
        ['network.fetch', { url: 'https://example.com/private' }],
      ] as const)
        await assert.rejects(
          call('extensions.run', {
            appId: app.id,
            extensionId: 'handler',
            input: { method, params },
          }),
          /недоступна|Требуется/,
        );
      await assert.rejects(
        call('extensions.call', {
          appId: app.id,
          extensionId: 'handler',
          method: 'state.set',
          params: { key: 'owned', value: true },
        }),
        /недоступна/,
      );
      assert.equal(await call('state.get', { key: 'owned' }), null);
      assert.equal(
        hostCalls.length,
        0,
        'Denied operations must never reach privileged parent host',
      );
    }),
);

test(
  'built worker rejects invalid extension definitions before activation and compiles a component',
  options,
  () =>
    fixture(async ({ call, hostCalls }) => {
      const initial = definition(),
        app = await call('apps.create', { definition: initial });
      await call('apps.updateMeta', { appId: app.id, status: 'running' });
      await call('records.upsert', { appId: app.id, entityId: 'items', values: { title: 'Keep' } });
      for (const source of [
        'export default function( {',
        'import fs from "node:fs"; export default () => fs.readFileSync("/etc/passwd");',
      ]) {
        const invalid = structuredClone(initial);
        invalid.extensions[0].source = source;
        await assert.rejects(call('definitions.prepare', { appId: app.id, definition: invalid }));
        const current = await call('apps.get', { appId: app.id });
        assert.equal(current.version, 1);
        assert.equal(current.definition.extensions[0].source, initial.extensions[0].source);
      }
      const next = structuredClone(initial);
      next.extensions.push({
        id: 'screen',
        name: 'Custom screen',
        kind: 'component',
        source: 'export default function Screen() { return <button>Local component</button> }',
      });
      const draft = await call('definitions.prepare', { appId: app.id, definition: next });
      await call('definitions.activate', { draftId: draft.draftId });
      const component = await call('extensions.build', { appId: app.id, extensionId: 'screen' });
      assert.equal(component.kind, 'component');
      assert.ok(component.html.includes('Local component'));
      assert.ok(component.html.includes("connect-src 'none'"));
      assert.equal(
        (await call('records.list', { appId: app.id, entityId: 'items' })).records[0].values.title,
        'Keep',
      );
      assert.equal(hostCalls.length, 0);
    }),
);

test(
  'built worker bounds queue concurrency, cancels pending jobs, and stops background work on revocation',
  options,
  () =>
    fixture(async ({ call, hostCalls, holdNotifications, releaseNotifications }) => {
      const app = await call('apps.create', { definition: definition() });
      await call('apps.updateMeta', { appId: app.id, status: 'running' });
      await assert.rejects(
        call('automations.save', {
          appId: app.id,
          name: 'Denied watcher',
          trigger: 'clipboard',
          actionId: 'notify',
          enabled: true,
        }),
        /Разрешите фоновую/,
      );
      assert.equal(hostCalls.length, 0);
      await call('permissions.grant', { appId: app.id, permission: 'notifications' });
      await call('permissions.grant', { appId: app.id, permission: 'background' });
      const automation = await call('automations.save', {
        appId: app.id,
        name: 'Background',
        trigger: 'interval',
        actionId: 'notify',
        enabled: true,
        intervalMs: 60000,
      });
      holdNotifications();
      const first = await call('actions.run', { appId: app.id, actionId: 'notify' }),
        second = await call('jobs.enqueue', { appId: app.id, actionId: 'notify' }),
        third = await call('jobs.enqueue', { appId: app.id, actionId: 'notify' });
      await until(() => hostCalls.length === 2);
      const queued = (await call('jobs.list', { appId: app.id })).find(
        (job: any) => job.id === third.id,
      );
      assert.equal(queued.status, 'queued');
      await call('jobs.cancel', { jobId: third.id });
      await call('permissions.revoke', { appId: app.id, permission: 'notifications' });
      await until(async () => {
        const jobs = await call('jobs.list', { appId: app.id });
        return [first.id, second.id, third.id].every(
          (id) => jobs.find((j: any) => j.id === id)?.status === 'cancelled',
        );
      });
      assert.equal(
        (await call('automations.list', { appId: app.id })).find((a: any) => a.id === automation.id)
          .enabled,
        false,
      );
      releaseNotifications();
      assert.equal(hostCalls.length, 2);
      assert.ok(
        hostCalls.every((c) => c.method === 'notifications.show'),
        'No secrets or clipboard should have reached parent',
      );
    }),
);
