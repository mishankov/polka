import { test, type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough, Writable } from 'node:stream';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { setTimeout as delay, setImmediate as turn } from 'node:timers/promises';
import { buildSync } from 'esbuild';
import { ClipboardHistory } from '../src/main/clipboard-history';
import type { createShelf } from '../src/main/shelf';
import type { ClipboardState } from '../src/shared/clipboard';
import type { ShelfPresentation } from '../src/shared/shelf';

const bundle = buildSync({
  entryPoints: ['src/main/shelf.ts'],
  bundle: true,
  write: false,
  platform: 'node',
  format: 'cjs',
  packages: 'external',
}).outputFiles[0].text;
const require = createRequire(resolve('package.json'));
const codec = {
  encode: (text: string) => Buffer.from(text),
  decode: (data: Buffer) => data.toString(),
};
async function until(check: () => boolean | Promise<boolean>) {
  for (let i = 0; i < 100; i++) {
    if (await check()) return;
    await delay(5);
  }
  assert.fail('State did not settle');
}

async function fixture(
  t: TestContext,
  options: {
    failure?: 'read' | 'decrypt' | 'parse' | 'sync' | 'prune-write';
    probe?: 'error' | 'timeout' | ('ready' | 'error' | 'timeout' | 'exit')[];
    holdProbeExit?: boolean;
    holdHistory?: boolean;
  } = {},
) {
  const root = await mkdtemp(join(tmpdir(), 'polka-services-'));
  const path = join(root, 'clipboard-history', 'history.enc');
  const syncPath = join(root, 'clipboard-history', 'sync.enc');
  await mkdir(join(root, 'clipboard-history'));
  const initial = new ClipboardHistory(path, codec, () => {});
  await initial.initialize();
  await initial.preferences({ hoverEnabled: false, pasteOnSelect: false });
  await initial.add('text', 'Committed clip', 'Committed clip');
  await writeFile(syncPath, JSON.stringify({ enabled: false, key: '', cert: '', peers: [] }));
  if (options.failure === 'read') {
    await rm(path);
    await mkdir(path);
  }
  if (options.failure === 'parse') await writeFile(path, '{private clipboard input');
  if (options.failure === 'sync') await writeFile(syncPath, '{unreadable sync');
  if (options.failure === 'prune-write') {
    const saved = JSON.parse(await readFile(path, 'utf8'));
    saved.clips[0].createdAt = 0;
    await writeFile(path, JSON.stringify(saved));
  }
  const original = Object.assign(new Error('fixture decrypt failure'), {
    code: 'E_DECRYPT_FIXTURE',
  });
  let encryptFailure = options.failure === 'prune-write';
  let trusted = true;
  let clipboardReads = 0;
  const writes: Record<string, unknown>[] = [];
  const alerts: unknown[] = [];
  const shortcuts = new Set<string>();
  const commands: string[] = [];
  const probes: {
    child: EventEmitter & { stdin: Writable; stdout: PassThrough; kill(): void };
    kills: number;
  }[] = [];
  function spawnProbe() {
    const stdout = new PassThrough();
    const probe = new EventEmitter() as (typeof probes)[number]['child'];
    const attempt = { child: probe, kills: 0 };
    probes.push(attempt);
    probe.stdout = stdout;
    probe.stdin = new Writable({
      write(chunk, _encoding, done) {
        const command = JSON.parse(String(chunk));
        commands.push(command.method);
        if (command.method !== 'cancel') {
          queueMicrotask(() =>
            stdout.write(
              JSON.stringify({
                type: 'paste.reply',
                id: command.id,
                result: { trusted },
              }) + '\n',
            ),
          );
        }
        done();
      },
    });
    probe.kill = () => {
      attempt.kills++;
      if (!options.holdProbeExit) probe.emit('exit', null, 'SIGTERM');
    };
    const outcome = Array.isArray(options.probe)
      ? (options.probe[probes.length - 1] ?? 'ready')
      : (options.probe ?? 'ready');
    queueMicrotask(() => {
      if (outcome === 'error')
        probe.emit('error', Object.assign(new Error('probe missing'), { code: 'ENOENT' }));
      else if (outcome === 'exit') probe.emit('exit', 7, null);
      else if (outcome === 'ready') {
        stdout.write(
          JSON.stringify({
            type: 'screens',
            displays: [{ id: 1, x: 660, width: 192, height: 32 }],
          }) + '\n',
        );
        stdout.write('{"type":"ready"}\n');
      }
    });
    return probe;
  }
  let spawns = 0;
  let fileProbe: PassThrough | undefined;
  let testWindow: Window | undefined;
  let pointer = { x: 500, y: 500 };
  let shelf: ReturnType<typeof createShelf>;
  class Window extends EventEmitter {
    visible = false;
    focused = false;
    webContents = Object.assign(new EventEmitter(), {
      setWindowOpenHandler() {},
      send(_channel: string, event: { type: string; presentation: { revision: number } }) {
        if (event.type === 'shelf.shown')
          queueMicrotask(() => {
            void shelf.handle('shelf.didShow', { revision: event.presentation.revision });
          });
      },
    });
    isDestroyed() {
      return false;
    }
    isFocused() {
      return this.visible && this.focused;
    }
    isVisible() {
      return this.visible;
    }
    setVisibleOnAllWorkspaces() {}
    setAlwaysOnTop() {}
    setBounds() {}
    setIgnoreMouseEvents() {}
    loadFile() {
      return Promise.resolve();
    }
    loadURL() {
      return Promise.resolve();
    }
    show() {
      this.visible = true;
    }
    showInactive() {
      this.visible = true;
      this.focused = false;
    }
    hide() {
      this.visible = false;
      this.focused = false;
    }
    focus() {
      this.focused = true;
    }
  }
  const display = { id: 1, bounds: { x: 0, y: 0, width: 1512, height: 982 } };
  const screen = Object.assign(new EventEmitter(), {
    getCursorScreenPoint: () => pointer,
    getDisplayNearestPoint: () => display,
    getAllDisplays: () => [display],
  });
  const electron = {
    app: {
      isPackaged: false,
      getAppPath: () => process.cwd(),
      getFileIcon: async () => ({ toDataURL: () => '' }),
    },
    BrowserWindow: Window,
    clipboard: {
      async read() {
        clipboardReads++;
        return [{ types: ['text/plain'], getType: async () => new Blob(['New clip']) }];
      },
      async write(items: { content: Record<string, unknown> }[]) {
        writes.push(items[0].content);
      },
    },
    ClipboardItem: class {
      constructor(public content: Record<string, unknown>) {}
    },
    safeStorage: {
      isEncryptionAvailable: () => !encryptFailure,
      encryptString: codec.encode,
      decryptString(data: Buffer) {
        if (options.failure === 'decrypt') throw original;
        return codec.decode(data);
      },
    },
    globalShortcut: {
      register: (value: string) => {
        shortcuts.add(value);
        return true;
      },
      unregister: (value: string) => shortcuts.delete(value),
    },
    dialog: {
      showMessageBox: (value: unknown) => {
        alerts.push(value);
        return new Promise(() => {});
      },
    },
    screen,
    shell: { showItemInFolder() {}, openPath: async () => '' },
    Notification: class {
      static isSupported() {
        return false;
      }
    },
  };
  const module = { exports: {} as { createShelf: typeof createShelf } };
  let releaseHistory = () => {};
  const historyGate = new Promise<void>((resolve) => {
    releaseHistory = resolve;
  });
  const fs = require('node:fs');
  const load = (name: string) =>
    name === 'electron'
      ? electron
      : name === 'node:fs' && options.holdHistory
        ? {
            ...fs,
            promises: {
              ...fs.promises,
              async stat(file: string) {
                if (file === path) await historyGate;
                return fs.promises.stat(file);
              },
            },
          }
        : name === 'node:child_process'
          ? {
              spawn(path: string) {
                if (path.endsWith('file-shelf-probe')) {
                  const child = new EventEmitter() as any;
                  child.stdout = fileProbe = new PassThrough();
                  child.stderr = new PassThrough();
                  child.stdin = new PassThrough();
                  child.kill = () => {};
                  return child;
                }
                spawns++;
                return spawnProbe();
              },
            }
          : require(name);
  new Function('require', 'module', 'exports', '__dirname', bundle)(
    load,
    module,
    module.exports,
    process.cwd(),
  );
  let geometry = 0;
  shelf = module.exports.createShelf(
    root,
    (win) => {
      testWindow = win as unknown as Window;
    },
    () => {},
    () => false,
    () => {
      geometry++;
    },
  );
  t.after(async () => {
    releaseHistory();
    await shelf.stop();
    await rm(root, { recursive: true, force: true });
  });
  return {
    shelf,
    path,
    syncPath,
    root,
    original,
    alerts,
    shortcuts,
    commands,
    writes,
    start: () => shelf.start(),
    state: async () => (await shelf.handle('clipboardHistory.state', {})) as ClipboardState,
    geometry: () => geometry,
    spawns: () => spawns,
    reads: () => clipboardReads,
    denyAccess: () => {
      trusted = false;
    },
    failWrites: () => {
      encryptFailure = true;
    },
    releaseHistory,
    fileEvent: (type: string, paths?: string[]) =>
      fileProbe!.write(JSON.stringify({ type, paths }) + '\n'),
    movePointer: (point: typeof pointer) => {
      pointer = point;
    },
    visible: () => testWindow?.visible ?? false,
    focused: () => testWindow?.isFocused() ?? false,
    line: (line: string, index = probes.length - 1) =>
      probes[index].child.stdout.write(line + '\n'),
    exit: (index = probes.length - 1) => probes[index].child.emit('exit', 7, null),
    stdinError: (index: number) => probes[index].child.stdin.emit('error', Error('stale stdin')),
    kills: (index: number) => probes[index].kills,
  };
}

