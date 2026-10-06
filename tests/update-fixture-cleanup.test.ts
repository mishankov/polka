import test from 'node:test';
import assert from 'node:assert/strict';
import childProcess, {
  spawn,
  type ChildProcess,
  type SpawnSyncOptionsWithStringEncoding,
} from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { stopUpdateFixtureProcesses } from '../scripts/update-fixture-cleanup';

async function fixture(marker: string, behavior: 'delayed' | 'ignore' | 'exit', writes = false) {
  const child = spawn(
    process.execPath,
    [
      '-e',
      `
    const fs = require('node:fs');
    const path = require('node:path');
    const [marker, behavior, writes] = process.argv.slice(1);
    process.on('SIGTERM', () => {
      if (behavior === 'ignore') return;
      if (behavior === 'exit') process.exit(0);
      setTimeout(() => {
        fs.writeFileSync(path.join(marker, 'shutdown-write'), 'finished');
        process.exit(0);
      }, 200);
    });
    setInterval(() => {
      if (writes === 'true') fs.writeFileSync(path.join(marker, 'cache'), 'still running');
    }, 10);
    process.send('ready');
  `,
      marker,
      behavior,
      String(writes),
    ],
    { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] },
  );
  const exited = once(child, 'exit');
  await once(child, 'message');
  return { child, exited };
}

async function dispose(child: ChildProcess) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit');
  child.kill('SIGKILL');
  await exited;
}

test(
  'cleanup waits for a detached fixture to finish cache writes before removing its directory',
  { timeout: 10000 },
  async () => {
    const directory = await mkdtemp(join(tmpdir(), 'polka-update-cleanup-'));
    const app = await fixture(directory, 'delayed', true);
    try {
      await stopUpdateFixtureProcesses(directory, `app.polka.cleanup.${randomUUID()}`);
      assert.deepEqual(await app.exited, [0, null]);
      assert.equal(await readFile(join(directory, 'shutdown-write'), 'utf8'), 'finished');
      await rm(directory, { recursive: true, force: true });
      await assert.rejects(readFile(join(directory, 'cache')), { code: 'ENOENT' });
    } finally {
      await dispose(app.child);
      await rm(directory, { recursive: true, force: true });
    }
  },
);

test(
  'cleanup finds a helper by literal app ID and leaves a similar unrelated process running',
  { timeout: 10000 },
  async () => {
    const directory = await mkdtemp(join(tmpdir(), 'polka-update-cleanup-'));
    const appId = `app.polka.cleanup.${randomUUID()}`;
    const helper = await fixture(appId, 'exit');
    const unrelated = await fixture(appId.replaceAll('.', 'x'), 'exit');
    try {
      await stopUpdateFixtureProcesses(directory, appId);
      assert.deepEqual(await helper.exited, [0, null]);
      assert.equal(unrelated.child.exitCode, null);
      assert.equal(unrelated.child.signalCode, null);
      assert.doesNotThrow(() => process.kill(unrelated.child.pid!, 0));
    } finally {
      await dispose(helper.child);
      await dispose(unrelated.child);
      await rm(directory, { recursive: true, force: true });
    }
  },
);

test(
  'cleanup escalates when a fixture ignores graceful termination',
  { timeout: 10000 },
  async () => {
    const directory = await mkdtemp(join(tmpdir(), 'polka-update-cleanup-'));
    const app = await fixture(directory, 'ignore');
    try {
      await stopUpdateFixtureProcesses(directory, `app.polka.cleanup.${randomUUID()}`);
      assert.deepEqual(await app.exited, [null, 'SIGKILL']);
    } finally {
      await dispose(app.child);
      await rm(directory, { recursive: true, force: true });
    }
  },
);

test('cleanup retries a timed-out process scan before stopping the fixture', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'polka-update-cleanup-'));
  const app = await fixture(directory, 'delayed', true);
  const inspect = childProcess.spawnSync;
  const clock = Date.now;
  let scanDelay = 0;
  let scans = 0;
  t.mock.method(Date, 'now', () => clock() + scanDelay);
  t.mock.method(
    childProcess,
    'spawnSync',
    (command: string, args: readonly string[], options: SpawnSyncOptionsWithStringEncoding) => {
      assert.equal(command, 'pgrep');
      if (++scans === 1) {
        scanDelay += 5000;
        return {
          error: Object.assign(new Error('spawnSync pgrep ETIMEDOUT'), { code: 'ETIMEDOUT' }),
          pid: 0,
          output: [],
          stdout: '',
          stderr: '',
          status: null,
          signal: 'SIGTERM',
        };
      }
      return inspect(command, args, options);
    },
  );
  syncBuiltinESMExports();
  try {
    await stopUpdateFixtureProcesses(directory, `app.polka.cleanup.${randomUUID()}`);
    assert(scans >= 2);
    assert.deepEqual(await app.exited, [0, null]);
    assert.equal(await readFile(join(directory, 'shutdown-write'), 'utf8'), 'finished');
  } finally {
    t.mock.restoreAll();
    syncBuiltinESMExports();
    await dispose(app.child);
    await rm(directory, { recursive: true, force: true });
  }
});

test('cleanup bounds repeated scan timeouts and propagates other inspection errors', async (t) => {
  let now = 0;
  t.mock.method(Date, 'now', () => (now += 1000));
  const timeout = Object.assign(new Error('spawnSync pgrep ETIMEDOUT'), { code: 'ETIMEDOUT' });
  let scans = 0;
  t.mock.method(childProcess, 'spawnSync', () => {
    scans++;
    return { error: timeout };
  });
  syncBuiltinESMExports();
  try {
    await assert.rejects(
      stopUpdateFixtureProcesses('/unused-fixture', 'unused.app.id'),
      /Timed out waiting for updater fixture processes to exit/,
    );
    assert(scans > 1 && scans < 15);
    t.mock.restoreAll();
    const failure = Object.assign(new Error('spawnSync pgrep ENOENT'), { code: 'ENOENT' });
    t.mock.method(childProcess, 'spawnSync', () => ({ error: failure }));
    syncBuiltinESMExports();
    await assert.rejects(stopUpdateFixtureProcesses('/unused-fixture', 'unused.app.id'), {
      code: 'ENOENT',
    });
  } finally {
    t.mock.restoreAll();
    syncBuiltinESMExports();
  }
});
