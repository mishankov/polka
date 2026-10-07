import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ClipboardHistory } from '../src/main/clipboard-history';
const codec = {
  encode: (text: string) => Buffer.from(text),
  decode: (bytes: Buffer) => bytes.toString(),
};

test('timed pause resumes at the boundary, after sleep and restart; early and persistent pause persist', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'privacy-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  let now = 1000000;
  const histories: ClipboardHistory[] = [];
  const make = async () => {
    const history = new ClipboardHistory(
      join(root, 'history'),
      codec,
      () => {},
      () => now,
    );
    histories.push(history);
    await history.initialize();
    return history;
  };
  t.after(() => histories.forEach((history) => history.stop()));
  let history = await make();
  await history.preferences({ paused: true, pauseUntil: now + 900000 });
  await history.add('text', 'ignored', 'ignored');
  now += 899999;
  history.stop();
  history = await make();
  assert.equal(history.getPreferences().paused, true);
  await history.add('text', 'still ignored', 'still ignored');
  assert.equal(history.snapshot().clips.length, 0);
  now++;
  assert.equal(history.getPreferences().paused, false);
  await history.resumeExpiredPause();
  assert.equal(history.getPreferences().pauseUntil, undefined);
  await history.add('text', 'resumed', 'resumed');
  assert.equal(history.snapshot().clips.length, 1);
  await history.preferences({ paused: true, pauseUntil: now + 900000 });
  history.stop();
  now += 900001;
  history = await make();
  assert.equal(history.getPreferences().paused, false);
  await history.preferences({ paused: true, pauseUntil: now + 900000 });
  await history.preferences({ paused: false });
  assert.equal(history.getPreferences().pauseUntil, undefined);
  await history.preferences({ paused: true, pauseUntil: now + 900000 });
  await history.preferences({ paused: true });
  now += 1000000;
  history.stop();
  history = await make();
  assert.equal(history.getPreferences().paused, true);
  assert.equal(history.getPreferences().pauseUntil, undefined);
});

test('deadline timer publishes automatic resume without reading state', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'privacy-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  let now = 1000,
    changes = 0;
  const history = new ClipboardHistory(
    join(root, 'history'),
    codec,
    () => changes++,
    () => now,
  );
  t.after(() => history.stop());
  await history.initialize();
  t.mock.timers.enable({ apis: ['setTimeout'] });
  await history.preferences({ paused: true, pauseUntil: now + 900000 });
  const before = changes;
  now += 900000;
  t.mock.timers.tick(900000);
  await history.flush();
  assert.equal(changes, before + 1);
  assert.equal(JSON.parse(await readFile(join(root, 'history'), 'utf8')).preferences.paused, false);
});

test('legacy preferences migrate and exclusions persist; excluded and unknown captures are skipped', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'privacy-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const path = join(root, 'history');
  await writeFile(
    path,
    JSON.stringify({
      version: 1,
      preferences: {
        paused: false,
        pasteOnSelect: true,
        hoverEnabled: true,
        retentionDays: 7,
        accelerator: '',
      },
      clips: [],
    }),
  );
  const history = new ClipboardHistory(path, codec, () => {});
  await history.initialize();
  assert.deepEqual(history.getPreferences().excludedApps, []);
  await history.preferences({
    excludedApps: [{ bundleId: 'com.example.private', name: 'Private app' }],
  });
  await history.add('text', 'secret', 'secret', 'com.example.private');
  await history.add('text', 'unknown', 'unknown');
  await history.add('text', 'allowed', 'allowed', 'com.example.allowed');
  assert.deepEqual(
    history.snapshot().clips.map((clip) => clip.content),
    ['allowed'],
  );
  const restarted = new ClipboardHistory(path, codec, () => {});
  await restarted.initialize();
  assert.deepEqual(restarted.getPreferences().excludedApps, history.getPreferences().excludedApps);
  assert.equal(JSON.parse(await readFile(path, 'utf8')).version, 2);
  assert.equal(history.manifest().version, 1);
});

test('local-only blocks metadata/content and incoming updates, preserves existing peers, and re-sharing converges', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'privacy-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const make = async (name: string) => {
    const h = new ClipboardHistory(join(root, name), codec, () => {});
    await h.initialize();
    return h;
  };
  const a = await make('a'),
    b = await make('b'),
    c = await make('c');
  const exchange = async (from: ClipboardHistory, to: ClipboardHistory) => {
    for (const id of await to.mergeManifest(from.manifest())) {
      const item = from.transfer(id);
      if (item) await to.receive(item, 'Other Mac');
    }
  };
  await a.add('text', 'shared earlier', 'shared earlier');
  const clip = a.snapshot().clips[0];
  const prior = a.transfer(clip.id)!;
  await exchange(a, b);
  await a.localOnly(clip.id, true);
  assert.equal(a.manifest().entries[clip.id], undefined);
  assert.deepEqual(a.manifest().available, []);
  assert.equal(a.transfer(clip.id), undefined);
  await exchange(a, c);
  assert.equal(c.snapshot().clips.length, 0);
  await exchange(a, b);
  assert.equal(b.snapshot().clips.length, 1);
  await b.pin(clip.id, true);
  await exchange(b, a);
  assert.equal(a.snapshot().clips[0].pinned, false);
  await a.receive(prior, 'Other Mac');
  await b.clear();
  await exchange(b, a);
  assert.equal(a.snapshot().clips[0].localOnly, true);
  await a.add('text', clip.content, clip.preview);
  assert.equal(a.transfer(clip.id), undefined);
  const restarted = await make('a');
  assert.equal(restarted.snapshot().clips[0].localOnly, true);
  await restarted.localOnly(clip.id, false);
  await exchange(restarted, b);
  await exchange(restarted, c);
  assert.equal(b.snapshot().clips.length, 1);
  assert.equal(c.snapshot().clips.length, 1);
  await restarted.localOnly(clip.id, true);
  await restarted.remove(clip.id);
  await exchange(c, restarted);
  assert.equal(restarted.snapshot().clips.length, 0);
});
