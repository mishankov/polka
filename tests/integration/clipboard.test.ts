import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  ClipboardHistory,
  excludedClipboardType,
  MAX_HISTORY_ITEMS,
  MAX_SNIPPET_ITEMS,
  MAX_CLIP_BYTES,
  clipboardContentType,
} from '../../src/main/clipboard-history';
import { ClipboardHover, shelfGeometry, contains } from '../../src/main/clipboard-hover';
import { clipboardResults } from '../../src/shared/clipboard';
const codec = {
  encode: (value: string) => Buffer.from(value),
  decode: (value: Buffer) => value.toString(),
};

test('clipboard history survives restart, deduplicates, preserves pins and applies retention', async () => {
  const root = await mkdtemp(join(tmpdir(), 'clipboard-history-test-'));
  let now = 1000000000;
  try {
    const path = join(root, 'history');
    const history = new ClipboardHistory(
      path,
      codec,
      () => {},
      () => now,
    );
    await history.initialize();
    await history.add('text', 'First note', 'First note');
    const id = history.snapshot().clips[0].id;
    await history.pin(id, true);
    now++;
    await history.add('text', 'Second note', 'Second note');
    now++;
    await history.add('text', 'First note', 'First note');
    assert.equal(history.snapshot().clips.length, 2);
    assert.equal(history.snapshot().clips[0].pinned, true);
    assert.equal(clipboardResults(history.snapshot().clips, 'second NOTE').length, 1);
    await history.preferences({ paused: true, retentionDays: 1 });
    await history.add('text', 'Ignored', 'Ignored');
    assert.equal(history.snapshot().clips.length, 2);
    now += 2 * 86400000;
    const restarted = new ClipboardHistory(
      path,
      codec,
      () => {},
      () => now,
    );
    await restarted.initialize();
    assert.deepEqual(
      restarted.snapshot().clips.map((clip) => clip.id),
      [id],
    );
    assert.equal(restarted.getPreferences().paused, true);
    await restarted.clear();
    assert.equal(JSON.parse(await readFile(path, 'utf8')).clips.length, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('earlier mixed snippet files migrate atomically without changing identity, revisions or pin status', async () => {
  const root = await mkdtemp(join(tmpdir(), 'clipboard-snippet-migration-'));
  try {
    const path = join(root, 'history');
    const history = new ClipboardHistory(path, codec, () => {});
    await history.initialize();
    await history.add('text', 'Source text', 'Source text');
    const source = history.snapshot().clips[0];
    const id = await history.edit(source.id, 'Saved snippet', 'Legacy name');
    await history.pin(id, false);
    const saved = JSON.parse(await readFile(path, 'utf8'));
    const entry = structuredClone(saved.sync.entries[id]);
    saved.clips.push(...saved.snippets);
    delete saved.snippets;
    await writeFile(path, JSON.stringify(saved));
    const beforeMigration = await readFile(path);
    const blocked = new ClipboardHistory(
      path,
      {
        ...codec,
        encode: () => {
          throw Error('Synthetic migration encryption failure');
        },
      },
      () => {},
    );
    await assert.rejects(blocked.initialize(), /зашифровать/);
    assert.equal(blocked.storage.ready, false);
    assert.deepEqual(await readFile(path), beforeMigration);
    assert.deepEqual(blocked.snapshot().clips, [source]);
    assert.equal(
      blocked.snapshot().snippets[0].id,
      id,
      'failed migration remains readable in the correct collection',
    );
    const restarted = new ClipboardHistory(path, codec, () => {});
    await restarted.initialize();
    assert.deepEqual(restarted.snapshot().clips, [source]);
    assert.equal(restarted.snapshot().snippets[0].id, id);
    assert.equal(restarted.snapshot().snippets[0].name, 'Legacy name');
    assert.equal(restarted.snapshot().snippets[0].pinned, false);
    const migrated = JSON.parse(await readFile(path, 'utf8'));
    assert.deepEqual(migrated.sync.entries[id], entry);
    assert.equal(migrated.clips.length, 1);
    assert.equal(migrated.snippets.length, 1);
    await restarted.clear();
    const again = new ClipboardHistory(path, codec, () => {});
    await again.initialize();
    assert.equal(again.snapshot().clips.length, 0);
    assert.equal(again.snapshot().snippets[0].id, id);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('snippet limits reject new saves without eviction and clipboard capacity stays independent', async () => {
  const root = await mkdtemp(join(tmpdir(), 'clipboard-snippet-capacity-'));
  try {
    const path = join(root, 'history');
    const history = new ClipboardHistory(path, codec, () => {});
    await history.initialize();
    await history.createSnippet('Saved text', 'Saved');
    const saved = JSON.parse(await readFile(path, 'utf8'));
    const template = saved.snippets[0];
    const entry = saved.sync.entries[template.id];
    saved.snippets = Array.from({ length: MAX_SNIPPET_ITEMS }, (_, i) => ({
      ...template,
      id: i.toString(16).padStart(64, '0'),
      pinned: false,
    }));
    saved.sync.entries = Object.fromEntries(
      saved.snippets.map((clip: { id: string }) => [
        clip.id,
        { ...entry, pin: { ...entry.pin, value: false } },
      ]),
    );
    await writeFile(path, JSON.stringify(saved));
    const restarted = new ClipboardHistory(path, codec, () => {});
    await restarted.initialize();
    await assert.rejects(restarted.createSnippet('One too many', 'Overflow'), /200/);
    for (let i = 0; i <= MAX_HISTORY_ITEMS; i++)
      await restarted.add('text', `Capture ${i}`, `Capture ${i}`);
    assert.equal(restarted.snapshot().clips.length, MAX_HISTORY_ITEMS);
    assert.equal(restarted.snapshot().snippets.length, MAX_SNIPPET_ITEMS);
    assert.equal(restarted.manifest().available.length, MAX_HISTORY_ITEMS + MAX_SNIPPET_ITEMS);
    assert.equal(restarted.manifest(false).available.length, MAX_HISTORY_ITEMS);
    await restarted.clear();
    assert.equal(restarted.snapshot().snippets.length, MAX_SNIPPET_ITEMS);
    assert.equal(restarted.storage.ready, true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('serialized concurrent writes and clear never resurrect removed clips; history stays bounded', async () => {
  const root = await mkdtemp(join(tmpdir(), 'clipboard-history-test-'));
  let now = 0;
  try {
    const history = new ClipboardHistory(
      join(root, 'history'),
      codec,
      () => {},
      () => ++now,
    );
    await history.initialize();
    await Promise.all([
      history.add('text', 'A', 'A'),
      history.add('text', 'B', 'B'),
      history.clear(),
    ]);
    assert.equal(history.snapshot().clips.length, 0);
    await Promise.all(
      Array.from({ length: MAX_HISTORY_ITEMS + 5 }, (_, index) =>
        history.add('text', String(index), String(index)),
      ),
    );
    assert.equal(history.snapshot().clips.length, MAX_HISTORY_ITEMS);
    assert(!history.snapshot().clips.some((clip) => clip.content === '0'));
    const before = history.snapshot();
    await assert.rejects(history.preferences({ retentionDays: 3 as any }));
    assert.deepEqual(history.snapshot(), before);
    await history.clear();
    await history.add('image', 'a'.repeat(MAX_CLIP_BYTES + 1), '');
    assert.equal(history.snapshot().clips.length, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('failed persistence preserves committed history and closes writes until restart', async () => {
  const root = await mkdtemp(join(tmpdir(), 'clipboard-history-test-'));
  const path = join(root, 'history');
  const original = Object.assign(new Error('locked'), { code: 'EACCES' });
  let fail = false;
  try {
    const history = new ClipboardHistory(
      path,
      {
        ...codec,
        encode: (value) => {
          if (fail) throw original;
          return codec.encode(value);
        },
      },
      () => {},
    );
    await history.initialize();
    await history.add('text', 'Committed', 'Committed');
    const before = history.snapshot();
    const bytes = await readFile(path);
    fail = true;
    const queued = await Promise.allSettled([
      history.add('text', 'Uncommitted', 'Uncommitted'),
      history.clear(),
    ]);
    assert(
      queued.every((result) => result.status === 'rejected' && result.reason.cause === original),
    );
    assert.deepEqual(history.snapshot(), before);
    assert.equal(history.storage.failureReason, original);
    assert.equal(history.storage.state().diagnostic?.stage, 'encrypt');
    assert.equal(history.storage.state().diagnostic?.code, 'EACCES');
    fail = false;
    await history.prune();
    await assert.rejects(history.preferences({ paused: true }), { cause: original });
    await assert.rejects(history.add('text', 'Still blocked', 'Still blocked'), {
      cause: original,
    });
    await history.flush();
    assert.deepEqual(await readFile(path), bytes);
    const restarted = new ClipboardHistory(path, codec, () => {});
    await restarted.initialize();
    assert.deepEqual(restarted.snapshot(), before);
    await restarted.add('text', 'After restart', 'After restart');
    assert.equal(restarted.snapshot().clips.length, 2);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('sensitive, temporary and generated clipboard formats are excluded', () => {
  for (const marker of [
    'org.nspasteboard.ConcealedType',
    'org.nspasteboard.TransientType',
    'org.nspasteboard.AutoGeneratedType',
  ])
    assert(
      excludedClipboardType(['text/plain', `electron application/osclipboard;format="${marker}"`]),
    );
  assert.equal(excludedClipboardType(['text/plain', 'image/png']), false);
});

test('notch and external display geometry uses display offsets and provides a continuous corridor', () => {
  const bounds = { x: -1512, y: -982, width: 1512, height: 982 };
  const geometry = shelfGeometry(bounds, { id: 1, x: 660, width: 192, height: 32 });
  assert.equal(geometry.target.x, -852);
  assert.equal(geometry.panel.y, -982);
  assert.equal(geometry.topInset, 32);
  assert.equal(geometry.panel.height, 542);
  assert(contains(geometry.corridor, { x: -750, y: -955 }));
  const external = shelfGeometry({ x: 1512, y: 0, width: 1920, height: 1080 });
  assert.equal(external.target.height, 3);
  assert.equal(external.target.x, 2424);
  assert.equal(external.panel.y, 0);
  assert.equal(external.topInset, 0);
  assert.equal(shelfGeometry({ x: 0, y: 0, width: 400, height: 300 }).panel.width, 400);
});

test('hover requires dwell, gives transit grace and respects explicit dismissal', () => {
  const hover = new ClipboardHover();
  assert.equal(hover.step(0, true, true, false), undefined);
  assert.equal(hover.step(349, true, true, false), undefined);
  assert.equal(hover.step(350, true, true, false), 'show');
  assert.equal(hover.step(400, false, true, true), undefined);
  assert.equal(hover.step(450, false, false, true), undefined);
  assert.equal(hover.step(599, false, false, true), undefined);
  assert.equal(hover.step(600, false, false, true), 'hide');
  hover.dismiss();
  assert.equal(hover.step(1000, true, true, false), undefined);
  assert.equal(hover.step(2000, true, true, false), undefined);
  hover.step(2100, false, false, false);
  hover.step(2200, true, true, false);
  assert.equal(hover.step(2550, true, true, false), 'show');
});

test('image representations take priority over companion file references and text', () => {
  const file = 'electron application/osclipboard;format="public.file-url"';
  assert.equal(clipboardContentType(['text/plain', file]), undefined);
  assert.equal(clipboardContentType(['image/png', file, 'text/plain']), 'image/png');
  assert.equal(clipboardContentType(['image/tiff', file]), 'image/tiff');
  assert.equal(clipboardContentType(['image/jpeg']), 'image/jpeg');
  const rawPng = 'electron application/osclipboard;format="Apple PNG pasteboard type"';
  assert.equal(clipboardContentType(['text/uri-list', file, rawPng]), rawPng);
  assert.equal(clipboardContentType(['text/plain']), 'text/plain');
  assert.equal(clipboardContentType(['application/octet-stream']), undefined);
  assert(excludedClipboardType(['image/png', 'org.nspasteboard.ConcealedType']));
});

test('existing history gains paste preference without losing clips or prior settings', async () => {
  const root = await mkdtemp(join(tmpdir(), 'clipboard-migrate-'));
  try {
    const path = join(root, 'history');
    const history = new ClipboardHistory(path, codec, () => {});
    await history.initialize();
    await history.add('text', 'Preserved clip', 'Preserved clip');
    const saved = JSON.parse(await readFile(path, 'utf8'));
    delete saved.preferences.pasteOnSelect;
    saved.preferences.hoverEnabled = false;
    await writeFile(path, JSON.stringify(saved));
    const restored = new ClipboardHistory(path, codec, () => {});
    await restored.initialize();
    assert.equal(restored.getPreferences().pasteOnSelect, true);
    assert.equal(restored.getPreferences().hoverEnabled, false);
    assert.equal(restored.snapshot().clips[0].content, 'Preserved clip');
    await restored.preferences({ pasteOnSelect: false });
    const again = new ClipboardHistory(path, codec, () => {});
    await again.initialize();
    assert.equal(again.getPreferences().pasteOnSelect, false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

for (const stage of ['decrypt', 'parse'] as const) {
  test(`${stage} failure retains its original cause and preserves unreadable bytes through rejected mutations`, async () => {
    const root = await mkdtemp(join(tmpdir(), 'clipboard-unreadable-'));
    const path = join(root, 'history');
    const bytes = Buffer.from(stage === 'parse' ? '{private clipboard input' : 'encrypted bytes');
    const original = Object.assign(new Error('key unavailable'), { code: 'ENOENT' });
    try {
      await writeFile(path, bytes);
      const history = new ClipboardHistory(
        path,
        {
          ...codec,
          decode: (data) => {
            if (stage === 'decrypt') throw original;
            return data.toString();
          },
        },
        () => {},
      );
      await assert.rejects(history.initialize());
      const rootCause = history.storage.failureReason;
      if (stage === 'decrypt') assert.equal(rootCause, original);
      assert.equal(history.storage.state().diagnostic?.stage, stage);
      assert.equal(history.preferencesAvailable, false);
      assert(!JSON.stringify(history.storage.state()).includes('private clipboard input'));
      await assert.rejects(history.clear(), { cause: rootCause });
      await assert.rejects(history.persistIdentity(), { cause: rootCause });
      await assert.rejects(history.preferences({ paused: false }), { cause: rootCause });
      await assert.rejects(history.initialize(), { cause: rootCause });
      await history.prune();
      await history.flush();
      assert.deepEqual(await readFile(path), bytes);
      assert.equal(history.storage.failureReason, rootCause);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
}

test('a filesystem write failure retains committed bytes and disables later writes', async () => {
  const root = await mkdtemp(join(tmpdir(), 'clipboard-write-failure-'));
  const path = join(root, 'history');
  try {
    const history = new ClipboardHistory(path, codec, () => {});
    await history.initialize();
    await history.add('text', 'Committed', 'Committed');
    const before = history.snapshot();
    const bytes = await readFile(path);
    await mkdir(path + '.tmp');
    await assert.rejects(history.add('text', 'Not committed', 'Not committed'));
    assert.equal(history.storage.state().diagnostic?.stage, 'write');
    const original = history.storage.failureReason;
    await assert.rejects(history.clear(), { cause: original });
    assert.deepEqual(history.snapshot(), before);
    assert.deepEqual(await readFile(path), bytes);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('snippets retain independent identity, optional names, pins, duplicates and search after restart', async () => {
  const root = await mkdtemp(join(tmpdir(), 'clipboard-snippets-'));
  let now = 1000000000;
  try {
    const path = join(root, 'history');
    const history = new ClipboardHistory(
      path,
      codec,
      () => {},
      () => now,
    );
    await history.initialize();
    await history.add('text', 'Original address', 'Original address');
    const original = history.snapshot().clips[0];
    await history.pin(original.id, true);
    const id = await history.edit(original.id, '123 Example Street', ' Delivery address ');
    assert.notEqual(id, original.id);
    assert.equal(history.snapshot().snippets[0].pinned, true);
    assert.equal(history.snapshot().snippets[0].name, 'Delivery address');
    assert.equal(history.snapshot().clips[0].content, 'Original address');
    assert.equal(history.snapshot().clips[0].pinned, true);
    await history.add('text', '123 Example Street', '123 Example Street');
    assert.equal(
      history.snapshot().clips.length,
      2,
      'captures have their own content-hash identity',
    );
    assert.equal(history.snapshot().snippets.length, 1);
    await history.add('text', 'Other saved text', 'Other saved text');
    const other = history.snapshot().clips.find((clip) => clip.content === 'Other saved text')!;
    const otherId = await history.edit(other.id, '123 Example Street', 'Billing address');
    assert.notEqual(id, otherId, 'equal text keeps distinct snippets and names');
    await history.pin(id, false);
    assert.equal(await history.edit(id, '456 Example Street', ''), id);
    const edited = history.snapshot().snippets.find((clip) => clip.id === id)!;
    assert.equal(edited.pinned, false, 'edits do not repin an existing snippet');
    assert.equal(edited.name, undefined);
    assert.equal(edited.preview, edited.content);
    await history.add('text', 'Existing ordinary', 'Existing ordinary');
    const ordinary = history.snapshot().clips.find((clip) => clip.content === 'Existing ordinary')!;
    await history.edit(id, 'Existing ordinary', '');
    assert.equal(
      history.snapshot().clips.filter((clip) => clip.content === 'Existing ordinary').length,
      1,
    );
    assert.equal(
      history.snapshot().snippets.filter((clip) => clip.content === 'Existing ordinary').length,
      1,
    );
    assert(history.snapshot().clips.some((clip) => clip.id === ordinary.id && !clip.snippet));
    assert.equal(clipboardResults(history.snapshot().snippets, 'billing EXAMPLE')[0].id, otherId);
    assert.equal(clipboardResults(history.snapshot().clips, 'billing').length, 0);
    await assert.rejects(history.edit(id, '', 'Empty'));
    await assert.rejects(history.edit(id, 'text', 'x'.repeat(121)));
    await assert.rejects(history.edit(id, 'я'.repeat(1024 * 1024), 'Too large'), /1 МБ/);
    await assert.rejects(history.edit(id, 'text', 'Stale', { content: 'old text' }), /изменился/);
    await history.add('image', 'pixels', 'thumbnail');
    const image = history.snapshot().clips.find((clip) => clip.kind === 'image')!;
    await history.pin(image.id, true);
    await assert.rejects(history.edit(image.id, 'text', 'Image'));
    const restarted = new ClipboardHistory(
      path,
      codec,
      () => {},
      () => now,
    );
    await restarted.initialize();
    assert.deepEqual(restarted.snapshot(), history.snapshot());
    assert.equal(clipboardResults(restarted.snapshot().snippets, 'billing')[0].id, otherId);
    now += 31 * 86400000;
    await restarted.prune();
    assert.deepEqual(
      new Set(restarted.snapshot().clips.map((clip) => clip.id)),
      new Set([original.id, image.id]),
    );
    assert.deepEqual(
      new Set(restarted.snapshot().snippets.map((clip) => clip.id)),
      new Set([id, otherId]),
      'snippets do not expire with clipboard retention, including migrated unpinned ones',
    );
    await restarted.clear();
    assert.equal(restarted.snapshot().clips.length, 0);
    assert.equal(restarted.snapshot().snippets.length, 2);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('standalone snippets can be created while capture is paused without a source entry', async () => {
  const root = await mkdtemp(join(tmpdir(), 'clipboard-snippet-create-'));
  try {
    const path = join(root, 'history');
    const history = new ClipboardHistory(path, codec, () => {});
    await history.initialize();
    await history.preferences({ paused: true });
    const id = await history.createSnippet('Reusable reply', ' Reply ');
    const clip = history.snapshot().snippets[0];
    assert.equal(clip.id, id);
    assert.equal(clip.name, 'Reply');
    assert.equal(clip.content, 'Reusable reply');
    assert.equal(clip.pinned, true);
    assert.equal(clip.snippet, true);
    assert.equal(
      Object.keys(history.manifest().entries).length,
      1,
      'creation has no temporary capture identity',
    );
    const secondId = await history.createSnippet('Reusable reply', 'Second reply');
    assert.notEqual(id, secondId);
    await assert.rejects(history.createSnippet('', 'Empty'));
    assert.equal(history.snapshot().snippets.length, 2);
    assert.equal(history.snapshot().clips.length, 0);
    const restarted = new ClipboardHistory(path, codec, () => {});
    await restarted.initialize();
    assert.deepEqual(restarted.snapshot(), history.snapshot());
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
