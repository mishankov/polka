import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { build } from 'esbuild';
import { PNG } from 'pngjs';
import { decodeBase64 } from '../src/services/base64';
import { DocumentService } from '../src/services/documents';
import { collectDocumentPaths } from '../src/services/documentFiles';
import { TransformJobService } from '../src/services/transformJobs';
import { runTransform, runPipeline, validatePipeline } from '../src/services/transforms';
import { validateRasterOperation } from '../src/renderer/src/rasterOperations';
let root: string, workerPath: string;
before(async () => {
  root = await mkdtemp(join(tmpdir(), 'everything-document-workflows-'));
  workerPath = join(root, 'transformWorker.cjs');
  await build({
    entryPoints: [resolve('src/main/transformWorker.ts')],
    bundle: true,
    platform: 'node',
    format: 'cjs',
    outfile: workerPath,
    logLevel: 'silent',
  });
});
after(async () => {
  await rm(root, { recursive: true, force: true });
});
function store() {
  const state = new Map();
  return {
    handle: async (method: string, p: any) =>
      method === 'state.get'
        ? structuredClone(state.get(p.key))
        : method === 'state.set'
          ? state.set(p.key, structuredClone(p.value))
          : { id: p.appId },
  };
}
async function wait(jobs: TransformJobService, id: string) {
  for (let n = 0; n < 300; n++) {
    const job = await jobs.handle('transforms.jobs.status', { appId: 'a', id, results: true });
    if (job.status !== 'running') return job;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw Error('Job did not finish');
}
test('folder selection walks nested files, skips hidden entries and links, deduplicates paths', async () => {
  const folder = join(root, 'folder');
  await mkdir(join(folder, 'nested'), { recursive: true });
  await writeFile(join(folder, 'a.txt'), 'a');
  await writeFile(join(folder, 'nested/b.txt'), 'b');
  await writeFile(join(folder, '.secret'), 'hidden');
  await symlink(join(folder, 'a.txt'), join(folder, 'link'));
  const result = await collectDocumentPaths([folder, join(folder, 'a.txt')]);
  assert.equal(result.files.length, 2);
  assert.equal(result.errors.length, 1);
  assert.match(result.errors[0].error, /ссылка/);
});
test('typed byte and structured transformations chain correctly and reject incompatible steps', () => {
  assert.deepEqual(
    runPipeline([{ operation: 'bytes.hex' }, { operation: 'hex.bytes' }], [0, 255, 17]).output,
    [0, 255, 17],
  );
  assert.equal(
    runPipeline([{ operation: 'json.parse' }, { operation: 'json.stringify' }], '{"n":2}').output,
    '{\n  "n": 2\n}',
  );
  assert.throws(
    () => validatePipeline([{ operation: 'base64.bytes' }, { operation: 'url.encode' }]),
    /Шаг 2/,
  );
  assert.throws(() => runTransform('hex.encode', [1]), /текст/);
  assert.throws(() => runTransform('text.encoding', [256]), /байтов/);
});
test('worker previews multiple documents without disk writes, exposes per-file errors and prevents stale batch apply', async () => {
  const storage = store(),
    documents = new DocumentService(storage);
  const aPath = join(root, 'first.json');
  await writeFile(aPath, '{"x":1}');
  const a = await documents.handle('docs.openPath', { appId: 'a', path: aPath });
  const b = await documents.handle('docs.create', {
    appId: 'a',
    name: 'broken.json',
    content: '{broken',
  });
  const jobs = new TransformJobService(workerPath, (m, p) =>
    m.startsWith('docs.') ? documents.handle(m, p) : storage.handle(m, p),
  );
  try {
    const job = await jobs.handle('transforms.jobs.start', {
      appId: 'a',
      documentIds: [a.id, b.id],
      steps: [{ operation: 'json.format' }],
    });
    const done = await wait(jobs, job.id);
    assert.equal(done.status, 'done');
    assert.equal(done.results.length, 2);
    assert.equal(done.results[0].output, '{\n  "x": 1\n}');
    assert.match(done.results[1].error, /Шаг 1/);
    assert.equal(await readFile(aPath, 'utf8'), '{"x":1}');
    await assert.rejects(
      jobs.handle('transforms.jobs.status', { appId: 'b', id: job.id }),
      /не найден/,
    );
    await documents.handle('docs.draft', {
      appId: 'a',
      id: a.id,
      revision: a.revision,
      content: 'newer',
    });
    await assert.rejects(
      documents.handle('docs.applyBatch', {
        appId: 'a',
        changes: [
          { id: b.id, revision: b.revision, content: 'should not apply' },
          { id: a.id, revision: a.revision, content: 'old preview' },
        ],
      }),
      /изменился/,
    );
    assert.equal((await documents.handle('docs.get', { appId: 'a', id: b.id })).content, '{broken');
  } finally {
    await jobs.close();
  }
});
test('large running transformations can be terminated without committing any changes', async () => {
  const jobs = new TransformJobService(workerPath, store().handle);
  try {
    const job = await jobs.handle('transforms.jobs.start', {
      appId: 'a',
      input: 'x'.repeat(1_000_000),
      steps: Array.from({ length: 64 }, (_, i) => ({
        operation: i % 2 ? 'base64.decode' : 'base64.encode',
      })),
    });
    const cancelled = await jobs.handle('transforms.jobs.cancel', { appId: 'a', id: job.id });
    assert.equal(cancelled.status, 'cancelled');
    assert.deepEqual(
      (await jobs.handle('transforms.jobs.status', { appId: 'a', id: job.id, results: true }))
        .results,
      [],
    );
  } finally {
    await jobs.close();
  }
});
test('batch draft changes preserve typed undo/redo and reopen retains dirty content', async () => {
  const documents = new DocumentService(store());
  const file = join(root, 'draft.txt');
  await writeFile(file, 'original');
  const d = await documents.handle('docs.openPath', { appId: 'a', path: file });
  await documents.handle('docs.applyBatch', {
    appId: 'a',
    changes: [{ id: d.id, revision: d.revision, content: '/w==', kind: 'binary' }],
  });
  const reopened = await documents.handle('docs.openPath', { appId: 'a', path: file });
  assert.equal(reopened.id, d.id);
  assert.equal(reopened.content, '/w==');
  const undo = await documents.handle('docs.revert', { appId: 'a', id: d.id });
  assert.equal(undo.kind, 'text');
  assert.equal(undo.content, 'original');
  const redo = await documents.handle('docs.redo', { appId: 'a', id: d.id });
  assert.equal(redo.kind, 'binary');
  assert.equal(redo.content, '/w==');
});
test('raster geometry refuses destructive out-of-bounds or excessive allocations', () => {
  validateRasterOperation({ type: 'crop', x: 1, y: 1, width: 9, height: 9 }, 10, 10);
  assert.throws(
    () => validateRasterOperation({ type: 'crop', x: 2, y: 2, width: 9, height: 9 }, 10, 10),
    /внутри/,
  );
  assert.throws(
    () => validateRasterOperation({ type: 'resize', width: 8192, height: 8192 }, 10, 10),
    /мегапикселей/,
  );
  assert.throws(
    () => validateRasterOperation({ type: 'resize', width: 0, height: 10 }, 10, 10),
    /Размер/,
  );
});

test('batch input is bounded before retaining all documents or expanding binary arrays', async () => {
  let reads = 0;
  const jobs = new TransformJobService(workerPath, async (method, p) => {
    if (method === 'apps.get') return { id: p.appId };
    reads++;
    return {
      id: p.id,
      name: p.id,
      revision: 1,
      kind: 'text',
      content: 'x'.repeat(17 * 1024 * 1024),
    };
  });
  try {
    await assert.rejects(
      jobs.handle('transforms.jobs.start', {
        appId: 'a',
        documentIds: Array.from({ length: 256 }, (_, i) => String(i)),
        steps: [{ operation: 'hex.encode' }],
      }),
      /32 МБ/,
    );
    assert.equal(reads, 2);
  } finally {
    await jobs.close();
  }
  const binary = new TransformJobService(workerPath, async (method, p) =>
    method === 'apps.get'
      ? { id: p.appId }
      : {
          id: p.id,
          name: p.id,
          revision: 1,
          kind: 'binary',
          content: Buffer.alloc(9 * 1024 * 1024).toString('base64'),
        },
  );
  try {
    await assert.rejects(
      binary.handle('transforms.jobs.start', {
        appId: 'a',
        documentIds: ['binary'],
        steps: [{ operation: 'bytes.hex' }],
      }),
      /32 МБ/,
    );
  } finally {
    await binary.close();
  }
});

function imageFixture() {
  const png = new PNG({ width: 3, height: 2 });
  png.data = Buffer.from([
    255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255, 0, 0, 0, 64, 255, 255, 255, 0,
  ]);
  return PNG.sync.write(png);
}
test('PNG image nodes compose a real decode/crop/rotate/flip/resize/encode chain with exact alpha pixels', () => {
  const output = runPipeline(
    [
      { operation: 'image.decodePng' },
      { operation: 'image.crop', options: { x: 1, y: 0, width: 2, height: 2 } },
      { operation: 'image.rotate', options: { angle: 90 } },
      { operation: 'image.flip', options: { axis: 'horizontal' } },
      { operation: 'image.resize', options: { width: 4, height: 4 } },
      { operation: 'image.encodePng' },
    ],
    [...imageFixture()],
  ).output as number[];
  const result = PNG.sync.read(Buffer.from(output));
  assert.deepEqual([result.width, result.height], [4, 4]);
  const pixel = (x: number, y: number) => [
    ...result.data.subarray((y * 4 + x) * 4, (y * 4 + x) * 4 + 4),
  ];
  assert.deepEqual(pixel(0, 0), [0, 255, 0, 255]);
  assert.deepEqual(pixel(3, 0), [0, 0, 0, 64]);
  assert.deepEqual(pixel(0, 3), [0, 0, 255, 255]);
  assert.deepEqual(pixel(3, 3), [255, 255, 255, 0]);
  const image = runTransform('image.decodePng', [...imageFixture()]).output;
  assert.throws(
    () => runTransform('image.crop', image, { x: 2, y: 0, width: 2, height: 2 }),
    /выходит за пределы/,
  );
  assert.throws(
    () => runTransform('image.resize', image, { width: 8192, height: 8192 }),
    /мегапикселей/,
  );
  assert.throws(() => runTransform('image.rotate', image, { angle: 45 }), /90, 180/);
  assert.throws(
    () => runPipeline([{ operation: 'image.rotate' }, { operation: 'json.format' }], image),
    /Шаг 2/,
  );
});
test('PNG decoder rejects dangerous dimensions and unsupported headers before pixel allocation', () => {
  const bomb = Buffer.from(imageFixture());
  bomb.writeUInt32BE(0x7fffffff, 16);
  assert.throws(() => runTransform('image.decodePng', [...bomb]), /мегапикселей/);
  const interlace = Buffer.from(imageFixture());
  interlace[28] = 1;
  assert.throws(() => runTransform('image.decodePng', [...interlace]), /чересстрочный/);
  const duplicate = Buffer.concat([imageFixture().subarray(0, 33), imageFixture().subarray(8)]);
  assert.throws(() => runTransform('image.decodePng', [...duplicate]), /повторный/);
  assert.throws(() => runTransform('image.decodePng', [1, 2, 3]), /корректный PNG/);
});
test('image document worker preview is visual PNG and draft apply remains revision checked', async () => {
  const storage = store(),
    documents = new DocumentService(storage);
  const source = `data:image/png;base64,${imageFixture().toString('base64')}`;
  const doc = await documents.handle('docs.create', {
    appId: 'a',
    name: 'fixture.png',
    kind: 'image',
    content: source,
  });
  const jobs = new TransformJobService(workerPath, (method, p) =>
    method.startsWith('docs.') ? documents.handle(method, p) : storage.handle(method, p),
  );
  try {
    const started = await jobs.handle('transforms.jobs.start', {
      appId: 'a',
      documentIds: [doc.id],
      steps: [
        { operation: 'image.rotate', options: { angle: 90 } },
        { operation: 'image.flip', options: { axis: 'vertical' } },
      ],
    });
    const done = await wait(jobs, started.id);
    assert.equal(done.status, 'done');
    const result = done.results[0];
    assert.equal(result.outputType, 'image');
    assert.equal(result.error, undefined);
    assert.deepEqual([result.output.width, result.output.height], [2, 3]);
    assert.equal((await documents.handle('docs.get', { appId: 'a', id: doc.id })).content, source);
    const change = {
      id: doc.id,
      revision: doc.revision,
      kind: 'image',
      content: result.output.dataUrl,
    };
    const [applied] = await documents.handle('docs.applyBatch', { appId: 'a', changes: [change] });
    assert.equal(applied.kind, 'image');
    assert.equal(applied.dirty, true);
    assert.equal(applied.content, result.output.dataUrl);
    await assert.rejects(
      documents.handle('docs.applyBatch', { appId: 'a', changes: [change] }),
      /изменился/,
    );
    assert.equal(
      (await documents.handle('docs.revert', { appId: 'a', id: doc.id })).content,
      source,
    );
  } finally {
    await jobs.close();
  }
});

test('valid multi-MiB Base64 decodes without regexp stack overflow and enforces padding/size', () => {
  const bytes = Buffer.alloc(4 * 1024 * 1024, 137),
    encoded = bytes.toString('base64');
  assert.deepEqual(decodeBase64(encoded, bytes.length), bytes);
  assert.throws(() => decodeBase64(encoded, bytes.length - 1), /слишком большой/);
  assert.throws(() => decodeBase64('a==='), /Base64/);
  assert.throws(() => decodeBase64('AAA'), /Base64/);
  assert.throws(() => decodeBase64('AA=A'), /Base64/);
});
