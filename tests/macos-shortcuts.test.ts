import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MacShortcuts, parseShortcutList, shortcutRunResult } from '../src/main/macos-shortcuts';
import { shelfSearch, shortcutSearch } from '../src/shared/shelf-search';
import { shelfMethodAllowed } from '../src/shared/features';
const id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const second = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
function fixture() {
  let catalog = [
    { id, name: 'Подготовить встречу' },
    { id: second, name: 'Resize Images' },
  ];
  let listError = false;
  let runs = 0;
  let finish: (() => void) | undefined;
  let hold = false;
  let outcome: 'completed' | 'cancelled' | 'failed' = 'completed';
  const service = new MacShortcuts({
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
    changed: () => {},
  });
  return {
    service,
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
    recover: () => {
      listError = false;
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
      { id: id.toUpperCase(), name: 'Name (with parentheses)' },
      { id: second, name: 'Name (with parentheses)' },
    ],
  );
  assert.deepEqual(parseShortcutList(''), []);
  assert.throws(() => parseShortcutList('Unsupported listing'));
});
test('discover all shortcuts automatically, refresh renamed names, remove stale results', async () => {
  const f = fixture();
  assert.equal((await f.service.state()).shortcuts.length, 2);
  assert.equal(f.runs, 0);
  f.rename();
  const renamed = await f.service.state(true);
  assert.equal(renamed.shortcuts[0].name, 'Meeting Preparation');
  assert.equal(renamed.shortcuts[0].id, id);
  f.remove();
  assert.deepEqual((await f.service.state(true)).shortcuts, []);
  const removed = await f.service.run(id);
  assert.equal(removed.run?.status, 'failed');
  assert.match(removed.run?.message || '', /удалена/);
  assert.equal(f.runs, 0);
});
test('catalog failure retains last-known results, prevents stale execution, and recovers', async () => {
  const cold = fixture();
  cold.failList();
  const failed = await cold.service.run(id);
  assert.match(failed.run?.message || '', /проверить доступность/);
  assert.equal(cold.runs, 0);
  const f = fixture();
  await f.service.state();
  f.failList();
  assert.equal((await f.service.state(true)).shortcuts[0].availability, 'unknown');
  assert.equal((await f.service.run(id)).run?.status, 'failed');
  assert.equal(f.runs, 0);
  f.recover();
  assert.equal((await f.service.state(true)).shortcuts[0].availability, 'available');
  assert.equal((await f.service.run(id)).run?.status, 'completed');
});
test('reserve before discovery, reject duplicate runs and absent IDs, report outcomes', async () => {
  const f = fixture();
  f.hold();
  const running = f.service.run(id);
  await assert.rejects(f.service.run(id), /завершения/);
  while (!f.runs) await new Promise((done) => setImmediate(done));
  assert.equal(f.service.snapshot().run?.status, 'running');
  f.finish();
  assert.equal((await running).run?.status, 'completed');
  assert.equal(f.runs, 1);
  assert.equal((await f.service.run('cccccccc-cccc-cccc-cccc-cccccccccccc')).run?.status, 'failed');
  assert.equal(f.runs, 1);
  const cancelled = fixture();
  cancelled.outcome('cancelled');
  assert.equal((await cancelled.service.run(id)).run?.status, 'cancelled');
  cancelled.outcome('failed');
  assert.equal((await cancelled.service.run(id)).run?.message, 'Permission denied');
  cancelled.service.stop();
  await assert.rejects(cancelled.service.run(id), /завершает/);
});
test('shortcut folder follows apps, with folder and individual names searchable', () => {
  const commands = [
    { id, name: 'Resize Images', availability: 'available' as const },
    { id: second, name: 'Another Shortcut', availability: 'available' as const },
  ];
  assert.deepEqual(shelfSearch([], [], '', {}, {}, [], commands).results, [
    { id: 'shortcut-folder', kind: 'shortcut-folder', count: 2 },
  ]);
  assert.equal(
    shelfSearch([], [], 'Shortcuts', {}, {}, [], commands).results[0]?.kind,
    'shortcut-folder',
  );
  assert.equal(
    shelfSearch([], [], 'команды', {}, {}, [], commands).results[0]?.kind,
    'shortcut-folder',
  );
  assert.equal(shelfSearch([], [], 'another', {}, {}, [], commands).results[0]?.kind, 'shortcut');
  const apps = [
    {
      kind: 'mac' as const,
      id: 'mac:viewer',
      name: 'Resize Images Viewer',
      icon: '',
      description: '',
    },
  ];
  const matches = shelfSearch(apps, [], 'Resize Images', {}, {}, [], commands).results;
  assert.equal(matches[0]?.kind, 'app');
  assert.equal(matches[1]?.kind, 'shortcut');
  assert.deepEqual(
    shelfSearch(apps, [], '', {}, {}, [], commands).results.map((r) => r.kind),
    ['app', 'shortcut-folder'],
  );
  assert.equal(shortcutSearch(commands, '').length, 2);
  assert.equal(shortcutSearch(commands, 'resize images')[0]?.id, `shortcut:${id}`);
  assert.equal(shortcutSearch(commands, 'unrelated').length, 0);
  assert.equal(shortcutSearch([], '').length, 0);
  assert.equal(shelfSearch([], [], '2+2', {}, {}, [], commands).results[0]?.kind, 'calculation');
  assert(shelfMethodAllowed('macShortcuts.run'));
  assert(!shelfMethodAllowed('macShortcuts.select'));
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

test('native catalog identifiers survive case-insensitive lookup unchanged', async () => {
  let executed: string | undefined;
  const nativeId = id.toUpperCase();
  const service = new MacShortcuts({
    list: async () => [{ id: nativeId, name: 'Synthetic command' }],
    run: async (value) => {
      executed = value;
      return { status: 'completed' };
    },
    changed: () => {},
  });
  assert.equal((await service.state()).shortcuts[0].id, nativeId);
  assert.equal((await service.run(id)).run?.status, 'completed');
  assert.equal(executed, nativeId);
});
