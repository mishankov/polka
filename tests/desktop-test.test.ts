import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import type { ElectronApplication } from '@playwright/test';
import {
  acquireDesktopLock,
  closeDesktopApp,
  desktopEnvironment,
  snapshotClipboard,
  restoreClipboard,
} from '../scripts/desktop-test';

test('GUI lock serializes suites and does not evict a live owner', async () => {
  const root = await mkdtemp(join(tmpdir(), 'polka-lock-test-'));
  const path = join(root, 'lock');
  const release = await acquireDesktopLock(path);
  try {
    await assert.rejects(acquireDesktopLock(path, 25), /Another desktop suite/);
    let acquired = false;
    const next = acquireDesktopLock(path).then((releaseNext) => {
      acquired = true;
      return releaseNext;
    });
    assert.equal(acquired, false);
    await release();
    await (
      await next
    )();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('competing GUI suites recover a dead owner without evicting the new owner', async () => {
  const root = await mkdtemp(join(tmpdir(), 'polka-lock-test-'));
  const path = join(root, 'lock');
  const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 50)']);
  const exited = once(child, 'exit');
  await mkdir(path);
  await writeFile(join(path, 'owner.json'), JSON.stringify({ pid: child.pid, token: 'dead' }));
  await exited;
  try {
    let active = 0;
    let completed = 0;
    await Promise.all(
      Array.from({ length: 4 }, async () => {
        const release = await acquireDesktopLock(path, 2000);
        try {
          active++;
          assert.equal(active, 1);
          await new Promise((done) => setTimeout(done, 25));
          completed++;
        } finally {
          active--;
          await release();
        }
      }),
    );
    assert.equal(completed, 4);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('launch environment removes Node mode without changing the caller environment', () => {
  const env = {
    ELECTRON_RUN_AS_NODE: '1',
    EVERYTHING_PROFILE: '/fixture',
    PATH: '/bin',
    EMPTY: undefined,
  };
  assert.deepEqual(desktopEnvironment(env), { EVERYTHING_PROFILE: '/fixture', PATH: '/bin' });
  assert.equal(env.ELECTRON_RUN_AS_NODE, '1');
});

test(
  'shutdown waits for final writes even when the Playwright quit acknowledgement is lost',
  { timeout: 5000 },
  async () => {
    const root = await mkdtemp(join(tmpdir(), 'polka-close-test-'));
    const path = join(root, 'final-write');
    const child = spawn(
      process.execPath,
      [
        '-e',
        `
    process.on('SIGTERM', () => setTimeout(() => {
      require('node:fs').writeFileSync(process.argv[1], 'saved'); process.exit(0);
    }, 100));
    setInterval(() => {}, 1000); process.send('ready');
  `,
        path,
      ],
      { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] },
    );
    await once(child, 'message');
    try {
      await closeDesktopApp(
        { process: () => child, close: () => new Promise(() => {}) } as any,
        25,
      );
      assert.equal(child.exitCode, 0);
      const { readFile } = await import('node:fs/promises');
      assert.equal(await readFile(path, 'utf8'), 'saved');
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
      await rm(root, { recursive: true, force: true });
    }
  },
);

test(
  'orderly quit accepts a natural successful exit when the debugger loses its acknowledgement',
  { timeout: 5000 },
  async () => {
    const child = spawn(
      process.execPath,
      [
        '-e',
        "process.send('ready'); process.on('message', () => setTimeout(() => process.exit(0), 50));",
      ],
      { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] },
    );
    await once(child, 'message');
    try {
      await closeDesktopApp(
        {
          process: () => child,
          close: async () => {
            child.send('quit');
            throw Error('Debugger disconnected');
          },
        } as any,
        100,
        true,
      );
      assert.equal(child.exitCode, 0);
      assert.equal(child.signalCode, null);
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }
  },
);

test(
  'an orderly-quit assertion fails when cleanup had to terminate the fixture',
  { timeout: 5000 },
  async () => {
    const child = spawn(
      process.execPath,
      ['-e', "setInterval(() => {}, 1000); process.send('ready');"],
      { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] },
    );
    await once(child, 'message');
    try {
      await assert.rejects(
        closeDesktopApp(
          { process: () => child, close: () => new Promise(() => {}) } as any,
          25,
          true,
        ),
        /Electron quit timed out/,
      );
      assert.notEqual(child.signalCode, null);
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }
  },
);

test('clipboard backup materializes lazy formats, skips empty items and survives app restart', async () => {
  const blob = new Blob(['original text']);
  let materialized = false;
  let written: any[] | undefined;
  let cleared = false;
  const bookmark = { opaque: 'native file bookmark' };
  const remote = {
    clipboard: {
      read: async () => [
        {
          types: [],
          getType: () => {
            throw Error('Empty item must be skipped');
          },
        },
        {
          types: ['text/plain', 'file/bookmark'],
          getType: async (type: string) => {
            materialized = true;
            return type === 'text/plain' ? blob : bookmark;
          },
        },
      ],
      write: async (items: any[]) => {
        written = items;
      },
      clear: () => {
        cleared = true;
      },
    },
    ClipboardItem: class {
      constructor(readonly formats: Record<string, unknown>) {
        assert(Object.keys(formats).length > 0);
      }
    },
  };
  const original = { evaluate: (callback: any) => callback(remote) } as ElectronApplication;
  const backup = await snapshotClipboard(original);
  assert(materialized);
  const restarted = {
    evaluate: (callback: any, args: unknown) => callback(remote, args),
  } as ElectronApplication;
  await restoreClipboard(restarted, backup);
  assert.equal(written?.length, 1);
  assert.equal(await written![0].formats['text/plain'].text(), 'original text');
  assert.deepEqual(written![0].formats['file/bookmark'], bookmark);
  await restoreClipboard(restarted, []);
  assert(cleared);
});
