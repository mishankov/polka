import { runDesktopTest, type DesktopTest } from './desktop-test';
import { expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { join, resolve } from 'node:path';
import { SettingsStore } from '../src/main/settings-store';
import { pressSettingsShortcut, pressAssistantShortcut } from './native-shortcuts';

async function main(test: DesktopTest) {
  const profile = test.profile;
  const settings = new SettingsStore(profile);
  // This workflow tests the shelf in isolation; media transitions have their own smoke test.
  await settings.handle('settings.set', { key: 'mediaIndicatorEnabled', value: false });
  settings.close();
  const launch = (hidden = false) =>
    test.launch({
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
      ['builtin:snippets', 'builtin:files', 'builtin:clipboard', 'builtin:emoji'],
    );
    const originalShortcut = (
      await page.evaluate(() => window.platform.call('launcher.getPreferences'))
    ).accelerator;
    await app.evaluate(({ globalShortcut }) => {
      const register = globalShortcut.register.bind(globalShortcut);
      globalShortcut.register = (accelerator, callback) => {
        (globalThis as any).__shelfToggle = callback;
        globalShortcut.register = register;
        return register(accelerator, callback);
      };
    });
    await page.evaluate(() =>
      window.platform.call('launcher.setShortcut', {
        accelerator: 'CommandOrControl+Alt+Shift+9',
      }),
    );
    for (const [method, searchName] of [
      ['clipboardHistory.show', 'Найти в истории'],
      ['shelf.showEmoji', 'Найти эмодзи'],
      ['shelf.showSnippets', 'Найти сниппет'],
    ]) {
      await page.evaluate((method) => window.platform.call(method), method);
      await test.shelfReady(app, page, searchName);
      await page.keyboard.press('Escape');
      await test.shelfHidden(app, page);
      await app.evaluate(({ app }) => app.emit('activate'));
      await expect(page.locator('.clipboard-shelf')).toHaveClass(/is-open/);
      await test.shelfReady(app, page, searchName);
      // Invoke the registered callback to exercise the shelf shortcut's toggle.
      await app.evaluate(() => (globalThis as any).__shelfToggle());
      await test.shelfHidden(app, page);
      await app.evaluate(() => (globalThis as any).__shelfToggle());
      await expect(page.locator('.clipboard-shelf')).toHaveClass(/is-open/);
      await test.shelfReady(app, page, searchName);
      await page.keyboard.press('Escape');
      await test.shelfHidden(app, page);
      await page.evaluate(() => window.platform.call('launcher.show'));
      await test.shelfReady(app, page, searchName);
      await app.evaluate(() => {
        (globalThis as any).__shelfClock = { read: Date.now, now: Date.now() };
        Date.now = () => (globalThis as any).__shelfClock.now;
      });
      try {
        await page.keyboard.press('Escape');
        await test.shelfHidden(app, page);
        await app.evaluate(({ app }) => {
          (globalThis as any).__shelfClock.now += 59_999;
          app.emit('activate');
        });
        await expect(page.locator('.clipboard-shelf')).toHaveClass(/is-open/);
        await test.shelfReady(app, page, searchName);
        // A minute spent in the open app must not reset its destination.
        await app.evaluate(() => ((globalThis as any).__shelfClock.now += 60_000));
        await page.evaluate(() => window.platform.call('launcher.show'));
        await test.shelfReady(app, page, searchName);
        await page.keyboard.press('Escape');
        await test.shelfHidden(app, page);
        await app.evaluate(() => ((globalThis as any).__shelfClock.now += 59_999));
        // Repeated hide requests must not restart the closed shelf's timeout.
        await page.evaluate(() => window.platform.call('launcher.hide'));
        await app.evaluate(() => {
          (globalThis as any).__shelfClock.now += 1;
          (globalThis as any).__shelfToggle();
        });
        await test.shelfReady(app, page, 'Поиск по полке');
        // An explicit built-in app opening still wins over the idle timeout.
        await page.keyboard.press('Escape');
        await test.shelfHidden(app, page);
        await app.evaluate(() => ((globalThis as any).__shelfClock.now += 60_000));
        await page.evaluate((method) => window.platform.call(method), method);
        await test.shelfReady(app, page, searchName);
      } finally {
        await app.evaluate(() => {
          Date.now = (globalThis as any).__shelfClock.read;
          delete (globalThis as any).__shelfClock;
        });
      }
      const builtinSearch = page.getByRole('combobox', { name: searchName, exact: true });
      await builtinSearch.fill(method === 'shelf.showEmoji' ? 'лайк' : 'retained query');
      if (method === 'shelf.showEmoji')
        await page.getByRole('combobox', { name: 'Оттенок кожи' }).selectOption('🏽');
      await builtinSearch.focus();
      const previousSession = (
        await page.evaluate(() => window.platform.call('shelf.presentation'))
      ).sessionId;
      await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .find((w) => w.webContents.getURL().includes('mode=shelf'))!
          .blur(),
      );
      await expect(page.locator('.clipboard-shelf')).toHaveClass(/is-closed/);
      assert.equal(
        (await page.evaluate(() => window.platform.call('clipboardHistory.state'))).pasteReady,
        false,
      );
      await app.evaluate(({ app }) => app.emit('activate'));
      await expect(page.locator('.clipboard-shelf')).toHaveClass(/is-open/);
      await expect(builtinSearch).toHaveValue(
        method === 'shelf.showEmoji' ? 'лайк' : 'retained query',
      );
      await expect(builtinSearch).toBeFocused();
      const next = await page.evaluate(() => window.platform.call('shelf.presentation'));
      assert(next.sessionId > previousSession);
      assert.equal(next.entryMode, 'resume');
      assert.equal(
        await app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows()
            .find((w) => w.webContents.getURL().includes('mode=shelf'))!
            .isFocused(),
        ),
        true,
      );
      if (method === 'shelf.showEmoji')
        await expect(page.getByRole('combobox', { name: 'Оттенок кожи' })).toHaveValue('🏽');
      await page.evaluate((method) => window.platform.call(method), method);
      await expect(builtinSearch).toHaveValue('');
      if (method === 'shelf.showEmoji')
        await expect(page.getByRole('combobox', { name: 'Оттенок кожи' })).toHaveValue('default');
      await page.getByRole('button', { name: 'Назад к приложениям', exact: true }).click();
      await expect(
        page.getByRole('combobox', { name: 'Поиск по полке', exact: true }),
      ).toBeFocused();
      await page.keyboard.press('Escape');
      await test.shelfHidden(app, page);
      await app.evaluate(({ app }) => app.emit('activate'));
      await expect(page.locator('.clipboard-shelf')).toHaveClass(/is-open/);
      await expect(
        page.getByRole('combobox', { name: 'Поиск по полке', exact: true }),
      ).toBeFocused();
    }
    await page.evaluate(
      (accelerator) => window.platform.call('launcher.setShortcut', { accelerator }),
      originalShortcut,
    );
    await app.evaluate(() => delete (globalThis as any).__shelfToggle);
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
    let [settings] = await Promise.all([
      app.waitForEvent('window'),
      page.getByRole('button', { name: 'Настройки', exact: true }).click(),
    ]);
    settings.on('pageerror', (error) => errors.push(error.message));
    const emojiPasteDenied = await settings.evaluate(async () => {
      try {
        await window.platform.call('shelf.selectEmoji', { id: '2764-fe0f' });
        return '';
      } catch (error) {
        return String(error);
      }
    });
    assert.match(emojiPasteDenied, /Операция доступна только на полке/);
    await expect(settings.getByRole('tab', { name: 'Основные', exact: true })).toHaveAttribute(
      'aria-selected',
      'true',
    );
    await expect(settings.locator('[class*="mantine-"]')).toHaveCount(0);
    await settings.getByRole('tab', { name: 'Полка и сочетания', exact: true }).click();
    const cameraSwitch = settings.getByRole('switch', {
      name: 'Показывать активность камеры',
      exact: true,
    });
    const microphoneSwitch = settings.getByRole('switch', {
      name: 'Показывать активность микрофона',
      exact: true,
    });
    await expect(cameraSwitch).not.toBeChecked();
    await expect(microphoneSwitch).not.toBeChecked();
    await cameraSwitch.click();
    await expect(cameraSwitch).toBeChecked();
    await expect(microphoneSwitch).not.toBeChecked();
    let mediaState = await settings.evaluate(() => window.platform.call('mediaIndicator.getState'));
    assert.equal(mediaState.cameraEnabled, true);
    assert.equal(mediaState.microphoneEnabled, false);
    assert.equal(mediaState.microphone, 'disabled');
    await cameraSwitch.click();
    await expect(cameraSwitch).not.toBeChecked();
    await microphoneSwitch.click();
    await expect(microphoneSwitch).toBeChecked();
    await expect(cameraSwitch).not.toBeChecked();
    mediaState = await settings.evaluate(() => window.platform.call('mediaIndicator.getState'));
    assert.equal(mediaState.cameraEnabled, false);
    assert.equal(mediaState.microphoneEnabled, true);
    assert.equal(mediaState.camera, 'disabled');
    await settings.screenshot({ path: '/tmp/everything-settings-media.png' });
    await microphoneSwitch.click();
    await expect(microphoneSwitch).not.toBeChecked();
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
    await expect(settings.getByRole('heading', { name: 'Полка', exact: true })).toBeVisible();
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
    await expect(
      page.getByRole('button', { name: 'Очистить историю на всех связанных Mac…' }),
    ).toBeDisabled();
    await page.keyboard.press('Escape');
    await expect(actions).toBeFocused();
    await expect(actions).toHaveAttribute('aria-expanded', 'false');
    await pressSettingsShortcut(app, page);
    for (let cycle = 0; cycle < 3; cycle++) {
      await Promise.all([settings.waitForEvent('close'), settings.evaluate(() => window.close())]);
      [settings] = await Promise.all([
        app.waitForEvent('window'),
        app.evaluate(async ({ Menu }) => {
          // Inspector evaluations can interrupt native window teardown. Dispatch
          // menu actions on the normal event loop, like a real menu selection.
          await new Promise<void>((resolve) => setImmediate(resolve));
          Menu.getApplicationMenu()!.getMenuItemById('settings')!.click();
        }),
      ]);
      settings.on('pageerror', (error) => errors.push(error.message));
      await expect(
        settings.getByRole('tab', { name: 'О приложении', exact: true }),
      ).toHaveAttribute('aria-selected', 'true');
    }
    await Promise.all([settings.waitForEvent('close'), settings.evaluate(() => window.close())]);
    // Reopening through macOS must reuse the shelf without adding a Dock icon.
    await app.evaluate(({ app }) => app.emit('activate'));
    await expect(page.getByRole('combobox', { name: 'Найти в истории' })).toBeFocused();
    await page.getByRole('button', { name: 'Назад к приложениям', exact: true }).click();
    await expect(page.getByRole('combobox', { name: 'Поиск по полке', exact: true })).toBeFocused();
    // A fresh macOS runner can still be discovering apps and extracting their icons.
    // Wait for the catalog before asserting an empty search; input focus alone does
    // not mean the results are ready. Keep ordinary interaction assertions short.
    await expect(page.getByRole('listbox', { name: 'Результаты поиска' })).toHaveAttribute(
      'aria-busy',
      'false',
      { timeout: 120_000 },
    );
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
    assert.equal(await app.evaluate(({ app }) => app.dock?.isVisible()), false);
    assert.deepEqual(errors, []);
    await test.close(app);
    const after = new SettingsStore(profile);
    assert.equal(await after.handle('settings.get', { key: 'mediaIndicatorEnabled' }), false);
    assert.deepEqual(await after.handle('settings.get', { key: 'mediaIndicatorTracking' }), {
      cameraEnabled: false,
      microphoneEnabled: false,
    });
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
      'Shelf smoke passed: hidden Dock icon, quiet startup, settings, native shortcuts, built-in app restoration, clipboard navigation, removed workspace entry points and persisted settings.',
    );
  } catch (error) {
    console.error('Shelf smoke failed:', error);
    console.error('Electron process:', {
      exitCode: app.process().exitCode,
      signalCode: app.process().signalCode,
    });
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
    await failedPage?.screenshot({ path: '/tmp/everything-shelf-failure.png' }).catch(() => {});
    throw error;
  }
}
void runDesktopTest('shelf', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
