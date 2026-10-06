import { once } from 'node:events';
import { join } from 'node:path';
import { writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { runDesktopTest, snapshotClipboard } from './desktop-test';

async function main() {
  let original: Awaited<ReturnType<typeof snapshotClipboard>> | undefined;
  const crash = Error('Intentional fixture crash to verify clipboard recovery');
  await assert.rejects(
    runDesktopTest('harness-recovery', async (test) => {
      const entry = join(test.profile, 'fixture.cjs');
      await writeFile(
        entry,
        `const {app,BrowserWindow}=require('electron');app.setPath('userData', ${JSON.stringify(test.profile)});app.whenReady().then(()=>new BrowserWindow({show:false}).loadURL('data:text/html,<p>Disposable harness fixture</p>'));`,
      );
      const app = await test.launch({ args: [entry] });
      original = await snapshotClipboard(app);
      await test.backupClipboard(app);
      await app.evaluate(({ clipboard }) => clipboard.writeText('Polka disposable crash fixture'));
      const exited = once(app.process(), 'exit');
      app.process().kill('SIGKILL');
      await exited;
      throw crash;
    }),
    (error) => error === crash,
  );
  await runDesktopTest('harness-recovery-check', async (test) => {
    const entry = join(test.profile, 'observer.cjs');
    await writeFile(
      entry,
      `const {app}=require('electron');app.setPath('userData', ${JSON.stringify(test.profile)});app.whenReady();`,
    );
    const app = await test.launch({ args: [entry] });
    // Compare in memory without writing or printing the user's formats or contents.
    assert.deepEqual(await snapshotClipboard(app), original);
  });
  console.log('Desktop harness passed: crashed fixture cleanup and original clipboard recovery.');
}

void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
