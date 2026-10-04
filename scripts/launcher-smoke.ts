import { _electron as electron, expect, type Page } from '@playwright/test';
import assert from 'node:assert/strict';
import { access, mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-launcher-'));
  const nativeName = `Everything Launcher QA ${Date.now()}`;
  const nativeBundle = join(profile, nativeName + '.app');
  const nativeLink = join(homedir(), 'Applications', nativeName + '.app');
  const nativeMarker = join(profile, 'native-launched');
  if (process.platform === 'darwin') {
    await mkdir(join(nativeBundle, 'Contents/MacOS'), { recursive: true });
    await writeFile(
      join(nativeBundle, 'Contents/Info.plist'),
      JSON.stringify({
        CFBundlePackageType: 'APPL',
        CFBundleIdentifier: `app.everything.launcher-qa-${Date.now()}`,
        CFBundleExecutable: 'main',
        CFBundleName: nativeName,
        LSUIElement: true,
      }),
    );
    await writeFile(
      join(nativeBundle, 'Contents/MacOS/main'),
      `#!/bin/sh\n/usr/bin/touch '${nativeMarker.replaceAll("'", "'\\''")}'\n`,
      { mode: 0o755 },
    );
    const { execFile } = await import('node:child_process');
    const { promisify } = await import('node:util');
    await promisify(execFile)('/usr/bin/plutil', [
      '-convert',
      'xml1',
      join(nativeBundle, 'Contents/Info.plist'),
    ]);
    await mkdir(join(homedir(), 'Applications'), { recursive: true });
    await symlink(nativeBundle, nativeLink);
  }
  const launch = () =>
    electron.launch({
      ...(process.env.EVERYTHING_EXECUTABLE
        ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
        : { args: [resolve('.')] }),
      env: { ...process.env, EVERYTHING_PROFILE: profile },
    });
  let app = await launch();
  let quit = false;
  const errors: string[] = [];
  const watch = (page: Page) => page.on('pageerror', (error) => errors.push(error.message));
  app.context().pages().forEach(watch);
  app.context().on('page', watch);
  try {
    let shell = await app.firstWindow();
    await shell.locator('.home-page').waitFor();
    await expect
      .poll(() =>
        shell.evaluate(() =>
          window.platform.call('launcher.getPreferences').then((p) => p.registered),
        ),
      )
      .toBe(true);
    const opened = app.waitForEvent('window');
    // Rapid entry changes during lazy window creation must not lose the final
    // destination or wait for a draft acknowledgement from an unmounted renderer.
    await shell.evaluate(() =>
      Promise.all([
        window.platform.call('launcher.show'),
        window.platform.call('clipboardHistory.show'),
        window.platform.call('launcher.show'),
      ]),
    );
    let panel = await opened;
    const search = panel.getByRole('combobox', { name: 'Найти приложение' });
    if (process.platform === 'darwin') {
      await expect
        .poll(() => panel.locator('.launcher-result[data-kind="mac"]').count(), { timeout: 15000 })
        .toBeGreaterThan(0);
      const listed = await panel.evaluate(() => window.platform.call('launcher.macApps'));
      assert(
        listed.some((entry: any) => entry.name === nativeName),
        'User Applications bundles are discovered',
      );
      assert(
        listed.some((entry: any) => entry.name === 'Calculator'),
        'System apps are discovered',
      );
      assert(
        listed.some((entry: any) => entry.icon.startsWith('data:image/png')),
        'Native icons are available',
      );
      assert(
        new Set(listed.map((entry: any) => entry.icon).filter(Boolean)).size > 1,
        'App-specific icons are distinct, rather than generic bundle icons',
      );
      await search.fill(nativeName);
      await expect(panel.getByRole('option')).toHaveCount(1);
      await expect(panel.getByRole('option').locator('img')).toBeVisible();
      // First exercise native-launch failure while retaining the result for retry.
      await app.evaluate(({ shell }) => {
        (globalThis as any).__originalOpenPath = shell.openPath;
        shell.openPath = async () => 'QA launch failed';
      });
      await search.press('Enter');
      await panel.getByText(/QA launch failed/).waitFor();
      await expect(panel.getByRole('option')).toHaveCount(1);
      await app.evaluate(({ shell }) => {
        shell.openPath = (globalThis as any).__originalOpenPath;
      });
    }
    const panelId = await app.evaluate(
      ({ BrowserWindow }) =>
        BrowserWindow.getAllWindows().find((win) =>
          win.webContents.getURL().includes('mode=shelf'),
        )!.id,
    );
    const visible = () =>
      app.evaluate(({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.isVisible(), panelId);
    if (process.platform === 'darwin') {
      await search.press('Enter');
      await expect
        .poll(
          async () =>
            access(nativeMarker).then(
              () => true,
              () => false,
            ),
          { timeout: 15000 },
        )
        .toBe(true);
      await expect.poll(visible).toBe(false);
      assert.equal(
        await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length),
        2,
        'Native launch does not create an embedded app window',
      );
      await shell.evaluate(() => window.platform.call('launcher.show'));
      await search.fill('');
      await expect(panel.locator('.launcher-app-header')).toHaveCount(0);
    }
    await search.fill('clipboard');
    await expect(panel.getByRole('option')).toHaveCount(1);
    await search.press('Enter');
    const clipboardSearch = panel.getByRole('combobox', { name: 'Найти в истории' });
    await expect(clipboardSearch).toBeFocused();
    assert.equal(
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length),
      2,
    );
    await clipboardSearch.fill('abc');
    await clipboardSearch.press('Backspace');
    await expect(clipboardSearch).toHaveValue('ab');
    await clipboardSearch.fill('');
    await clipboardSearch.press('Backspace');
    await expect(search).toBeFocused();
    await panel.keyboard.press('Escape');
    await expect.poll(visible).toBe(false);
    // Capture the registered callback and invoke that OS entrypoint deterministically.
    // Physical key delivery from another macOS app remains a manual check.
    await app.evaluate(({ globalShortcut }) => {
      const original = globalShortcut.register.bind(globalShortcut);
      globalShortcut.register = (key, callback) => {
        const result = original(key, callback);
        if (result) (globalThis as any).__launcherShortcut = callback;
        return result;
      };
      (globalThis as any).__launcherErrors = [];
      process.on('unhandledRejection', (error) =>
        (globalThis as any).__launcherErrors.push(String(error)),
      );
    });
    const accelerator = 'Control+Alt+Shift+F12';
    await shell.evaluate(
      (accelerator) => window.platform.call('launcher.setShortcut', { accelerator }),
      accelerator,
    );
    const instances = await shell.evaluate(async () => {
      const definition = {
        schemaVersion: 1,
        entities: [
          {
            id: 'items',
            name: 'Записи',
            fields: [{ id: 'title', name: 'Название', type: 'text' }],
          },
        ],
        screens: [{ id: 'list', name: 'Записи', type: 'table', entityId: 'items' }],
        actions: [],
        automations: [],
        extensions: [],
        permissions: [],
      };
      const first = await window.platform.call('apps.create', {
        definition: { ...definition, name: 'Альфа', description: 'Личные проекты' },
      });
      const second = await window.platform.call('apps.create', {
        definition: { ...definition, name: 'Бета', description: 'Рабочие задачи' },
      });
      await window.platform.call('apps.updateMeta', { appId: second.id, favorite: true });
      const archived = await window.platform.call('apps.create', {
        definition: { ...definition, name: 'Архив' },
      });
      await window.platform.call('apps.updateMeta', { appId: archived.id, status: 'archived' });
      const custom = await window.platform.call('apps.create', {
        definition: {
          ...definition,
          name: 'Полотно',
          screens: [
            { id: 'canvas', name: 'Полотно', type: 'custom', config: { extensionId: 'canvas' } },
          ],
          extensions: [
            {
              id: 'canvas',
              name: 'Полотно',
              kind: 'component',
              source:
                "import {useState} from 'react'; export default function Screen(){const [count,setCount]=useState(0);return <main><h2>Панель приложения</h2><button onClick={()=>setCount(count+1)}>Нажатий: {count}</button></main>}",
            },
          ],
        },
      });
      return { first, second, custom, archived };
    });
    const invokeHotkey = () => app.evaluate(() => (globalThis as any).__launcherShortcut());
    const shellClosed = shell.waitForEvent('close');
    await shell.evaluate(() => window.platform.call('windows.close'));
    await shellClosed;
    await invokeHotkey();
    await expect.poll(visible).toBe(true);
    await expect(panel.locator('.launcher-result[data-kind="everything"]')).toHaveCount(3);
    assert.match(await panel.getByRole('option').first().innerText(), /История буфера обмена/);
    assert.match(await panel.getByRole('option').nth(1).innerText(), /Бета/);
    await expect(search).toBeFocused();
    await search.fill('not-a-real-app-qa');
    await panel.getByText('Приложения не найдены. Попробуйте другое название.').waitFor();
    await search.fill('');
    await search.press('ArrowDown');
    await search.press('ArrowDown');
    await expect(panel.getByRole('option', { selected: true })).toContainText('Альфа');
    await mkdir('artifacts', { recursive: true });
    await panel.screenshot({ path: 'artifacts/launcher-search.png' });
    await search.press('Enter');
    await expect(panel.locator('.launcher-app-header')).toContainText('Альфа');
    assert.equal(
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length),
      1,
      'App opens inside the existing panel',
    );
    assert.equal(
      await panel.evaluate(
        (appId) => window.platform.call('apps.get', { appId }).then((p) => p.status),
        instances.first.id,
      ),
      'running',
    );
    await panel.getByRole('button', { name: 'Добавить запись', exact: true }).click();
    await panel
      .getByRole('textbox', { name: 'Название', exact: true })
      .fill('Запись из быстрого запуска');
    await panel.keyboard.press('Escape');
    await expect(panel.getByRole('dialog')).toHaveCount(0);
    assert.equal(await visible(), true, 'Escape closes the app dialog before the panel');
    await panel.getByRole('button', { name: 'Добавить запись', exact: true }).click();
    await panel
      .getByRole('textbox', { name: 'Название', exact: true })
      .fill('Запись из быстрого запуска');
    await panel.getByRole('button', { name: 'Сохранить запись', exact: true }).click();
    await expect(panel.getByRole('dialog')).toHaveCount(0);
    await panel.getByText('Запись из быстрого запуска', { exact: true }).waitFor();
    await panel.screenshot({ path: 'artifacts/launcher-app.png' });
    await panel.keyboard.press('Escape');
    await expect.poll(visible).toBe(false);
    await invokeHotkey();
    await expect.poll(visible).toBe(true);
    await expect(search).toBeFocused();
    await search.fill('Альфа');
    await search.press('Enter');
    await panel.getByText('Запись из быстрого запуска', { exact: true }).waitFor();
    await panel.getByRole('button', { name: 'Назад к приложениям', exact: true }).click();
    await search.fill('Полотно');
    await search.press('Enter');
    await expect(panel.locator('.launcher-app-header')).toContainText('Полотно');
    await expect
      .poll(() =>
        app
          .context()
          .pages()
          .some((p) => p.url().startsWith('everything-extension:')),
      )
      .toBe(true);
    const extension = app
      .context()
      .pages()
      .find((p) => p.url().startsWith('everything-extension:'))!;
    await extension.getByRole('button', { name: 'Нажатий: 0', exact: true }).click();
    await extension.getByRole('button', { name: 'Нажатий: 1', exact: true }).waitFor();
    // CDP keyboard input can bypass Electron's before-input-event in native child views.
    await app.evaluate(({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((entry) => entry.getURL() === url)!;
      contents.focus();
      contents.sendInputEvent({ type: 'keyDown', keyCode: 'Escape' });
      contents.sendInputEvent({ type: 'keyUp', keyCode: 'Escape' });
    }, extension.url());
    await expect.poll(visible).toBe(false);
    await invokeHotkey();
    await expect.poll(visible).toBe(true);
    await expect(search).toBeFocused();
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }) =>
            webContents
              .getAllWebContents()
              .filter((wc) => wc.getURL().startsWith('everything-extension:')).length,
        ),
      )
      .toBe(0);
    await search.fill('личные');
    await expect(panel.getByRole('option')).toHaveCount(1);
    await search.press('Enter');
    const separateOpened = app.waitForEvent('window');
    await panel.getByRole('button', { name: 'Открыть в отдельном окне', exact: true }).click();
    const separate = await separateOpened;
    await separate.getByText('Запись из быстрого запуска', { exact: true }).waitFor();
    await expect.poll(visible).toBe(false);
    // Opening the workspace must not reuse the launcher's appId-less window.
    const shellOpened = app.waitForEvent('window');
    await separate.evaluate(() => window.platform.call('windows.open'));
    shell = await shellOpened;
    await shell.locator('.home-page').waitFor();
    await shell.getByRole('button', { name: 'Настройки', exact: true }).click();
    const shortcut = shell.getByRole('textbox', { name: 'Сочетание для запуска', exact: true });
    await shortcut.click();
    await shortcut.press('Control+Alt+Shift+F11');
    await expect
      .poll(() =>
        shell.evaluate(() =>
          window.platform.call('launcher.getPreferences').then((p) => p.accelerator),
        ),
      )
      .toBe('Control+Alt+Shift+F11');
    assert.deepEqual(errors, []);
    assert.deepEqual(await app.evaluate(() => (globalThis as any).__launcherErrors), []);
    await app.close();
    quit = true;
    app = await launch();
    quit = false;
    shell = await app.firstWindow();
    await shell.locator('.home-page').waitFor();
    await expect
      .poll(() => shell.evaluate(() => window.platform.call('launcher.getPreferences')))
      .toEqual({ accelerator: 'Control+Alt+Shift+F11', registered: true });
    await shell.evaluate(() => window.platform.call('launcher.setShortcut', { accelerator: '' }));
    assert.equal(
      await app.evaluate(({ globalShortcut }) =>
        globalShortcut.isRegistered('Control+Alt+Shift+F11'),
      ),
      false,
    );
    await app.close();
    quit = true;
    app = await launch();
    quit = false;
    shell = await app.firstWindow();
    await shell.locator('.home-page').waitFor();
    await expect
      .poll(() => shell.evaluate(() => window.platform.call('launcher.getPreferences')))
      .toEqual({ accelerator: '', registered: false });
    const documents = await shell.evaluate(() =>
      window.platform.call('apps.create', {
        definition: {
          schemaVersion: 1,
          name: 'Черновики',
          entities: [],
          screens: [{ id: 'text', name: 'Текст', type: 'text' }],
          actions: [],
          automations: [],
          extensions: [],
          permissions: [],
        },
      }),
    );
    // Quit with a live hidden launcher, exercising document flush and its close policy.
    const finalOpened = app.waitForEvent('window');
    await shell.evaluate(() => window.platform.call('launcher.show'));
    panel = await finalOpened;
    await panel.locator('.launcher').waitFor();
    const docSearch = panel.getByRole('combobox', { name: 'Найти приложение' });
    await docSearch.fill('Черновики');
    await expect(panel.getByRole('option')).toHaveCount(1);
    await docSearch.press('Enter');
    await panel.getByRole('button', { name: 'Новый', exact: true }).click();
    await panel.locator('.cm-content').fill('Правка перед возвратом к поиску');
    await panel.getByRole('button', { name: 'Назад к приложениям', exact: true }).click();
    const saved = await panel.evaluate(
      (appId) => window.platform.call('docs.list', { appId }),
      documents.id,
    );
    assert.equal(saved[0].content, 'Правка перед возвратом к поиску');
    await docSearch.press('Enter');
    await expect(panel.locator('.cm-content')).toHaveText('Правка перед возвратом к поиску');
    await panel.locator('.cm-content').fill('Черновик перед буфером обмена');
    await panel.evaluate(() => window.platform.call('clipboardHistory.show'));
    await expect(panel.getByRole('combobox', { name: 'Найти в истории' })).toBeFocused();
    const switched = await panel.evaluate(
      (appId) => window.platform.call('docs.list', { appId }),
      documents.id,
    );
    assert.equal(switched[0].content, 'Черновик перед буфером обмена');
    await panel.evaluate(() => window.platform.call('launcher.show'));
    await docSearch.fill('Черновики');
    await docSearch.press('Enter');
    await panel.locator('.cm-content').fill('Последняя правка в скрытой панели');
    await panel.evaluate(() => window.platform.call('launcher.hide'));
    const closed = app.waitForEvent('close', { timeout: 15000 });
    await app.evaluate(({ app }) => {
      app.quit();
    });
    await closed;
    quit = true;
    app = await launch();
    quit = false;
    shell = await app.firstWindow();
    await shell.locator('.home-page').waitFor();
    const recovered = await shell.evaluate(
      (appId) => window.platform.call('docs.list', { appId }),
      documents.id,
    );
    assert.equal(recovered[0].content, 'Последняя правка в скрытой панели');
    console.log(
      'Launcher smoke passed: real native app launch and icons, launch failure/retry, embedded records and custom screens, keyboard search, hide/reopen, background hotkey callback, shortcut capture/persistence/disable, document drafts, normal windows, clean quit.',
    );
  } finally {
    if (!quit) await app.close();
    if (process.platform === 'darwin') await rm(nativeLink, { force: true });
    await rm(profile, { recursive: true, force: true });
  }
}
void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