for (const failure of ['read', 'decrypt', 'parse'] as const) {
  test(`${failure} failure preserves storage while native services and emoji copying remain available`, async (t) => {
    const env = await fixture(t, { failure });
    const syncBytes = await readFile(env.syncPath);
    const historyBytes = failure === 'read' ? undefined : await readFile(env.path);
    await env.start(); // Never waits for the unacknowledged error dialog.
    let state = await env.state();
    const diagnostic = state.storage.diagnostic;
    assert.equal(state.storage.status, 'failed');
    assert.equal(diagnostic?.stage, failure);
    assert(!JSON.stringify(state).includes('private clipboard input'));
    assert.equal(state.helper.status, 'running');
    assert.equal(env.geometry(), 1);
    assert.equal(state.sync?.status, 'blocked');
    assert.equal(state.preferencesAvailable, false);
    assert.equal(state.preferences.paused, true);
    assert.equal(state.preferences.pasteOnSelect, false);
    assert.equal(state.preferences.hoverEnabled, false);
    assert.equal(state.preferences.accelerator, '');
    assert.equal(env.shortcuts.size, 0);
    assert.equal(state.pasteAccess, 'granted');
    assert.equal(state.pasteReady, false);
    await env.shelf.show('keyboard', 'emoji');
    const presentation = (await env.shelf.handle('shelf.presentation', {})) as ShelfPresentation;
    assert.equal(presentation.visible, true);
    assert.equal(presentation.destination, 'emoji');
    assert.equal(presentation.notchWidth, 192);
    await env.shelf.handle('shelf.selectEmoji', { id: '1f600' });
    assert.equal(env.writes.length, 1);
    assert(!env.commands.includes('paste'));
    for (const method of ['clear', 'preferences', 'shortcut', 'syncEnabled', 'syncNow']) {
      await assert.rejects(
        env.shelf.handle(`clipboardHistory.${method}`, { accelerator: 'Control+V', enabled: true }),
      );
    }
    env.line('{"type":"clipboard"}');
    env.line('invalid helper JSON');
    await delay(20);
    assert.equal(env.reads(), 0);
    assert.deepEqual((await env.state()).storage.diagnostic, diagnostic);
    env.exit();
    state = await env.state();
    assert.equal(state.helper.status, 'failed');
    assert.equal(state.pasteAccess, 'unavailable');
    assert.deepEqual(state.storage.diagnostic, diagnostic);
    assert.equal(env.alerts.length, 1);
    t.mock.timers.enable({ apis: ['setInterval'] });
    t.mock.timers.tick(60000);
    t.mock.timers.reset();
    await env.shelf.stop();
    if (historyBytes) assert.deepEqual(await readFile(env.path), historyBytes);
    else assert.deepEqual(await readdir(env.path), []);
    assert.deepEqual(await readFile(env.syncPath), syncBytes);
    assert.deepEqual((await readdir(join(env.root, 'clipboard-history'))).sort(), [
      'history.enc',
      'sync.enc',
    ]);
  });
}

