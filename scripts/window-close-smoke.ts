import { _electron as electron, expect, type Page } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-window-close-'));
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  const child = app.process();
  let stderr = '';
  child.stderr?.on('data', (data) => (stderr += data.toString()));
  const rendererErrors: string[] = [];
  const watch = (page: Page) =>
    page.on('pageerror', (error) => rendererErrors.push(error.stack || error.message));
  app.context().pages().forEach(watch);
  app.context().on('page', watch);
  let quit = false;
  const checks: string[] = [];
  try {
    // Observe real Electron errors, including its default uncaught-exception dialog.
    // Replacing only the dialog keeps an actual regression from blocking unattended tests.
    await app.evaluate(({ dialog }) => {
      (globalThis as any).__closeErrors = [];
      process.on('uncaughtExceptionMonitor', (error) => {
        const message = error.stack || error.message;
        (globalThis as any).__closeErrors.push(message);
        process.stderr.write(`WINDOW_CLOSE_ERROR:${JSON.stringify(message)}\n`);
      });
      process.on('unhandledRejection', (error) => {
        (globalThis as any).__closeErrors.push(String(error));
        process.stderr.write(`WINDOW_CLOSE_ERROR:${JSON.stringify(String(error))}\n`);
      });
      dialog.showErrorBox = (title, content) => {
        (globalThis as any).__closeErrors.push(`${title}: ${content}`);
        process.stderr.write(`WINDOW_CLOSE_ERROR:${JSON.stringify(`${title}: ${content}`)}\n`);
      };
    });
    const shell = await app.firstWindow();
    await shell.locator('.home-page').waitFor();
    const instance = await shell.evaluate(async () => {
      const instance = await window.platform.call('apps.create', {
        definition: {
          schemaVersion: 1,
          name: 'Window close QA',
          entities: [],
          actions: [],
          automations: [],
          permissions: [],
          screens: [
            { id: 'screen', name: 'Screen', type: 'custom', config: { extensionId: 'screen' } },
          ],
          extensions: [
            {
              id: 'screen',
              name: 'Screen',
              kind: 'component',
              source: `import {useState} from 'react'; export default function Screen(){const [count,setCount]=useState(0);return <button onClick={()=>setCount(count+1)}>Close QA {count}</button>}`,
              dependencies: {},
            },
          ],
        },
      });
      await window.platform.call('apps.updateMeta', { appId: instance.id, status: 'running' });
      return instance;
    });
    const healthy = async () => {
      assert.deepEqual(await app.evaluate(() => (globalThis as any).__closeErrors), []);
      assert.deepEqual(rendererErrors, []);
      assert(!stderr.includes('WINDOW_CLOSE_ERROR:'), stderr);
    };
    const extensionIds = () =>
      app.evaluate(({ webContents }) =>
        webContents
          .getAllWebContents()
          .filter((wc) => wc.getURL().startsWith('everything-extension:'))
          .map((wc) => wc.id),
      );
    const open = async (mode: string) => {
      const id = await shell.evaluate(
        ({ appId, mode }) => window.platform.call('windows.open', { appId, mode }),
        { appId: instance.id, mode },
      );
      await expect.poll(async () => (await extensionIds()).length).toBe(1);
      const view = app
        .context()
        .pages()
        .find((page) => page.url().startsWith('everything-extension:'))!;
      await view.getByRole('button', { name: 'Close QA 0', exact: true }).click();
      await view.getByRole('button', { name: 'Close QA 1', exact: true }).waitFor();
      return id as number;
    };
    for (const mode of ['window', 'overlay', 'window', 'overlay']) {
      const id = await open(mode);
      await app.evaluate(({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.close(), id);
      await healthy();
      await expect.poll(extensionIds).toEqual([]);
      assert.equal(await shell.evaluate(() => 2 + 2), 4);
      assert.equal(
        await shell.evaluate(
          (appId) => window.platform.call('apps.get', { appId }).then((value) => value.id),
          instance.id,
        ),
        instance.id,
      );
      await healthy();
      checks.push(`${mode} opens, interacts, closes without orphan views`);
    }
    const childFirst = await open('window');
    await app.evaluate(({ BrowserWindow }, id) => {
      const win = BrowserWindow.fromId(id)!;
      const view = win.contentView.children.find((view: any) => view.webContents) as any;
      view.webContents.close({ waitForBeforeUnload: false });
    }, childFirst);
    await expect.poll(extensionIds).toEqual([]);
    await app.evaluate(({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.close(), childFirst);
    await healthy();
    checks.push('child destroyed before owner');

    // Leave a native app window alive while closing the main workspace with its own custom view.
    await open('overlay');
    await shell.locator('.app-nav').filter({ hasText: 'Window close QA' }).first().click();
    await expect.poll(async () => (await extensionIds()).length).toBe(2);
    const shellId = await app.evaluate(
      ({ BrowserWindow }) =>
        BrowserWindow.getAllWindows().find((win) => !win.webContents.getURL().includes('appId='))!
          .id,
    );
    await app.evaluate(({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.close(), shellId);
    await healthy();
    await expect.poll(async () => (await extensionIds()).length).toBe(1);
    checks.push('workspace closes while floating custom app remains');
    const exited = new Promise<number | null>((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(Error('Application did not quit within 20 seconds')),
        20_000,
      );
      child.once('close', (code) => {
        clearTimeout(timeout);
        resolve(code);
      });
    });
    await app.evaluate(({ app }) => {
      setTimeout(() => app.quit(), 0);
    });
    assert.equal(await exited, 0);
    quit = true;
    assert(!stderr.includes('WINDOW_CLOSE_ERROR:'), stderr);
    assert(!/Uncaught Exception|Object has been destroyed/.test(stderr), stderr);
    assert.deepEqual(rendererErrors, []);
    checks.push('quit with remaining custom window without main-process errors');
    await mkdir('artifacts', { recursive: true });
    await writeFile(
      'artifacts/window-close-smoke.json',
      JSON.stringify({ passed: true, checks, rendererErrors, mainProcessErrors: [] }, null, 2),
    );
    console.log('Window close smoke passed');
  } catch (error) {
    if (stderr.includes('WINDOW_CLOSE_ERROR:')) console.error(stderr);
    await mkdir('artifacts', { recursive: true });
    await writeFile(
      'artifacts/window-close-smoke-failure.json',
      JSON.stringify(
        { passed: false, checks, rendererErrors, stderr, error: String(error) },
        null,
        2,
      ),
    );
    throw error;
  } finally {
    if (!quit) await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
