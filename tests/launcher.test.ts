import test from 'node:test';
import assert from 'node:assert/strict';
import { LauncherShortcut } from '../src/main/launcher-shortcut';
import { launcherApps, type LauncherApp } from '../src/shared/launcher';

test('launcher searches names and descriptions, excludes archives, and prefers favorites', () => {
  const apps: LauncherApp[] = [
    {
      id: '1',
      kind: 'everything',
      name: 'Бета',
      description: 'Мои проекты',
      icon: '',
      status: 'stopped',
      favorite: true,
    },
    {
      id: '2',
      kind: 'everything',
      name: 'Альфа',
      description: 'Мои проекты',
      icon: '',
      status: 'running',
      favorite: false,
    },
    {
      id: '3',
      kind: 'everything',
      name: 'Архив',
      description: 'Мои проекты',
      icon: '',
      status: 'archived',
      favorite: true,
    },
  ];
  assert.deepEqual(
    launcherApps(apps, '  ПРОЕКТЫ мои ').map((app) => app.id),
    ['1', '2'],
  );
  assert.deepEqual(
    launcherApps(apps, 'альф').map((app) => app.id),
    ['2'],
  );
  assert.equal(launcherApps(apps, 'unknown').length, 0);
  const native: LauncherApp = {
    kind: 'mac',
    id: 'mac:qa',
    name: 'Google Chrome',
    icon: '',
    description: 'macOS · /Applications',
  };
  assert.deepEqual(
    launcherApps([...apps, native], '').map((app) => app.id),
    ['1', '2', 'mac:qa'],
  );
  assert.deepEqual(
    launcherApps([...apps, native], 'CHROME').map((app) => app.id),
    ['mac:qa'],
  );
  assert.equal(
    launcherApps(
      [{ ...native, name: 'Code', searchTerms: ['Visual Studio Code'] }],
      'visual studio',
    ).length,
    1,
  );
  assert.deepEqual(
    apps.map((app) => app.id),
    ['1', '2', '3'],
  );
});

function shortcutFixture() {
  const registered = new Set<string>();
  const blocked = new Set<string>();
  let failSave = false;
  const saved: string[] = [];
  const service = new LauncherShortcut(
    {
      register: (key) => {
        if (registered.has(key) || blocked.has(key)) return false;
        registered.add(key);
        return true;
      },
      unregister: (key) => {
        registered.delete(key);
      },
    },
    () => {},
    async (key) => {
      if (failSave) throw Error('disk failure');
      saved.push(key);
    },
  );
  return {
    service,
    registered,
    blocked,
    saved,
    failSave: () => {
      failSave = true;
    },
  };
}

test('conflict and save failure retain the working launcher shortcut', async () => {
  const fixture = shortcutFixture();
  fixture.service.initialize('Alt+Space');
  fixture.blocked.add('Control+Space');
  await assert.rejects(fixture.service.set('Control+Space'), /занято/);
  assert.deepEqual([...fixture.registered], ['Alt+Space']);
  fixture.failSave();
  await assert.rejects(fixture.service.set('Control+K'), /disk failure/);
  assert.deepEqual([...fixture.registered], ['Alt+Space']);
  assert.equal(fixture.service.getPreferences().accelerator, 'Alt+Space');
});

test('shortcut replacement, concurrent changes, disabling, and startup conflict recovery', async () => {
  const fixture = shortcutFixture();
  fixture.blocked.add('Alt+Space');
  fixture.service.initialize('Alt+Space');
  assert.equal(fixture.service.getPreferences().registered, false);
  assert.match(fixture.service.getPreferences().error!, /занято/);
  await fixture.service.set('Control+K');
  assert.deepEqual(fixture.service.getPreferences(), {
    accelerator: 'Control+K',
    registered: true,
  });
  await Promise.all([fixture.service.set('Control+J'), fixture.service.set('Control+L')]);
  assert.deepEqual([...fixture.registered], ['Control+L']);
  await fixture.service.set('Control+L');
  assert.deepEqual(fixture.saved, ['Control+K', 'Control+J', 'Control+L']);
  await fixture.service.set('');
  assert.deepEqual([...fixture.registered], []);
  assert.deepEqual(fixture.service.getPreferences(), { accelerator: '', registered: false });
});