test('unreadable sync file leaves local capture, shortcut, and helper working', async (t) => {
  const env = await fixture(t, { failure: 'sync' });
  const before = await readFile(env.syncPath);
  await env.start();
  const state = await env.state();
  assert.equal(state.storage.status, 'ready');
  assert.equal(state.helper.status, 'running');
  assert.equal(state.registered, true);
  assert.equal(state.sync?.status, 'failed');
  assert.equal(state.sync?.storage.diagnostic?.stage, 'parse');
  env.line('{"type":"clipboard"}');
  await until(async () => (await env.state()).clips.length === 2);
  assert.equal((await env.state()).sync?.storage.status, 'failed');
  await assert.rejects(env.shelf.handle('clipboardHistory.syncEnabled', { enabled: true }));
  assert.deepEqual(await readFile(env.syncPath), before);
  assert.equal(env.alerts.length, 0);
});

test('runtime write failure preserves committed clips for copying and stops subsequent capture', async (t) => {
  const env = await fixture(t);
  await env.start();
  const bytes = await readFile(env.path);
  env.failWrites();
  env.line('{"type":"clipboard"}');
  await until(async () => (await env.state()).storage.status === 'failed');
  const state = await env.state();
  assert.equal(state.preferencesAvailable, true);
  assert.equal(state.clips.length, 1);
  assert.equal(state.sync?.status, 'blocked');
  assert.equal(state.helper.status, 'running');
  await env.shelf.handle('clipboardHistory.copy', { id: state.clips[0].id });
  assert.equal(env.writes.length, 1);
  env.line('{"type":"clipboard"}');
  await delay(20);
  assert.equal(env.reads(), 1);
  await assert.rejects(env.shelf.handle('clipboardHistory.clear', {}));
  assert.deepEqual(await readFile(env.path), bytes);
  assert.equal(env.alerts.length, 1);
});

