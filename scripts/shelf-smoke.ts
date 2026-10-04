import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { CoreService } from '../src/core/service';
import { pressSettingsShortcut, pressAssistantShortcut } from './native-shortcuts';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-shelf-'));
  const core = new CoreService(profile);
  const definition = {
    schemaVersion: 1,
    name: 'Dormant app',
    entities: [],
    screens: [],
    actions: [],
    automations: [],
    extensions: [],
    permissions: [],
  };
  const saved = await core.handle('apps.create', { definition });
  const jobs = [{ id: 'saved-queued-job', appId: saved.id, actionId: 'later', status: 'queued' }];
  const runs = [{ id: 'saved-run', status: 'waiting_approval' }];
  await core.handle('state.set', { key: 'runtime.jobs', value: jobs });
  await core.handle('state.set', { key: 'runtime.runs', value: runs });
  await core.handle('settings.set', {
    key: `shortcut:${saved.id}`,
    value: 'CommandOrControl+Alt+9',
  });
  core.close();
  const launch = (hidden = false) =>
    electron.launch({
      ...(process.env.EVERYTHING_EXECUTABLE
        ? {
            executablePath: resolve(process.env.EVERYTHING_EXECUTABLE),
            args: hidden ? ['--hidden'] : [],
            cwd: profile,
          }
        : { args: [resolve('.'), ...(hidden ? ['--hidden'] : [])] }),
      env: { ...process.env, EVERYTHING_PROFILE: profile },
    });
  let app = await launch();
  const errors: string[] = [];
  try {
    const page = await app.firstWindow();
    page.on('pageerror', (error) => errors.push(error.message));
    await expect(
      page.getByRole('combobox', { name: 'Найти приложение', exact: true }),
    ).toBeFocused();
    await expect(page.locator('.home-page')).toHaveCount(0);
    assert.equal(
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length),
      1,
    );
    assert.equal(await app.evaluate(({ app }) => app.dock?.isVisible()), false);
    assert.equal(
      await app.evaluate(({ globalShortcut }) =>
        globalShortcut.isRegistered('CommandOrControl+Alt+9'),
      ),
      false,
    );
    await page.getByRole('button', { name: 'Понятно', exact: true }).click();
    await expect(page.locator('.shelf-welcome')).toHaveCount(0);
    assert.equal(
      (await page.evaluate(() => window.platform.call('launcher.getPreferences'))).registered,
      true,
    );
    const apps = await page.evaluate(() => window.platform.call('launcher.apps'));
    assert.deepEqual(
      apps.map((item: any) => item.id),
      ['builtin:clipboard'],
    );
    for (const method of [
      'apps.list',
      'apps.create',
      'agent.send',
      'provider.get',
      'launcher.open',
      'windows.open',
      'system.shortcut',
      'packages.importPreview',
    ]) {
      const failure = await page.evaluate(async (method) => {
        try {
          await window.platform.call(method, {});
          return '';
        } catch (error) {
          return String(error);
        }
      }, method);
      assert.match(failure, /временно приостановлены/);
    }
    await pressAssistantShortcut(app, page);
    await expect(page.locator('.agent-panel')).toHaveCount(0);
    await page.getByRole('button', { name: 'Настройки', exact: true }).click();
    await expect(page.getByRole('tab', { name: 'Основные', exact: true })).toHaveAttribute(
      'aria-selected',
      'true',
    );
    await page.getByRole('tab', { name: 'Полка и сочетания', exact: true }).click();
    const shortcut = page.getByRole('textbox', { name: 'Сочетание для запуска', exact: true });
    await shortcut.click();
    await page.keyboard.press('Escape');
    await expect(page.locator('.shelf-settings')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(
      page.getByRole('combobox', { name: 'Найти приложение', exact: true }),
    ).toBeFocused();
    await pressSettingsShortcut(app, page);
    await expect(page.locator('.shelf-settings')).toBeVisible();
    await pressSettingsShortcut(app, page);
    assert.equal(
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length),
      1,
    );
    await page.getByRole('tab', { name: 'Буфер обмена', exact: true }).click();
    await expect(
      page.getByRole('switch', { name: 'Сохранять скопированный текст и изображения' }),
    ).toBeEnabled();
    await page.screenshot({ path: '/tmp/everything-shelf-clipboard-settings.png' });
    await page.getByRole('tab', { name: 'О приложении', exact: true }).click();
    await expect(page.getByRole('heading', { name: 'Everything App', exact: true })).toBeVisible();
    await expect(page.getByText('Подключение AI', { exact: true })).toHaveCount(0);
    await page.screenshot({ path: '/tmp/everything-shelf-about.png' });
    await page.getByRole('button', { name: 'Назад к приложениям', exact: true }).click();
    await page.getByRole('option', { name: /История буфера обмена/ }).click();
    await expect(page.getByRole('combobox', { name: 'Найти в истории' })).toBeFocused();
    await pressSettingsShortcut(app, page);
    await expect(page.locator('.shelf-settings')).toBeVisible();
    await page.getByRole('button', { name: 'Закрыть настройки', exact: true }).click();
    await expect
      .poll(() => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isVisible()))
      .toBe(false);
    // Reopening through macOS must reuse the shelf without adding a Dock icon.
    await app.evaluate(({ app }) => app.emit('activate'));
    await expect(
      page.getByRole('combobox', { name: 'Найти приложение', exact: true }),
    ).toBeFocused();
    await page
      .getByRole('combobox', { name: 'Найти приложение', exact: true })
      .fill('zz-no-results-zz');
    await expect(
      page.getByText('Приложения не найдены. Попробуйте другое название.'),
    ).toBeVisible();
    await expect(page.getByRole('button', { name: 'Открыть рабочее пространство' })).toHaveCount(0);
    await page.getByRole('combobox', { name: 'Найти приложение', exact: true }).fill('');
    await page.screenshot({ path: '/tmp/everything-shelf-launcher.png' });
    const hiddenMenu = await app.evaluate(
      ({ Menu }) => Menu.getApplicationMenu()!.items.find((item) => item.label === 'Файл')!.visible,
    );
    assert.equal(hiddenMenu, false);
    assert.equal(await app.evaluate(({ app }) => app.dock?.isVisible()), false);
    assert.deepEqual(errors, []);
    await app.close();
    const after = new CoreService(profile);
    assert.deepEqual(await after.handle('apps.get', { appId: saved.id }), saved);
    assert.deepEqual(await after.handle('state.get', { key: 'runtime.jobs' }), jobs);
    assert.deepEqual(await after.handle('state.get', { key: 'runtime.runs' }), runs);
    after.close();
    app = await launch(true);
    // Wait for readiness through the menu, without creating or displaying a window.
    await expect
      .poll(() =>
        app.evaluate(({ Menu }) => !!Menu.getApplicationMenu()?.getMenuItemById('settings')),
      )
      .toBe(true);
    assert.equal(
      await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows().some((win) => win.isVisible()),
      ),
      false,
    );
    assert.equal(await app.evaluate(({ app }) => app.dock?.isVisible()), false);
    await app.evaluate(({ app }) => app.emit('activate'));
    const reopened = await app.firstWindow();
    await expect(
      reopened.getByRole('combobox', { name: 'Найти приложение', exact: true }),
    ).toBeFocused();
    await expect(reopened.locator('.shelf-welcome')).toHaveCount(0);
    assert.equal(await app.evaluate(({ app }) => app.dock?.isVisible()), false);
    console.log(
      'Shelf smoke passed: hidden Dock icon, quiet startup, settings, native shortcuts, clipboard navigation, frozen entry points and preserved app/job data.',
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
