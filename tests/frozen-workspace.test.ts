import test from 'node:test';
import assert from 'node:assert/strict';
import { Worker } from 'node:worker_threads';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { CoreService } from '../src/core/service';

const bundle = join(import.meta.dirname, '../out/main/worker.js');
test(
  'frozen worker never starts persisted jobs, watchers or assistant sessions and preserves their state',
  {
    skip: existsSync(bundle) ? false : 'Build the worker first',
  },
  async () => {
    const root = mkdtempSync(join(tmpdir(), 'everything-frozen-'));
    const before = new CoreService(root);
    const state = {
      'runtime.jobs': [{ id: 'pending', status: 'queued', appId: 'dormant', actionId: 'notify' }],
      'runtime.runs': [{ id: 'assistant', status: 'waiting_approval' }],
      'runtime.automations': [
        { id: 'watcher', enabled: true, trigger: { type: 'clipboard.changed' } },
      ],
      'runtime.provider': {
        type: 'openai',
        endpoint: 'https://example.invalid',
        model: 'saved-model',
      },
    };
    for (const [key, value] of Object.entries(state))
      await before.handle('state.set', { key, value });
    before.close();
    const worker = new Worker(bundle, { workerData: { root } });
    const hosts: unknown[] = [];
    worker.on('message', (message) => {
      if (message.kind === 'host') hosts.push(message);
    });
    try {
      let message;
      do {
        [message] = await once(worker, 'message');
      } while (message.kind !== 'ready');
      async function call(method: string) {
        const id = randomUUID();
        const result = new Promise<any>((resolve) => {
          const listener = (message: any) => {
            if (message.id !== id || message.kind !== 'result') return;
            worker.off('message', listener);
            resolve(message);
          };
          worker.on('message', listener);
        });
        worker.postMessage({ kind: 'call', id, method, params: {} });
        return result;
      }
      for (const method of [
        'agent.send',
        'apps.start',
        'jobs.enqueue',
        'runtime.signal',
        'provider.get',
      ])
        assert.match((await call(method)).error, /временно приостановлены/);
      // Cross one scheduler tick to detect accidentally initialized background work.
      await new Promise((resolve) => setTimeout(resolve, 1150));
      assert.deepEqual(hosts, []);
      const exited = once(worker, 'exit');
      worker.postMessage({ kind: 'shutdown' });
      await exited;
      const after = new CoreService(root);
      try {
        for (const [key, value] of Object.entries(state))
          assert.deepEqual(await after.handle('state.get', { key }), value);
      } finally {
        after.close();
      }
    } finally {
      await worker.terminate();
      rmSync(root, { recursive: true, force: true });
    }
  },
);