test('helper spawn failure retains healthy history and is distinct from permission denial', async (t) => {
  const env = await fixture(t, { probe: 'error' });
  await env.start();
  const state = await env.state();
  assert.equal(state.storage.status, 'ready');
  assert.equal(state.helper.status, 'failed');
  assert.match(state.helper.error!, /probe missing/);
  assert.equal(state.pasteAccess, 'unavailable');
  assert.equal(state.sync?.status, 'disabled');
  assert.equal(env.alerts.length, 0);
});

test('helper retries slow startup with a longer deadline and ignores stale process events', async (t) => {
  const env = await fixture(t, { probe: ['timeout', 'timeout'], holdProbeExit: true });
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const starting = env.start();
  const screens = JSON.stringify({
    type: 'screens',
    displays: [{ id: 1, x: 660, width: 192, height: 32 }],
  });
  env.line(screens);
  await env.shelf.show('keyboard', 'clipboard');
  const presentation = (await env.shelf.handle('shelf.presentation', {})) as ShelfPresentation;
  assert.equal(presentation.visible, true);
  t.mock.timers.tick(5000);
  await turn();
  assert.equal(env.kills(0), 1);
  // A replacement must wait for the timed-out process to actually exit.
  t.mock.timers.tick(1000);
  assert.equal(env.spawns(), 1);
  env.exit(0);
  await turn();
  t.mock.timers.tick(1000);
  await turn();
  assert.equal(env.spawns(), 2);
  assert.equal((await env.state()).helper.status, 'starting');
  // The second attempt can take longer than the original five-second limit.
  t.mock.timers.tick(10000);
  env.line(screens);
  env.line('{"type":"ready"}');
  await starting;
  assert.equal(env.geometry(), 1);
  assert.deepEqual(await env.shelf.handle('shelf.presentation', {}), presentation);
  env.line('{"type":"ready"}', 0);
  env.line('{"type":"clipboard"}', 0);
  env.stdinError(0);
  env.exit(0);
  t.mock.timers.tick(60000);
  t.mock.timers.reset();
  const state = await env.state();
  assert.equal(state.helper.status, 'running');
  assert.equal(state.helper.error, undefined);
  assert.equal(state.pasteAccess, 'granted');
  assert.equal(env.spawns(), 2);
  assert.equal(env.kills(1), 0);
  assert.equal(env.reads(), 0);
  env.line('{"type":"clipboard"}');
  await until(async () => (await env.state()).clips.length === 2);
});

