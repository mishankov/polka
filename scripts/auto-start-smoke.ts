import { _electron as electron, expect, type Page } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-auto-start-'));
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  const errors: string[] = [];
  const watch = (page: Page) => page.on('pageerror', (error) => errors.push(error.message));
  app.context().pages().forEach(watch);
  app.context().on('page', watch);
  const checks: string[] = [];
  try {
    const shell = await app.firstWindow();
    await shell.locator('.home-page').waitFor();
    const shellId = await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].id);
    const instance = await shell.evaluate(() =>
      window.platform.call('apps.create', {
        definition: {
          schemaVersion: 1,
          name: 'Автоматическое открытие',
          entities: [],
          actions: [],
          automations: [],
          permissions: [],
          screens: [
            { id: 'canvas', name: 'Холст', type: 'custom', config: { extensionId: 'canvas' } },
          ],
          extensions: [
            {
              id: 'canvas',
              name: 'Холст',
              kind: 'component',
              source:
                "import {useState} from 'react'; export default function Screen(){const [count,setCount]=useState(0);return <button onClick={()=>setCount(count+1)}>Automatic app {count}</button>}",
            },
          ],
        },
      }),
    );
    const status = () =>
      shell.evaluate(
        (appId) => window.platform.call('apps.get', { appId }).then((value) => value.status),
        instance.id,
      );
    const stop = async () => {
      await shell.evaluate(
        (appId) => window.platform.call('apps.updateMeta', { appId, status: 'stopped' }),
        instance.id,
      );
      await expect.poll(status).toBe('stopped');
    };
    const viewFor = async (ownerId: number) => {
      let view: Page | undefined;
      await expect
        .poll(
          async () => {
            const urls = await app.evaluate(({ BrowserWindow }, id) => {
              const owner = BrowserWindow.fromId(id);
              return (owner?.contentView.children || [])
                .map((child: any) => child.webContents?.getURL() || '')
                .filter((url: string) => url.startsWith('everything-extension:'));
            }, ownerId);
            view = app
              .context()
              .pages()
              .find((page) => urls.includes(page.url()) && !page.isClosed());
            return !!view;
          },
          { timeout: 15_000 },
        )
        .toBe(true);
      return view!;
    };
    const interactive = async (ownerId: number) => {
      const view = await viewFor(ownerId);
      const button = view.getByRole('button', { name: /^Automatic app \d+$/ });
      await button.waitFor();
      const count = Number((await button.innerText()).split(' ').at(-1));
      await button.click();
      await expect(button).toHaveText(`Automatic app ${count + 1}`);
      await expect.poll(status).toBe('running');
    };
    assert.equal(await status(), 'stopped', 'Listing or reading a new app must not start it');
    await shell.getByRole('button', { name: instance.name, exact: true }).click();
    await interactive(shellId);
    await expect(shell.getByText('Экран не запущен', { exact: true })).toHaveCount(0);
    checks.push('opening a stopped custom app in the workspace starts an interactive screen');

    await shell.getByRole('button', { name: 'Приложение', exact: true }).click();
    await shell.getByRole('menuitem', { name: 'Остановить приложение', exact: true }).click();
    await expect.poll(status).toBe('stopped');
    await shell.evaluate(async (appId) => {
      await window.platform.call('apps.updateMeta', { appId, favorite: true });
      // Let refresh requests triggered by this unrelated change settle before checking status.
      await new Promise((resolve) => setTimeout(resolve, 500));
    }, instance.id);
    assert.equal(await status(), 'stopped', 'Workspace refresh must respect an explicit stop');
    checks.push('explicit stop remains effective across unrelated workspace refreshes');
    await shell.getByRole('button', { name: instance.name, exact: true }).click();
    await interactive(shellId);
    checks.push('reopening the currently selected stopped app starts its custom screen again');

    await shell.evaluate(async (appId) => {
      await window.platform.call('settings.set', { key: 'restoreLastApp', value: true });
      localStorage.setItem('lastApp', appId);
    }, instance.id);
    await stop();
    await shell.reload();
    await interactive(shellId);
    checks.push('restoring the last app on workspace startup starts a stopped app');
    await shell.getByRole('button', { name: 'Главная', exact: true }).click();

    for (const mode of ['window', 'overlay']) {
      await stop();
      const opened = app.waitForEvent('window');
      const id = await shell.evaluate(
        ({ appId, mode }) => window.platform.call('windows.open', { appId, mode }),
        { appId: instance.id, mode },
      );
      const page = await opened;
      await page.locator('.standalone-app').waitFor();
      await interactive(id);
      checks.push(`${mode} opens a stopped app automatically`);
      await stop();
      const reused = await shell.evaluate(
        ({ appId, mode }) => window.platform.call('windows.open', { appId, mode }),
        { appId: instance.id, mode },
      );
      assert.equal(reused, id, 'Opening the same mode must reuse its existing native window');
      await interactive(id);
      checks.push(`${mode} reuses its existing window and restarts its stopped app`);
      const closed = page.waitForEvent('close');
      await app.evaluate(({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.close(), id);
      await closed;
    }
    assert.deepEqual(errors, []);
    await mkdir('artifacts', { recursive: true });
    await writeFile(
      'artifacts/auto-start-smoke.json',
      JSON.stringify({ passed: true, checks, rendererErrors: errors }, null, 2),
    );
    console.log('Auto-start smoke passed');
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}

void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
