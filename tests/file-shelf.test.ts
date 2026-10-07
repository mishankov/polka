import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rename, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { FileShelf } from '../src/main/file-shelf';

test('references are deduplicated, selected together and never change originals', async () => {
  const root = await mkdtemp(join(tmpdir(), 'polka-file-test-'));
  try {
    const paths = [join(root, 'report.txt'), join(root, 'folder')];
    await writeFile(paths[0], 'report');
    await mkdir(paths[1]);
    const shelf = new FileShelf(async () => 'icon');
    await Promise.all([shelf.add(paths), shelf.add(paths)]);
    const items = shelf.snapshot().items;
    assert.equal(items.length, 2);
    assert.equal(items[1].directory, true);
    assert.deepEqual(shelf.drag(items.map((item) => item.id)), paths);
    await shelf.remove([items[0].id]);
    await shelf.clear();
    assert.equal(await readFile(paths[0], 'utf8'), 'report');
    assert.equal(shelf.snapshot().items.length, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('moved, deleted and replaced files cannot be transferred as the old reference', async () => {
  const root = await mkdtemp(join(tmpdir(), 'polka-file-test-'));
  try {
    const a = join(root, 'a.txt'),
      b = join(root, 'b.txt');
    await writeFile(a, 'original');
    await writeFile(b, 'original');
    const shelf = new FileShelf(async () => '');
    await shelf.add([a, b]);
    const items = shelf.snapshot().items;
    await rename(a, join(root, 'moved.txt'));
    assert.throws(() => shelf.drag(items.map((item) => item.id)), /недоступен/);
    await writeFile(a, 'replacement');
    await rm(b);
    assert.deepEqual(
      (await shelf.refresh()).items.map((item) => item.available),
      [false, false],
    );
    await shelf.clear();
    assert.equal(await readFile(a, 'utf8'), 'replacement');
    assert.equal(await readFile(join(root, 'moved.txt'), 'utf8'), 'original');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('partial inaccessible drops remain actionable and clear resets their error', async () => {
  const root = await mkdtemp(join(tmpdir(), 'polka-file-test-'));
  try {
    const file = join(root, 'ok.txt');
    await writeFile(file, 'ok');
    const shelf = new FileShelf(async () => {
      throw Error('No icon');
    });
    const state = await shelf.add([join(root, 'missing'), file]);
    assert.equal(state.items.length, 1);
    assert.equal(state.items[0].icon, '');
    assert.match(state.error, /недоступны/);
    assert.throws(() => shelf.drag(['untrusted']), /Выберите/);
    assert.equal((await shelf.clear()).error, '');
    await assert.rejects(shelf.add(['relative.txt']), /локальный/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