test('helper exit before readiness is retried, but runtime exit stays a failure', async (t) => {
  const env = await fixture(t, { probe: ['exit', 'ready'] });
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const starting = env.start();
  await turn();
  t.mock.timers.tick(1000);
  await starting;
  assert.equal((await env.state()).helper.status, 'running');
  env.exit();
  t.mock.timers.tick(60000);
  t.mock.timers.reset();
  const state = await env.state();
  assert.equal(state.helper.status, 'failed');
  assert.equal(state.pasteAccess, 'unavailable');
  assert.equal(env.spawns(), 2);
});

test('persistent helper timeout exhausts bounded retries without reporting permission denial', async (t) => {
  const env = await fixture(t, { probe: 'timeout' });
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const starting = env.start();
  for (const timeout of [5000, 15000, 30000]) {
    t.mock.timers.tick(timeout);
    await turn();
    if (timeout !== 30000) {
      t.mock.timers.tick(1000);
      await turn();
    }
  }
  await starting;
  t.mock.timers.reset();
  const state = await env.state();
  assert.equal(state.storage.status, 'ready');
  assert.equal(state.helper.status, 'failed');
  assert.match(state.helper.error!, /30 секунд/);
  assert.equal(state.pasteAccess, 'unavailable');
  assert.equal(env.spawns(), 3);
  assert.equal(env.kills(0), 1);
  assert.equal(env.kills(1), 1);
  assert.equal(env.kills(2), 1);
});

for (const phase of ['startup', 'probe-exit', 'retry-delay'] as const) {
  test(`quitting during helper ${phase} cancels startup and prevents further retries`, async (t) => {
    const env = await fixture(t, { probe: 'timeout', holdProbeExit: phase === 'probe-exit' });
    t.mock.timers.enable({ apis: ['setTimeout'] });
    const starting = env.start();
    if (phase !== 'startup') {
      t.mock.timers.tick(5000);
      await turn();
    }
    await env.shelf.stop();
    await starting;
    t.mock.timers.tick(60000);
    t.mock.timers.reset();
    assert.equal(env.spawns(), 1);
    assert.equal(env.kills(0), 1);
    assert.equal((await env.state()).helper.status, 'stopped');
  });
}

test('valid helper permission denial is separate from helper and storage health', async (t) => {
  const env = await fixture(t);
  env.denyAccess();
  await env.start();
  const state = await env.state();
  assert.equal(state.pasteAccess, 'required');
  assert.equal(state.helper.status, 'running');
  assert.equal(state.storage.status, 'ready');
  assert.equal(state.pasteReady, false);
  assert(!env.commands.includes('requestAccess'));
});

