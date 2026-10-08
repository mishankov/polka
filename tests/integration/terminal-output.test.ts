import test from 'node:test';
import assert from 'node:assert/strict';
import { Console } from 'node:console';
import { Writable, PassThrough } from 'node:stream';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { setImmediate } from 'node:timers/promises';
import { protectTerminalOutput } from '../../src/main/terminal-output';

for (const code of ['EIO', 'EPIPE']) {
  for (const method of ['log', 'error'] as const) {
    test(`console.${method} tolerates ${code} from a disconnected terminal`, async () => {
      const failure = Object.assign(new Error(`write ${code}`), { code });
      const broken = new Writable({
        write(_chunk, _encoding, callback) {
          callback(failure);
        },
      });
      const healthy = new PassThrough();
      const stdout = method === 'log' ? broken : healthy;
      const stderr = method === 'error' ? broken : healthy;
      protectTerminalOutput(stdout, stderr);
      const logger = new Console({ stdout, stderr, ignoreErrors: false });
      logger[method]('Logging during terminal teardown');
      await setImmediate();
      assert.equal(broken.errored, failure);
      logger[method]('A subsequent log must also be harmless');
      await setImmediate();
      healthy.destroy();
    });
  }
}

test('healthy output is preserved and unexpected stream errors still surface', () => {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  protectTerminalOutput(stdout, stderr);
  const logger = new Console({ stdout, stderr, ignoreErrors: false });
  logger.log('normal output');
  logger.error('normal error');
  assert.equal(stdout.read().toString(), 'normal output\n');
  assert.equal(stderr.read().toString(), 'normal error\n');
  for (const stream of [stdout, stderr]) {
    for (const code of ['ENOSPC', 'EBADF', undefined]) {
      const failure = Object.assign(new Error('unexpected output failure'), { code });
      assert.throws(
        () => stream.emit('error', failure),
        (error) => error === failure,
      );
    }
    stream.destroy();
  }
});

for (const output of ['stdout', 'stderr'] as const) {
  test(`process survives a real closed ${output} pipe`, { timeout: 10000 }, async (t) => {
    const moduleUrl = new URL('../../src/main/terminal-output.ts', import.meta.url).href;
    const child = spawn(
      process.execPath,
      [
        '--import',
        'tsx',
        '--input-type=module',
        '-e',
        `import { protectTerminalOutput } from ${JSON.stringify(moduleUrl)};
         protectTerminalOutput();
         process.${output}.on('error', (error) => {
           process.send({ code: error.code });
           setImmediate(() => process.disconnect());
         });
         process.once('message', () => process.${output}.write('late output'));
         process.send('ready');`,
      ],
      { stdio: ['ignore', 'pipe', 'pipe', 'ipc'] },
    );
    t.after(() => {
      if (child.exitCode === null) child.kill();
    });
    const exited = once(child, 'exit');
    assert.deepEqual(await once(child, 'message'), ['ready', undefined]);
    const closed = once(child[output]!, 'close');
    child[output]!.destroy();
    await closed;
    const failure = once(child, 'message');
    child.send('write');
    assert.deepEqual((await failure)[0], { code: 'EPIPE' });
    assert.deepEqual(await exited, [0, null]);
  });
}
