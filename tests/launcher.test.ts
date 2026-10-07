import test from 'node:test';
import assert from 'node:assert/strict';
import { LauncherShortcut } from '../src/main/launcher-shortcut';
import { BUILTIN_APPS, launcherApps, type LauncherApp } from '../src/shared/launcher';

test('launcher searches native app names, descriptions and aliases and puts clipboard first', () => {
  const native: LauncherApp = {
    kind: 'mac',
    id: 'mac:qa',
    name: 'Code',
    icon: '',
    description: 'macOS · /Applications',
    searchTerms: ['Visual Studio Code'],
  };
  const apps = [native, ...BUILTIN_APPS];
  assert.deepEqual(
    launcherApps(apps, '').map((app) => app.id),
    ['builtin:clipboard', 'builtin:files', 'builtin:emoji', 'mac:qa'],
  );
  assert.deepEqual(
    launcherApps(apps, ' VISUAL studio ').map((app) => app.id),
    ['mac:qa'],
  );
  assert.deepEqual(
    launcherApps(apps, 'clipboard history').map((app) => app.id),
    ['builtin:clipboard'],
  );
  assert.equal(launcherApps(apps, 'unknown').length, 0);
  assert.equal(apps[0], native);
  assert.equal(launcherApps(apps, 'emoji')[0].id, 'builtin:emoji');
  assert.equal(launcherApps(apps, 'смайлики')[0].id, 'builtin:emoji');
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

test('launcher and clipboard cannot replace each other when native registration accepts duplicates', async () => {
  const callbacks = new Map<string, () => void>();
  const shortcuts = {
    isRegistered: (key: string) => callbacks.has(key),
    register: (key: string, callback: () => void) => {
      callbacks.set(key, callback);
      return true;
    },
    unregister: (key: string) => {
      callbacks.delete(key);
    },
  };
  const launch = () => {};
  const clipboard = () => {};
  const launcher = new LauncherShortcut(shortcuts, launch, async () => {});
  const history = new LauncherShortcut(shortcuts, clipboard, async () => {});
  launcher.initialize('Control+Space');
  history.initialize('Control+V');
  await assert.rejects(history.set('Control+Space'), /занято/);
  assert.equal(callbacks.get('Control+Space'), launch);
  assert.equal(callbacks.get('Control+V'), clipboard);
});