test('native geometry and permission checks are available while history is still loading', async (t) => {
  const env = await fixture(t, { holdHistory: true });
  const starting = env.start();
  await until(() => env.geometry() === 1);
  const state = await env.state();
  assert.equal(state.helper.status, 'running');
  assert.equal(state.storage.status, 'starting');
  assert.equal(state.preferencesAvailable, false);
  assert.equal(state.pasteAccess, 'granted');
  env.releaseHistory();
  await starting;
  assert.equal((await env.state()).storage.status, 'ready');
});

test('initial expiry write failure preserves loaded native preferences and committed clips', async (t) => {
  const env = await fixture(t, { failure: 'prune-write' });
  const bytes = await readFile(env.path);
  await env.start();
  const state = await env.state();
  assert.equal(state.storage.status, 'failed');
  assert.equal(state.storage.diagnostic?.stage, 'encrypt');
  assert.equal(state.preferencesAvailable, true);
  assert.equal(state.registered, true);
  assert.equal(state.helper.status, 'running');
  assert.equal(state.clips.length, 1);
  assert.equal(state.sync?.status, 'blocked');
  assert.deepEqual(await readFile(env.path), bytes);
});

test(
  'an incoming drag that ends without a drop closes its automatic shelf',
  { skip: process.platform !== 'darwin' },
  async (t) => {
    const env = await fixture(t);
    await env.start();
    env.fileEvent('enter');
    await until(env.visible);
    env.fileEvent('incomingEnd');
    await until(
      async () =>
        !((await env.shelf.handle('shelf.presentation', {})) as ShelfPresentation).visible,
    );
    await until(() => !env.visible());
    assert.equal(
      ((await env.shelf.handle('shelf.files.state', {})) as { items: unknown[] }).items.length,
      0,
    );
  },
);

test(
  'leaving an automatic file shelf during a drag closes it and permits reentry',
  { skip: process.platform !== 'darwin' },
  async (t) => {
    const env = await fixture(t);
    await env.start();
    env.fileEvent('enter');
    await until(env.visible);
    env.movePointer({ x: 20, y: 800 });
    await until(
      async () =>
        !((await env.shelf.handle('shelf.presentation', {})) as ShelfPresentation).visible,
    );
    await until(() => !env.visible());
    env.movePointer({ x: 500, y: 500 });
    env.fileEvent('enter');
    await until(env.visible);
  },
);

for (const route of ['native', 'renderer'] as const) {
  test(
    `a successful ${route} file drop remains available after the incoming drag ends`,
    { skip: process.platform !== 'darwin' },
    async (t) => {
      const env = await fixture(t);
      const path = join(env.root, 'Plan.txt');
      await writeFile(path, 'Synthetic drag fixture');
      await env.start();
      env.fileEvent('enter');
      await until(env.visible);
      assert.equal(env.focused(), false, 'An incoming drag must not steal native focus');
      if (route === 'native') env.fileEvent('drop', [path]);
      else await env.shelf.handle('shelf.files.add', { paths: [path] });
      await until(
        async () =>
          ((await env.shelf.handle('shelf.files.state', {})) as { items: unknown[] }).items
            .length === 1,
      );
      await until(env.focused);
      env.fileEvent('incomingEnd');
      env.movePointer({ x: 20, y: 800 });
      await delay(500);
      assert.equal(env.visible(), true);
      assert.equal(await readFile(path, 'utf8'), 'Synthetic drag fixture');
    },
  );
}

test(
  'cancellation does not dismiss a manually opened file shelf',
  { skip: process.platform !== 'darwin' },
  async (t) => {
    const env = await fixture(t);
    await env.start();
    await env.shelf.handle('shelf.showFiles', {});
    env.fileEvent('enter');
    env.fileEvent('incomingEnd');
    await delay(500);
    assert.equal(env.visible(), true);
  },
);
