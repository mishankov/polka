import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MacShortcuts, parseShortcutList, shortcutRunResult } from '../src/main/macos-shortcuts';
import { shelfSearch } from '../src/shared/shelf-search';
import { shelfMethodAllowed } from '../src/shared/features';
const id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const second = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
function fixture(saved: unknown = null) {
  let stored = saved;
  let catalog = [
    { id, name: 'Подготовить встречу' },
    { id: second, name: 'Resize Images' },
  ];
  let listError = false;
  let saveError = false;
  let runs = 0;
  let finish: (() => void) | undefined;
  let hold = false;
  let outcome: 'completed' | 'cancelled' | 'failed' = 'completed';
  const events: unknown[] = [];
  const service = new MacShortcuts({
    read: async () => stored,
    save: async (value) => {
      if (saveError) throw Error('Disk full');
      stored = structuredClone(value);
    },
    list: async () => {
      if (listError) throw Error('Unavailable');
      return catalog;
    },
    run: async () => {
      runs++;
      if (hold)
        await new Promise<void>((done) => {
          finish = done;
        });
      return { status: outcome, message: outcome === 'failed' ? 'Permission denied' : undefined };
    },
    changed: (state) => events.push(state),
  });
  return {
    service,
    events,
    get stored() {
      return stored;
    },
    get runs() {
      return runs;
    },
    rename: () => {
      catalog = [{ id, name: 'Meeting Preparation' }];
    },
    remove: () => {
      catalog = [];
    },
    failList: () => {
      listError = true;
    },
    failSave: () => {
      saveError = true;
    },
    hold: () => {
      hold = true;
    },
    finish: () => finish?.(),
    outcome: (value: typeof outcome) => {
      outcome = value;
    },
  };
}
test('parse identifiers separately from names, including duplicate names and punctuation', () => {
  assert.deepEqual(
    parseShortcutList(
      `Name (with parentheses) (${id.toUpperCase()})\nName (with parentheses) (${second})\n`,
    ),
    [
      { id, name: 'Name (with parentheses)' },
      { id: second, name: 'Name (with parentheses)' },
    ],
  );
  assert.deepEqual(parseShortcutList(''), []);
  assert.throws(() => parseShortcutList('Unsupported listing'));
});
test('choose locally, persist by identifier, refresh renamed and missing selections', async () => {
  const f = fixture();
  await f.service.state(true, true);
  await f.service.select(id, true);
  assert.deepEqual(f.stored, [{ id, name: 'Подготовить встречу' }]);
  f.rename();
  const renamed = await f.service.state(true);
  assert.equal(renamed.shortcuts[0].name, 'Meeting Preparation');
  assert(renamed.shortcuts[0].selected);
  const restarted = fixture(f.stored);
  assert.equal((await restarted.service.state()).shortcuts[0].name, 'Meeting Preparation');
  f.remove();
  const missing = await f.service.state(true);
  assert.equal(missing.shortcuts[0].availability, 'missing');
  assert.equal((await f.service.run(id)).run?.status, 'failed');
  assert.equal(f.runs, 0);
  await f.service.select(id, false);
  assert.deepEqual(f.stored, []);
});
test('catalog failure preserves choice, prevents stale execution, and permits deselection', async () => {
  const f = fixture([{ id, name: 'Saved' }]);
  await f.service.state(true);
  f.failList();
  assert.equal((await f.service.state(true)).shortcuts[0].availability, 'unknown');
  assert.equal((await f.service.run(id)).run?.status, 'failed');
  assert.equal(f.runs, 0);
  await f.service.select(id, false);
  assert.deepEqual(f.stored, []);
});
test('save failures and malformed settings do not silently discard selections', async () => {
  const f = fixture([{ id, name: 'Saved' }]);
  await f.service.state(true);
  f.failSave();
  await assert.rejects(f.service.select(id, false), /Disk full/);
  assert((await f.service.state()).shortcuts.find((s) => s.id === id)?.selected);
  const broken = fixture({ old: 'unexpected' });
  await assert.rejects(broken.service.state(), /прочитать/);
  assert.deepEqual(broken.stored, { old: 'unexpected' });
});
test('reserve before discovery, reject duplicate runs and unselected IDs, report outcomes', async () => {
  const f = fixture([{ id, name: 'Saved' }]);
  f.hold();
  const running = f.service.run(id);
  await assert.rejects(f.service.run(id), /завершения/);
  while (!f.runs) await new Promise((done) => setImmediate(done));
  assert.equal(f.service.snapshot().run?.status, 'running');
  f.finish();
  assert.equal((await running).run?.status, 'completed');
  assert.equal(f.runs, 1);
  assert.equal((await f.service.run(second)).run?.status, 'failed');
  assert.equal(f.runs, 1);
  const cancelled = fixture([{ id, name: 'Saved' }]);
  cancelled.outcome('cancelled');
  assert.equal((await cancelled.service.run(id)).run?.status, 'cancelled');
  cancelled.outcome('failed');
  assert.equal((await cancelled.service.run(id)).run?.message, 'Permission denied');
  cancelled.service.stop();
  await assert.rejects(cancelled.service.run(id), /завершает/);
});
test('search chosen names with existing matching and preserve other result types', () => {
  const commands = [
    { id, name: 'Resize Images', selected: true, availability: 'available' as const },
    { id: second, name: 'Ignored', selected: false, availability: 'available' as const },
  ];
  assert.equal(shelfSearch([], [], 'resize', {}, {}, commands).results[0]?.kind, 'shortcut');
  assert.equal(shelfSearch([], [], 'ignored', {}, {}, commands).results.length, 0);
  assert.equal(shelfSearch([], [], '2+2', {}, {}, commands).results[0]?.kind, 'calculation');
  assert(shelfMethodAllowed('macShortcuts.run'));
  assert(!shelfMethodAllowed('macShortcuts.exec'));
});

test('CLI completion and cancellation use exposed exit status and error details', () => {
  assert.deepEqual(shortcutRunResult(0, 'ignored diagnostics'), { status: 'completed' });
  assert.equal(shortcutRunResult(1, 'Error: The user cancelled.').status, 'cancelled');
  assert.equal(shortcutRunResult(1, 'Error: NSUserCancelledError (-128)').status, 'cancelled');
  assert.deepEqual(shortcutRunResult(1, 'Permission denied'), {
    status: 'failed',
    message: 'Permission denied',
  });
  assert.equal(shortcutRunResult(null, '').status, 'failed');
  assert.deepEqual(parseShortcutList(`First line\nSecond line (${id})\n`), [
    { id, name: 'First line\nSecond line' },
  ]);
});
