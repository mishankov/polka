import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pressSettingsShortcut } from './native-shortcuts';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-settings-shortcut-'));
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  const errors: string[] = [];
  app
    .context()
    .pages()
    .forEach((page) => page.on('pageerror', (error) => errors.push(error.message)));
  app.context().on('page', (page) => page.on('pageerror', (error) => errors.push(error.message)));
  try {
    let shell = await app.firstWindow();
    await shell.locator('.home-page').waitFor();
    const windows = () => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length);
    await pressSettingsShortcut(app, shell);
    await shell.locator('.settings-page').waitFor();
    assert.equal(await windows(), 1);
    // Repeating the shortcut reuses the existing workspace.
    await pressSettingsShortcut(app, shell);
    assert.equal(await windows(), 1);
    const accelerator = await app.evaluate(
      ({ Menu }) => Menu.getApplicationMenu()!.getMenuItemById('settings')!.accelerator,
    );
    assert.equal(accelerator, 'CommandOrControl+,');
    await shell.getByRole('button', { name: 'Главная', exact: true }).click();
    await shell.locator('.home-page').waitFor();
    await app.evaluate(({ Menu }) => {
      const item = Menu.getApplicationMenu()!.getMenuItemById('settings')!;
      item.click(item, undefined, {});
    });
    await shell.locator('.settings-page').waitFor();
    const instance = await shell.evaluate(async () => {
      const instance = await window.platform.call('apps.create', {
        definition: {
          schemaVersion: 1,
          name: 'Settings shortcut QA',
          entities: [],
          actions: [],
          automations: [],
          permissions: [],
          screens: [
            { id: 'custom', name: 'Экран', type: 'custom', config: { extensionId: 'custom' } },
          ],
          extensions: [
            {
              id: 'custom',
              name: 'Экран',
              kind: 'component',
              source:
                'export default function Screen(){return <button>Настройки из экрана</button>}',
            },
          ],
        },
      });
      await window.platform.call('settings.set', { key: 'restoreLastApp', value: true });
      localStorage.setItem('lastApp', instance.id);
      return instance;
    });
    const standaloneOpened = app.waitForEvent('window');
    await shell.evaluate((appId) => window.platform.call('windows.open', { appId }), instance.id);
    const standalone = await standaloneOpened;
    await standalone.locator('.standalone-titlebar').waitFor();
    await expect
      .poll(() =>
        app
          .context()
          .pages()
          .some((page) => page.url().startsWith('everything-extension:')),
      )
      .toBe(true);
    const extension = app
      .context()
      .pages()
      .find((page) => page.url().startsWith('everything-extension:'))!;
    await extension.getByRole('button', { name: 'Настройки из экрана', exact: true }).waitFor();
    let closed = shell.waitForEvent('close');
    await shell.evaluate(() => window.platform.call('windows.close'));
    await closed;
    const settingsOpened = app.waitForEvent('window');
    await pressSettingsShortcut(app, extension);
    shell = await settingsOpened;
    await shell.locator('.settings-page').waitFor();
    await expect(shell.locator('.home-page')).toHaveCount(0);
    await expect(shell.locator('.topbar')).toHaveCount(0);
    assert.equal(await windows(), 2);
    await shell.getByRole('button', { name: 'Главная', exact: true }).click();
    await shell.locator('.home-page').waitFor();
    await pressSettingsShortcut(app, standalone);
    await shell.locator('.settings-page').waitFor();
    assert.equal(await windows(), 2);
    // The launcher routes to full workspace settings, leaving app windows intact.
    closed = shell.waitForEvent('close');
    await shell.evaluate(() => window.platform.call('windows.close'));
    await closed;
    const launcherOpened = app.waitForEvent('window');
    await standalone.evaluate(() => window.platform.call('launcher.show'));
    const launcher = await launcherOpened;
    await launcher.locator('.launcher').waitFor();
    const workspaceOpened = app.waitForEvent('window');
    await pressSettingsShortcut(app, launcher);
    shell = await workspaceOpened;
    await shell.locator('.settings-page').waitFor();
    assert.equal(await windows(), 3);
    assert.equal(
      await app.evaluate(
        ({ BrowserWindow }, url) =>
          BrowserWindow.getAllWindows()
            .find((win) => win.webContents.getURL() === url)!
            .isVisible(),
        launcher.url(),
      ),
      false,
    );
    assert.deepEqual(errors, []);
    console.log(
      'Settings shortcut smoke passed: native Command-comma, menu command, window reuse, standalone/custom app views, launcher, closed workspace, and restoreLastApp does not override Settings.',
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
