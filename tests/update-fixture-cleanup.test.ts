import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
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
