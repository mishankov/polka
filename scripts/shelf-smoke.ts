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
  // This workflow tests the shelf in isolation; media transitions have their own smoke test.
  await core.handle('settings.set', { key: 'mediaIndicatorEnabled', value: false });
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
    await expect(page.getByRole('combobox', { name: 'Поиск по полке', exact: true })).toBeFocused();
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
    const settingsCreated = app.waitForEvent('window');
    await page.getByRole('button', { name: 'Настройки', exact: true }).click();
    let settings = await settingsCreated;
    settings.on('pageerror', (error) => errors.push(error.message));
    await expect(settings.getByRole('tab', { name: 'Основные', exact: true })).toHaveAttribute(
      'aria-selected',
      'true',
    );
    await expect(settings.locator('[class*="mantine-"]')).toHaveCount(0);
    await settings.getByRole('tab', { name: 'Полка и сочетания', exact: true }).click();
    const mediaSwitch = settings.getByRole('switch', {
      name: 'Показывать активность камеры и микрофона',
      exact: true,
    });
    await expect(mediaSwitch).not.toBeChecked();
    await mediaSwitch.click();
    await expect(mediaSwitch).toBeChecked();
    assert.equal(
      (await settings.evaluate(() => window.platform.call('mediaIndicator.getState'))).enabled,
      true,
    );
    await mediaSwitch.click();
    await expect(mediaSwitch).not.toBeChecked();
    const shortcut = settings.getByRole('textbox', { name: 'Сочетание для запуска', exact: true });
    await shortcut.click();
    await settings.keyboard.press('Escape');
    await expect(settings.locator('.shelf-settings')).toBeVisible();
    await pressSettingsShortcut(app, settings);
    assert.equal(
      await app.evaluate(
        ({ BrowserWindow }) =>
          BrowserWindow.getAllWindows().filter((w) =>
            w.webContents.getURL().includes('mode=settings'),
          ).length,
      ),
      1,
    );
    await settings.getByRole('tab', { name: 'Буфер обмена', exact: true }).click();
    await expect(
      settings.getByRole('switch', { name: 'Сохранять скопированный текст и изображения' }),
    ).toBeEnabled();
    for (const appearance of ['light', 'dark'] as const) {
      await app.evaluate(({ nativeTheme }, appearance) => {
        nativeTheme.themeSource = appearance;
      }, appearance);
      await expect(settings.locator('html')).toHaveAttribute('data-appearance', appearance);
      await settings.screenshot({ path: `/tmp/everything-settings-${appearance}.png` });
    }
    await settings.getByRole('tab', { name: 'О приложении', exact: true }).click();
    await expect(
      settings.getByRole('heading', { name: 'Everything App', exact: true }),
    ).toBeVisible();
    await settings.getByRole('button', { name: 'Открыть полку' }).click();
    // Switching to the transient shelf must not dismiss the settings window.
    assert.equal(
      await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .find((w) => w.webContents.getURL().includes('mode=settings'))!
          .isVisible(),
      ),
      true,
    );
    await expect(page.getByRole('combobox', { name: 'Поиск по полке', exact: true })).toBeFocused();
    await page.getByRole('option', { name: /История буфера обмена/ }).click();
    await expect(page.getByRole('combobox', { name: 'Найти в истории' })).toBeFocused();
    const actions = page.getByRole('button', { name: 'Действия с историей' });
    await actions.click();
    await expect(page.getByRole('button', { name: 'Очистить историю…' })).toBeDisabled();
    await page.keyboard.press('Escape');
    await expect(actions).toBeFocused();
    await expect(actions).toHaveAttribute('aria-expanded', 'false');
    await pressSettingsShortcut(app, page);
    await app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows()
        .find((w) => w.webContents.getURL().includes('mode=settings'))!
        .close(),
    );
    const recreated = app.waitForEvent('window');
    await app.evaluate(({ Menu }) =>
      Menu.getApplicationMenu()!.getMenuItemById('settings')!.click(),
    );
    settings = await recreated;
    await expect(settings.getByRole('tab', { name: 'О приложении', exact: true })).toHaveAttribute(
      'aria-selected',
      'true',
    );
    await app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows()
        .find((w) => w.webContents.getURL().includes('mode=settings'))!
        .close(),
    );
    // Reopening through macOS must reuse the shelf without adding a Dock icon.
    await app.evaluate(({ app }) => app.emit('activate'));
    await expect(page.getByRole('combobox', { name: 'Поиск по полке', exact: true })).toBeFocused();
    await page
      .getByRole('combobox', { name: 'Поиск по полке', exact: true })
      .fill('zz-no-results-zz');
    await expect(page.getByText('Ничего не найдено. Попробуйте другое слово.')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Открыть рабочее пространство' })).toHaveCount(0);
    await page.getByRole('combobox', { name: 'Поиск по полке', exact: true }).fill('');
    for (const appearance of ['light', 'dark'] as const) {
      await app.evaluate(({ nativeTheme }, appearance) => {
        nativeTheme.themeSource = appearance;
      }, appearance);
      await expect(page.locator('html')).toHaveAttribute('data-appearance', appearance);
      await page.screenshot({ path: `/tmp/everything-launcher-${appearance}.png` });
    }
    await expect(page.locator('[class*="mantine-"]')).toHaveCount(0);
    const hiddenMenu = await app.evaluate(
      ({ Menu }) => Menu.getApplicationMenu()!.items.find((item) => item.label === 'Файл')!.visible,
    );
    assert.equal(hiddenMenu, false);
    assert.equal(await app.evaluate(({ app }) => app.dock?.isVisible()), false);
    assert.deepEqual(errors, []);
    await app.close();
    const after = new CoreService(profile);
    assert.equal(await after.handle('settings.get', { key: 'mediaIndicatorEnabled' }), false);
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
      reopened.getByRole('combobox', { name: 'Поиск по полке', exact: true }),
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
