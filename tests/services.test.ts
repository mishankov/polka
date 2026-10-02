import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runTransform, runPipeline } from '../src/services/transforms';
import { compileExtension, runHandler, buildComponent } from '../src/extensions/host';
import { DocumentService } from '../src/services/documents';
test('Transforms round trip Unicode and distinguish binary', () => {
  const input = 'Привет 🌍';
  assert.equal(
    runTransform('base64.decode', runTransform('base64.encode', input).output).output,
    input,
  );
  assert.equal(runTransform('hex.decode', runTransform('hex.encode', input).output).output, input);
  assert.deepEqual(runTransform('base64.bytes', '/wA=').output, [255, 0]);
  assert.throws(() => runTransform('base64.decode', '/wA='));
  assert.throws(() => runTransform('base64.decode', '%%%'));
  assert.throws(() => runTransform('hex.decode', '0g'));
  assert.equal(
    runPipeline([{ operation: 'url.encode' }, { operation: 'url.decode' }], input).output,
    input,
  );
});
test('XML parser rejects entities and malformed input', () => {
  assert.throws(() =>
    runTransform('xml.json', '<!DOCTYPE x [<!ENTITY a SYSTEM "file:///etc/passwd">]><x>&a;</x>'),
  );
  assert.throws(() => runTransform('xml.format', '<a></b>'));
  assert.equal(
    JSON.parse(runTransform('xml.json', '<x n="2">ok</x>').output as string).x['@_n'],
    '2',
  );
});
test('Extension boundary: no Node, filesystem, process, network or host objects', async () => {
  const code = await compileExtension(
    'export default input => ({value:input, node:typeof process, nodeRequire:typeof require, fetch:typeof fetch})',
    'handler',
  );
  assert.deepEqual(
    await runHandler(code, { x: 1 }, async () => {
      throw Error('unexpected');
    }),
    { value: { x: 1 }, node: 'undefined', nodeRequire: 'undefined', fetch: 'undefined' },
  );
  await assert.rejects(
    compileExtension(
      'import fs from "node:fs";export default ()=>fs.readFileSync("/etc/passwd")',
      'handler',
    ),
  );
  const loop = await compileExtension('export default ()=>{while(true){}}', 'handler');
  await assert.rejects(
    runHandler(loop, null, async () => null),
    /interrupt/i,
  );
  const request = await compileExtension(
    'export default ()=>({operations:[{method:"state.get",params:{}}]})',
    'handler',
  );
  await assert.rejects(
    runHandler(request, null, async () => {
      throw Error('denied');
    }),
    /denied/,
  );
  const component = await buildComponent(
    'export default function(){return <div>Работает</div>}',
    {},
  );
  assert.match(component.html, /connect-src 'none'/);
});
test('Document drafts recover and external writes require explicit conflict resolution', async () => {
  const root = await mkdtemp(join(tmpdir(), 'everything-doc-'));
  const state = new Map();
  const store = {
    handle: async (method: string, p: any) =>
      method === 'state.get'
        ? state.get(p.key)
        : method === 'state.set'
          ? state.set(p.key, p.value)
          : { id: p.appId },
  };
  try {
    const path = join(root, 'test.txt');
    await writeFile(path, 'original');
    const docs = new DocumentService(store);
    const d = await docs.handle('docs.openPath', { appId: 'a', path });
    await docs.handle('docs.draft', { appId: 'a', id: d.id, content: 'draft', revision: 1 });
    const recovered = new DocumentService(store);
    assert.equal((await recovered.handle('docs.get', { appId: 'a', id: d.id })).content, 'draft');
    await writeFile(path, 'external');
    await assert.rejects(recovered.handle('docs.savePath', { appId: 'a', id: d.id }), /изменён/);
    assert.equal(await readFile(path, 'utf8'), 'external');
    await recovered.handle('docs.savePath', { appId: 'a', id: d.id, force: true });
    assert.equal(await readFile(path, 'utf8'), 'draft');
    await assert.rejects(docs.handle('docs.get', { appId: 'b', id: d.id }), /не найден/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
