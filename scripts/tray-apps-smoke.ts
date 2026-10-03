import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-tray-'));
  const launch = () =>
    electron.launch({
      ...(process.env.EVERYTHING_EXECUTABLE
        ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
        : { args: [resolve('.')] }),
      env: { ...process.env, EVERYTHING_PROFILE: profile },
    });
  let app = await launch();
  const errors: string[] = [];
  app.context().on('page', (page) => page.on('pageerror', (error) => errors.push(error.message)));
  try {
    const shell = await app.firstWindow();
    await shell.locator('.home-page').waitFor();
    // Capture the real native menu while retaining Electron's normal tray behavior.
    await app.evaluate(({ Tray }) => {
      const original = Tray.prototype.setContextMenu;
      Tray.prototype.setContextMenu = function (menu) {
        (globalThis as any).__trayMenu = menu;
        return original.call(this, menu);
      };
      (globalThis as any).__trayErrors = [];
      process.on('unhandledRejection', (error) => {
        (globalThis as any).__trayErrors.push(String(error));
      });
    });
    const create = (name: string) =>
      shell.evaluate(
        (name) =>
          window.platform.call('apps.create', {
            definition: {
              schemaVersion: 1,
              name,
              entities: [],
              screens: [],
              actions: [],
              automations: [],
              extensions: [],
              permissions: [],
            },
          }),
        name,
      );
    const items = () =>
      app.evaluate(() =>
        ((globalThis as any).__trayMenu?.items || []).map((item: any) => ({
          id: item.id,
          label: item.label,
          enabled: item.enabled,
        })),
      );
    const appItems = async () => (await items()).filter((item: any) => item.id?.startsWith('app:'));
    const click = (id: string) =>
      app.evaluate((_, id) => {
        const menu = (globalThis as any).__trayMenu;
        const item = menu.getMenuItemById(`app:${id}`);
        item.click(item, undefined, {});
      }, id);
    const appWindows = () =>
      app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .filter((win) => win.webContents.getURL().includes('appId='))
          .map((win) => ({
            id: win.id,
            url: win.webContents.getURL(),
            alwaysOnTop: win.isAlwaysOnTop(),
          })),
      );
    const first = await create('Альфа');
    const second = await create('Бета');
    await expect
      .poll(async () => (await appItems()).map((item: any) => item.label))
      .toEqual(['Альфа', 'Бета']);
    assert.equal(
      await shell
        .evaluate((appId) => window.platform.call('apps.get', { appId }), first.id)
        .then((instance) => instance.status),
      'stopped',
    );
    await shell.evaluate(
      (appId) => window.platform.call('windows.setPreferences', { appId, alwaysOnTop: true }),
      first.id,
    );
    for (const instance of [first, second]) {
      const opened = app.waitForEvent('window');
      await click(instance.id);
      const page = await opened;
      await expect(page.locator('.standalone-titlebar')).toHaveText(instance.name);
      assert(new URL(page.url()).searchParams.get('appId') === instance.id);
    }
    await expect.poll(async () => (await appWindows()).length).toBe(2);
    assert.equal((await appWindows()).find((win) => win.url.includes(first.id))!.alwaysOnTop, true);
    assert.equal(
      (await appWindows()).find((win) => win.url.includes(second.id))!.alwaysOnTop,
      false,
    );
    await expect(shell.locator('.home-page')).toBeVisible();
    const firstWindow = (await appWindows()).find((win) => win.url.includes(first.id))!;
    await app.evaluate(
      ({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.minimize(),
      firstWindow.id,
    );
    await click(first.id);
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }, id) => {
          const win = BrowserWindow.fromId(id)!;
          return !win.isMinimized() && win.isFocused();
        }, firstWindow.id),
      )
      .toBe(true);
    assert.equal((await appWindows()).length, 2, 'Reopening must reuse the app window');
    await shell.evaluate(async (appId) => {
      await window.platform.call('apps.updateMeta', { appId, name: 'Новое имя', favorite: true });
    }, second.id);
    await expect
      .poll(async () => (await appItems()).map((item: any) => item.label))
      .toEqual(['Новое имя', 'Альфа']);
    // The tray remains useful after the workspace closes.
    await app.evaluate(({ BrowserWindow }) => {
      BrowserWindow.getAllWindows()
        .find((win) => !win.webContents.getURL().includes('appId='))!
        .close();
    });
    await expect.poll(() => shell.isClosed()).toBe(true);
    const firstPage = app.windows().find((page) => page.url().includes(first.id))!;
    await firstPage.evaluate(
      async ({ first, second }) => {
        await window.platform.call('apps.updateMeta', { appId: first, status: 'archived' });
        await window.platform.call('apps.delete', { appId: second, confirm: true });
      },
      { first: first.id, second: second.id },
    );
    await expect.poll(appItems).toEqual([]);
    assert(
      (await items()).some((item: any) => item.label === 'Пока нет приложений' && !item.enabled),
    );
    await firstPage.evaluate(
      (appId) => window.platform.call('apps.updateMeta', { appId, status: 'stopped' }),
      first.id,
    );
    await expect.poll(async () => (await appItems()).length).toBe(1);
    await click(first.id);
    await expect
      .poll(() =>
        firstPage.evaluate(
          (appId) => window.platform.call('apps.get', { appId }).then((value) => value.status),
          first.id,
        ),
      )
      .toBe('running');
    assert.equal((await appWindows()).length, 2);
    assert.deepEqual(errors, []);
    assert.deepEqual(await app.evaluate(() => (globalThis as any).__trayErrors), []);
    await app.close();
    app = await launch();
    const restartedShell = await app.firstWindow();
    await restartedShell.locator('.home-page').waitFor();
    assert.deepEqual(
      await restartedShell.evaluate(
        (appId) => window.platform.call('windows.getPreferences', { appId }),
        first.id,
      ),
      { alwaysOnTop: true },
    );
    await restartedShell.evaluate(
      (appId) => window.platform.call('windows.open', { appId }),
      first.id,
    );
    assert.equal(
      (await appWindows())[0].alwaysOnTop,
      true,
      'App preference must survive a platform restart',
    );
    console.log(
      'Tray apps smoke passed: live list, separate windows, reuse, restore, rename, favorites, archive, delete, empty state, launch without workspace, and per-app pin preference across platform restart',
    );
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}

void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
