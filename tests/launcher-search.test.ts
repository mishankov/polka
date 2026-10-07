import test from 'node:test';
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { BUILTIN_APPS, launcherApps, type MacLauncherApp } from '../src/shared/launcher';

function app(name: string, searchTerms: string[] = [], description = ''): MacLauncherApp {
  return { kind: 'mac', id: `mac:${name}`, name, searchTerms, description, icon: '' };
}
const names = (apps: MacLauncherApp[], query: string) =>
  launcherApps(apps, query).map((item) => item.name);

test('search tolerates insertion, deletion, substitution and adjacent transposition', () => {
  const apps = [app('Safari'), app('Calendar'), app('Mail'), app('Terminal')];
  for (const query of ['saffari', 'safri', 'safaro', 'safrai', 'safra'])
    assert.equal(names(apps, query)[0], 'Safari', query);
  assert.equal(names(apps, 'mial')[0], 'Mail');
  assert.equal(names(apps, 'calnedar')[0], 'Calendar');
  assert.equal(names(apps, 'termnal')[0], 'Terminal');
  for (const query of ['zx', 'qqqqqq', 'sa'.repeat(5000), 'saf+ari', 'x '.repeat(1000)])
    assert.deepEqual(names(apps, query), [], query.slice(0, 30));
  assert.deepEqual(names([app('Safari')], 'sx'), []);
  assert.deepEqual(names([app('Clipboard')], 'cal'), []);
});

test('initials work for word separators, aliases and camel-case names', () => {
  const apps = [
    app('Visual Studio Code'),
    app('Google Chrome'),
    app('TextEdit'),
    app('Activity Monitor'),
    app('Code', ['Visual Studio Code']),
    app('Disk-Utility'),
  ];
  assert.deepEqual(names(apps, 'vsc'), ['Code', 'Visual Studio Code']);
  assert.deepEqual(names(apps, 'vs'), ['Code', 'Visual Studio Code']);
  assert.deepEqual(names(apps, 'gc'), ['Google Chrome']);
  assert.deepEqual(names(apps, 'te'), ['TextEdit']);
  assert.deepEqual(names(apps, 'am'), ['Activity Monitor']);
  assert.deepEqual(names(apps, 'du'), ['Disk-Utility']);
  assert.deepEqual(names([app('Safari')], 'si'), []);
});

test('both keyboard layouts work, including punctuation on Russian letter keys', () => {
  const apps = [app('Safari'), app('Google Chrome'), app('Заметки'), app('Журнал'), app('Ёлка')];
  assert.equal(names(apps, 'ЫФАФКШ')[0], 'Safari');
  assert.equal(names(apps, 'пщщпду сркщьу')[0], 'Google Chrome');
  assert.equal(names(apps, 'пс')[0], 'Google Chrome');
  assert.equal(names(apps, 'pfvtnrb')[0], 'Заметки');
  assert.equal(names(apps, ';ehyfk')[0], 'Журнал');
  assert.equal(names(apps, ':EHYFK')[0], 'Журнал');
  assert.equal(names(apps, '`krf')[0], 'Ёлка');
  assert.equal(names(apps, '~KRF')[0], 'Ёлка');
  assert.equal(names(apps, 'елка')[0], 'Ёлка');
  assert.equal(names(apps, 'ыфафк')[0], 'Safari');
  assert.equal(names(apps, 'ыфакш')[0], 'Safari');
});

test('usage cannot push weak matches ahead of exact or prefix matches', () => {
  const apps = [app('Safari Technology Preview'), app('Safira'), app('Safari'), app('My Safari')];
  const usage = Object.fromEntries(
    apps.map((item, i) => [item.id, { count: 100 - i, lastLaunchedAt: i }]),
  );
  assert.deepEqual(
    launcherApps(apps, 'safari', usage).map((item) => item.name),
    ['Safari', 'Safari Technology Preview', 'My Safari', 'Safira'],
  );
  const layout = [app('Ыфафкш Tools'), app('Safari')];
  assert.equal(
    launcherApps(layout, 'ыфафкш', { [layout[0].id]: { count: 100, lastLaunchedAt: 1 } })[0].name,
    'Safari',
  );
});

test('frequency then recency rank comparable results with deterministic ties and no mutation', () => {
  const apps = [app('Visual Studio Code'), app('Visual Studio'), app('Visual Notes')];
  const usage = {
    [apps[0].id]: { count: 2, lastLaunchedAt: 50 },
    [apps[1].id]: { count: 2, lastLaunchedAt: 100 },
    [apps[2].id]: { count: 1, lastLaunchedAt: 200 },
  };
  const original = structuredClone(apps);
  assert.deepEqual(
    launcherApps(apps, 'visual', usage).map((item) => item.name),
    ['Visual Studio', 'Visual Studio Code', 'Visual Notes'],
  );
  assert.deepEqual(
    launcherApps([...apps].reverse(), 'visual', usage),
    launcherApps(apps, 'visual', usage),
  );
  assert.deepEqual(apps, original);
  const sameName = [
    { ...app('Code'), id: 'mac:z' },
    { ...app('Code'), id: 'mac:a' },
  ];
  assert.equal(launcherApps(sameName, 'code')[0].id, 'mac:a');
  assert.deepEqual(
    launcherApps([...apps, ...BUILTIN_APPS], '', usage).map((item) => item.id),
    ['builtin:clipboard', 'builtin:files', 'builtin:emoji', apps[1].id, apps[0].id, apps[2].id],
  );
});

test('metadata remains searchable but does not receive fuzzy or initials matching', () => {
  const apps = [
    app('Code', ['com.microsoft.VSCode', 'Visual Studio Code'], 'macOS · /Applications'),
  ];
  for (const query of ['  STUDIO   visual  ', 'microsoft', '/applications', 'vscode'])
    assert.deepEqual(names(apps, query), ['Code']);
  assert.deepEqual(names(apps, '/applicatons'), []);
  assert.deepEqual(names(apps, 'ma'), ['Code']);
});

test('matching stays responsive with a large catalog and long pasted queries', () => {
  const apps = Array.from({ length: 3000 }, (_, i) =>
    app(`Application ${i} Editor`, [`com.vendor.product${i}`]),
  );
  apps.push(app('Safari'), app('Visual Studio Code'));
  // Warm metadata caches before measuring successive keystrokes.
  names(apps, 's');
  const start = performance.now();
  for (const query of ['sa', 'saf', 'safri', 'ыфафкш', 'vsc', 'z'.repeat(10000)])
    names(apps, query);
  const elapsed = performance.now() - start;
  assert(elapsed < 1500, `Six searches across 3002 apps took ${elapsed.toFixed(1)}ms`);
});
