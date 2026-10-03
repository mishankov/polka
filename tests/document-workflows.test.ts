import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DocumentService } from '../src/services/documents';
import { collectDocumentPaths } from '../src/services/documentFiles';
import { validateRasterOperation } from '../src/renderer/src/rasterOperations';
let root: string;
before(async () => {
  root = await mkdtemp(join(tmpdir(), 'everything-document-workflows-'));
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
test('draft edits retain formatting through undo/redo and reopening preserves unsaved content', async () => {
  const documents = new DocumentService(store());
  const file = join(root, 'draft.txt');
  await writeFile(file, 'original');
  const d = await documents.handle('docs.openPath', { appId: 'a', path: file });
  await documents.handle('docs.draft', {
    appId: 'a',
    id: d.id,
    revision: d.revision,
    content: 'edited',
    encoding: 'windows-1251',
    lineEnding: 'CRLF',
  });
  const reopened = await documents.handle('docs.openPath', { appId: 'a', path: file });
  assert.equal(reopened.id, d.id);
  assert.equal(reopened.content, 'edited');
  assert.equal(await readFile(file, 'utf8'), 'original');
  await assert.rejects(
    documents.handle('docs.draft', {
      appId: 'a',
      id: d.id,
      revision: d.revision,
      content: 'stale',
    }),
    /изменён/,
  );
  const undo = await documents.handle('docs.revert', { appId: 'a', id: d.id });
  assert.equal(undo.content, 'original');
  assert.equal(undo.encoding, 'utf8');
  assert.equal(undo.lineEnding, 'LF');
  const redo = await documents.handle('docs.redo', { appId: 'a', id: d.id });
  assert.equal(redo.content, 'edited');
  assert.equal(redo.encoding, 'windows-1251');
  assert.equal(redo.lineEnding, 'CRLF');
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
