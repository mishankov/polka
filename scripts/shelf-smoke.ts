import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { SettingsStore } from '../src/main/settings-store';
import { pressSettingsShortcut, pressAssistantShortcut } from './native-shortcuts';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-shelf-'));
  const settings = new SettingsStore(profile);
  // This workflow tests the shelf in isolation; media transitions have their own smoke test.
  await settings.handle('settings.set', { key: 'mediaIndicatorEnabled', value: false });
  settings.close();
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
    assert.equal(
      await app.evaluate(({ Menu }) =>
        Menu.getApplicationMenu()!.items.some((item) => item.label === 'Файл'),
      ),
      false,
    );
    assert.equal(await app.evaluate(({ app }) => app.dock?.isVisible()), false);
    assert.equal(
      await app.evaluate(({ globalShortcut }) =>
        globalShortcut.isRegistered('CommandOrControl+Alt+9'),
      ),
      false,
    );
    await page.evaluate(() => window.platform.call('launcher.show'));
    await expect(page.locator('.clipboard-shelf')).toHaveClass(/is-open/);
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
      assert.match(failure, /Неизвестная операция/);
    }
    await pressAssistantShortcut(app, page);
    await expect(page.locator('.agent-panel')).toHaveCount(0);
    await page.getByRole('button', { name: 'Настройки', exact: true }).click();
    await expect(page.getByRole('tab', { name: 'Основные', exact: true })).toHaveAttribute(
      'aria-selected',
      'true',
    );
    await page.getByRole('tab', { name: 'Полка и сочетания', exact: true }).click();
    const mediaSwitch = page.getByRole('switch', {
      name: 'Показывать активность камеры и микрофона',
      exact: true,
    });
    await expect(mediaSwitch).not.toBeChecked();
    await mediaSwitch.click();
    await expect(mediaSwitch).toBeChecked();
    assert.equal(
      (await page.evaluate(() => window.platform.call('mediaIndicator.getState'))).enabled,
      true,
    );
    await mediaSwitch.click();
    await expect(mediaSwitch).not.toBeChecked();
    const shortcut = page.getByRole('textbox', { name: 'Сочетание для запуска', exact: true });
    await shortcut.click();
    await page.keyboard.press('Escape');
    await expect(page.locator('.shelf-settings')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.getByRole('combobox', { name: 'Поиск по полке', exact: true })).toBeFocused();
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
    await expect(page.getByRole('heading', { name: 'Полка', exact: true })).toBeVisible();
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
    await expect(page.getByRole('combobox', { name: 'Поиск по полке', exact: true })).toBeFocused();
    await page
      .getByRole('combobox', { name: 'Поиск по полке', exact: true })
      .fill('zz-no-results-zz');
    await expect(page.getByText('Ничего не найдено. Попробуйте другое слово.')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Открыть рабочее пространство' })).toHaveCount(0);
    await page.getByRole('combobox', { name: 'Поиск по полке', exact: true }).fill('');
    await page.screenshot({ path: '/tmp/everything-shelf-launcher.png' });
    assert.equal(await app.evaluate(({ app }) => app.dock?.isVisible()), false);
    assert.deepEqual(errors, []);
    await app.close();
    const after = new SettingsStore(profile);
    assert.equal(await after.handle('settings.get', { key: 'mediaIndicatorEnabled' }), false);
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
      'Shelf smoke passed: hidden Dock icon, quiet startup, settings, native shortcuts, clipboard navigation, removed workspace entry points and persisted settings.',
    );
  } catch (error) {
    const failedPage = app.windows()[0];
    console.error(
      'Shelf state at failure:',
      await failedPage
        ?.evaluate(() => ({
          focused: document.hasFocus(),
          className: document.querySelector('.clipboard-shelf')?.className,
        }))
        .catch(() => 'Renderer unavailable'),
    );
    await failedPage?.screenshot({ path: '/tmp/polka-shelf-failure.png' }).catch(() => {});
    throw error;
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
