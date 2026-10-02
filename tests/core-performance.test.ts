import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { CoreService } from '../src/core/service';

test('10k-record local data fixture exports and imports intact', async () => {
  const root = mkdtempSync(join(tmpdir(), 'everything-perf-')),
    core = new CoreService(root),
    timings: Record<string, number> = {};
  const measure = async <T>(name: string, fn: () => Promise<T>) => {
    const start = performance.now();
    const result = await fn();
    timings[name] = Math.round((performance.now() - start) * 10) / 10;
    return result;
  };
  try {
    const app = await core.handle('apps.create', {
      definition: {
        schemaVersion: 1,
        name: '10k fixture',
        entities: [
          {
            id: 'items',
            name: 'Записи',
            fields: [
              { id: 'title', name: 'Название', type: 'text' },
              { id: 'content', name: 'Текст', type: 'text' },
            ],
          },
        ],
        screens: [],
        actions: [],
        automations: [],
        extensions: [],
        permissions: [],
      },
    });
    await measure('write10kMs', async () => {
      for (let batch = 0; batch < 10; batch++) {
        const operations = Array.from({ length: 1000 }, (_, i) => {
          const n = batch * 1000 + i;
          return {
            type: 'upsert',
            entityId: 'items',
            values: {
              title: `Запись ${n}`,
              content: createHash('sha512').update(String(n)).digest('hex'),
            },
          };
        });
        await core.handle('records.batch', { appId: app.id, operations });
      }
    });
    const query = await measure('queryMs', () =>
      core.handle('records.list', {
        appId: app.id,
        entityId: 'items',
        search: 'Запись 99',
        sort: { field: 'title', direction: 'asc' },
        limit: 50,
      }),
    );
    assert.equal(query.total, 111);
    const path = join(root, 'fixture.everyapp');
    await measure('exportMs', () =>
      core.handle('packages.export', { appId: app.id, mode: 'data', path }),
    );
    const preview = await measure('importPreviewMs', () =>
      core.handle('packages.importPreview', { path }),
    );
    const imported = await measure('importCommitMs', () =>
      core.handle('packages.importCommit', { previewId: preview.previewId }),
    );
    assert.equal(
      (await core.handle('records.list', { appId: imported.app.id, entityId: 'items' })).total,
      10000,
    );
    console.log(
      'CORE_PERFORMANCE ' +
        JSON.stringify({
          node: process.version,
          platform: process.platform,
          arch: process.arch,
          records: 10000,
          packageBytes: statSync(path).size,
          ...timings,
          maxRssMiB: Math.round((process.resourceUsage().maxRSS / 1024) * 10) / 10,
        }),
    );
  } finally {
    core.close();
    rmSync(root, { recursive: true, force: true });
  }
});
