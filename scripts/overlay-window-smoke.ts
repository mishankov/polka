import { _electron as electron, expect, type Page } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-overlay-'));
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  const errors: string[] = [];
  app.on('window', (page) => page.on('pageerror', (error) => errors.push(error.message)));
  const shell = await app.firstWindow();
  const expectStandalone = async (page: Page) => {
    await expect(page.locator('.home-rail, .topbar, .agent-panel, .home-page')).toHaveCount(0);
    await expect(page.locator('.standalone-titlebar')).toBeVisible();
    assert.equal(
      await page
        .locator('.standalone-titlebar')
        .evaluate((element) => getComputedStyle(element).getPropertyValue('-webkit-app-region')),
      'drag',
    );
    await expect(page.getByRole('button', { name: 'Приложение', exact: true })).toHaveCount(0);
    await expect(page.getByRole('tab', { name: 'Записи', exact: true })).toBeVisible();
    await page.keyboard.press('Meta+j');
    await page.keyboard.press('Meta+k');
    await expect(page.locator('.agent-panel, [role="dialog"]')).toHaveCount(0);
  };
  const flags = (id: number) =>
    app.evaluate(({ BrowserWindow }, id) => {
      const win = BrowserWindow.fromId(id)!;
      return {
        id: win.id,
        alwaysOnTop: win.isAlwaysOnTop(),
        allWorkspaces: win.isVisibleOnAllWorkspaces(),
        bounds: win.getBounds(),
        contentBounds: win.getContentBounds(),
        appId: new URL(win.webContents.getURL()).searchParams.get('appId'),
      };
    }, id);
  try {
    await shell.waitForSelector('.home-page');
    await expect(shell.locator('.home-rail')).toBeVisible();
    const shellId = await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].id);
    const shellFlags = await flags(shellId);
    assert.equal(shellFlags.alwaysOnTop, false);
    assert.equal(shellFlags.allWorkspaces, false);
    const instance = await shell.evaluate(async () => {
      const instance = await window.platform.call('apps.create', {
        definition: {
          schemaVersion: 1,
          name: 'Панель для проверки',
          entities: [
            {
              id: 'items',
              name: 'Записи',
              fields: [{ id: 'title', name: 'Название', type: 'text' }],
            },
          ],
          screens: [
            { id: 'items', name: 'Записи', type: 'table', entityId: 'items' },
            {
              id: 'canvas',
              name: 'Рабочая область',
              type: 'custom',
              config: { extensionId: 'canvas' },
            },
          ],
          actions: [],
          automations: [],
          extensions: [
            {
              id: 'canvas',
              name: 'Рабочая область',
              kind: 'component',
              source:
                "import {useState} from 'react'; export default function Screen(){const [count,setCount]=useState(0);return <main style={{height:'100%',background:'#efe5d5'}}><h2>Моя рабочая область</h2><button onClick={()=>setCount(count+1)}>Нажатий: {count}</button></main>}",
            },
          ],
          permissions: [],
        },
      });
      await window.platform.call('apps.updateMeta', { appId: instance.id, status: 'running' });
      await window.platform.call('records.upsert', {
        appId: instance.id,
        entityId: 'items',
        values: { title: 'Запись в панели' },
      });
      return instance;
    });
    await shell.locator('.app-nav').filter({ hasText: instance.name }).first().click();
    await shell.getByText('Запись в панели', { exact: true }).waitFor();
    const opened = app.waitForEvent('window');
    await shell.getByRole('button', { name: 'Приложение', exact: true }).click();
    await expect(
      shell.getByRole('menuitem', { name: 'Панель поверх окон', exact: true }),
    ).toHaveCount(0);
    await expect(shell.getByRole('menuitem', { name: 'Компактное окно', exact: true })).toHaveCount(
      0,
    );
    await shell.getByRole('menuitem', { name: 'Открыть в отдельном окне', exact: true }).click();
    const overlay = await opened;
    await overlay.getByText('Запись в панели', { exact: true }).waitFor();
    await expectStandalone(overlay);
    await overlay.getByRole('button', { name: 'Добавить запись', exact: true }).click();
    await overlay
      .getByRole('textbox', { name: 'Название', exact: true })
      .fill('Создано в отдельном окне');
    await overlay.getByRole('button', { name: 'Сохранить запись', exact: true }).click();
    await overlay.getByText('Создано в отдельном окне', { exact: true }).waitFor();
    const overlayId = await app.evaluate(
      ({ BrowserWindow }, shellId) =>
        BrowserWindow.getAllWindows().find((win) => win.id !== shellId)!.id,
      shellId,
    );
    assert.equal((await flags(overlayId)).alwaysOnTop, false);
    await overlay.getByRole('button', { name: 'Настройки окна', exact: true }).click();
    const pin = overlay.getByRole('switch', { name: 'Поверх других окон', exact: true });
    await expect(pin).toBeEnabled();
    await pin.check();
    await expect.poll(async () => (await flags(overlayId)).alwaysOnTop).toBe(true);
    await mkdir('artifacts', { recursive: true });
    await overlay.screenshot({ path: 'artifacts/window-settings.png' });
    await overlay.keyboard.press('Escape');
    assert.equal(
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length),
      2,
    );
    const overlayFlags = await flags(overlayId);
    assert.equal(overlayFlags.appId, instance.id);
    if (process.platform === 'darwin') {
      assert.equal(
        overlayFlags.contentBounds.height,
        overlayFlags.bounds.height,
        'App content extends into the native title bar area',
      );
    }
    assert.equal(overlayFlags.alwaysOnTop, true);
    assert.equal(overlayFlags.allWorkspaces, true);

    const alternate = await shell.evaluate(async () => {
      const instance = await window.platform.call('apps.create', {
        definition: {
          schemaVersion: 1,
          name: 'Другое приложение',
          entities: [],
          screens: [],
          actions: [],
          automations: [],
          extensions: [],
          permissions: [],
        },
      });
      await window.platform.call('settings.set', { key: 'restoreLastApp', value: true });
      localStorage.setItem('lastApp', instance.id);
      return instance;
    });
    await overlay.reload();
    await overlay.getByText('Создано в отдельном окне', { exact: true }).waitFor();
    await expectStandalone(overlay);
    assert.equal(await overlay.evaluate(() => localStorage.getItem('lastApp')), alternate.id);
    assert.equal(
      await app.evaluate(
        ({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.getTitle(),
        overlayId,
      ),
      instance.name,
    );

    const movedBounds = await app.evaluate(({ BrowserWindow, screen }, id) => {
      const area = screen.getPrimaryDisplay().workArea;
      const win = BrowserWindow.fromId(id)!;
      win.setBounds({
        x: area.x + 30,
        y: area.y + 30,
        width: Math.min(680, area.width - 60),
        height: Math.min(480, area.height - 60),
      });
      // setBounds does not emit the macOS user-drag completion events.
      // Exercise the same persistence handlers after changing real native bounds.
      win.emit('moved');
      win.emit('resized');
      return win.getBounds();
    }, overlayId);
    await expect
      .poll(() =>
        shell.evaluate(
          (appId) => window.platform.call('settings.get', { key: `window:${appId}:window` }),
          instance.id,
        ),
      )
      .toEqual(movedBounds);
    const reopenedId = await shell.evaluate(
      (appId) => window.platform.call('windows.open', { appId, mode: 'overlay' }),
      instance.id,
    );
    assert.equal(
      reopenedId,
      overlayId,
      'Legacy overlay requests must reuse the ordinary app window',
    );
    assert.deepEqual((await flags(overlayId)).bounds, movedBounds);
    assert.equal(
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length),
      2,
    );

    const closed = overlay.waitForEvent('close');
    await app.evaluate(({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.close(), overlayId);
    await closed;
    const restoredPage = app.waitForEvent('window');
    const restoredId = await shell.evaluate(
      (appId) => window.platform.call('windows.open', { appId }),
      instance.id,
    );
    const restored = await restoredPage;
    await restored.getByText('Запись в панели', { exact: true }).waitFor();
    await restored.getByText('Создано в отдельном окне', { exact: true }).waitFor();
    await expectStandalone(restored);
    assert.notEqual(restoredId, overlayId);
    const restoredFlags = await flags(restoredId);
    assert.equal(restoredFlags.alwaysOnTop, true);
    assert.equal(restoredFlags.allWorkspaces, true);
    assert.deepEqual(restoredFlags.bounds, movedBounds);
    for (const mode of ['window', 'quick', 'overlay']) {
      const id = await shell.evaluate(
        ({ appId, mode }) => window.platform.call('windows.open', { appId, mode }),
        { appId: instance.id, mode },
      );
      assert.equal(id, restoredId, `${mode} must reuse the app's single window`);
      const state = await flags(id);
      assert.equal(state.alwaysOnTop, true, `${mode} must respect app preferences`);
      assert.equal(state.allWorkspaces, true, `${mode} must respect app preferences`);
      assert.equal(state.appId, instance.id);
    }
    assert.equal(
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length),
      2,
    );
    assert.equal((await flags(shellId)).alwaysOnTop, false);
    assert.equal((await flags(shellId)).allWorkspaces, false);
    // The same setting is available in app properties and updates every existing app window.
    await shell.getByRole('button', { name: 'Приложение', exact: true }).click();
    await shell.getByRole('menuitem', { name: 'Свойства и доступ', exact: true }).click();
    const appPin = shell.getByRole('switch', { name: 'Поверх других окон', exact: true });
    await expect(appPin).toBeChecked();
    await appPin.uncheck();
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows().every(
            (win) => !win.isAlwaysOnTop() && !win.isVisibleOnAllWorkspaces(),
          ),
        ),
      )
      .toBe(true);
    await shell.keyboard.press('Escape');
    await restored.getByRole('button', { name: 'Настройки окна', exact: true }).click();
    await expect(
      restored.getByRole('switch', { name: 'Поверх других окон', exact: true }),
    ).not.toBeChecked();
    await restored.keyboard.press('Escape');
    const extensionOpened = app.context().waitForEvent('page');
    await restored.getByRole('tab', { name: 'Рабочая область', exact: true }).click();
    const extension = await extensionOpened;
    await extension.getByRole('heading', { name: 'Моя рабочая область', exact: true }).waitFor();
    await expect(restored.getByRole('button', { name: 'Меню экрана', exact: true })).toHaveCount(0);
    await extension.getByRole('button', { name: 'Нажатий: 0', exact: true }).click();
    await expect(extension.getByRole('button', { name: 'Нажатий: 1', exact: true })).toBeVisible();
    await expect
      .poll(
        async () => {
          const viewport = await restored.evaluate(() => ({
            width: innerWidth,
            height: innerHeight,
            contentY: document.querySelector('.standalone-content')!.getBoundingClientRect().top,
          }));
          const views = await app.evaluate(
            ({ BrowserWindow }, id) =>
              (BrowserWindow.fromId(id)!.contentView.children as any[])
                .filter((view) => view.webContents)
                .map((view) => ({ bounds: view.getBounds(), visible: view.getVisible() })),
            restoredId,
          );
          return views.some(
            ({ bounds, visible }) =>
              visible &&
              bounds.x <= 1 &&
              bounds.width >= viewport.width - 2 &&
              bounds.y >= viewport.contentY &&
              bounds.y < viewport.contentY + 70 &&
              bounds.y + bounds.height >= viewport.height - 2,
          );
        },
        { message: 'Custom app content fills available window beneath its own tabs' },
      )
      .toBe(true);
    await restored.getByRole('tab', { name: 'Записи', exact: true }).click();
    await restored.getByText('Создано в отдельном окне', { exact: true }).waitFor();
    await shell.evaluate(async (appId) => {
      const current = await window.platform.call('apps.get', { appId });
      current.definition.screens = current.definition.screens.filter(
        (screen: any) => screen.id === 'canvas',
      );
      const draft = await window.platform.call('definitions.prepare', {
        appId,
        definition: current.definition,
      });
      await window.platform.call('definitions.activate', { draftId: draft.draftId });
    }, instance.id);
    await expect(restored.getByRole('tablist')).toHaveCount(0);
    await expect
      .poll(
        async () => {
          const viewport = await restored.evaluate(() => ({
            width: innerWidth,
            height: innerHeight,
            contentY: document.querySelector('.standalone-content')!.getBoundingClientRect().top,
          }));
          const views = await app.evaluate(
            ({ BrowserWindow }, id) =>
              (BrowserWindow.fromId(id)!.contentView.children as any[])
                .filter((view) => view.webContents)
                .map((view) => ({ bounds: view.getBounds(), visible: view.getVisible() })),
            restoredId,
          );
          return views.some(
            ({ bounds, visible }) =>
              visible &&
              bounds.x <= 1 &&
              Math.abs(bounds.y - viewport.contentY) <= 1 &&
              bounds.width >= viewport.width - 2 &&
              bounds.height >= viewport.height - viewport.contentY - 2,
          );
        },
        { message: 'A single custom screen fills the entire content area without platform tabs' },
      )
      .toBe(true);
    assert.deepEqual(errors, []);
    await mkdir('artifacts', { recursive: true });
    await restored.screenshot({ path: 'artifacts/overlay-window.png' });
    const viewURL = await app.evaluate(
      ({ BrowserWindow }, id) =>
        (BrowserWindow.fromId(id)!.contentView.children as any[])
          .find((view) => view.webContents)
          ?.webContents.getURL(),
      restoredId,
    );
    const nativePage = app
      .context()
      .pages()
      .find((page) => page.url() === viewURL);
    assert(nativePage, 'Standalone native app screen must have an isolated renderer');
    await nativePage.getByRole('heading', { name: 'Моя рабочая область', exact: true }).waitFor();
    await nativePage.screenshot({ path: 'artifacts/overlay-window-content.png' });
    await writeFile(
      'artifacts/overlay-window-smoke.json',
      JSON.stringify(
        {
          passed: true,
          checks: [
            'ordinary window opens from app menu; separate overlay command removed',
            'saved per-app setting pins the existing window without creating another',
            'setting persists across close/reopen; legacy compact and overlay requests reuse the same window',
            'app properties and standalone settings agree; disabling unpins all app windows immediately',
            'native always-on-top and all-workspaces flags enabled',
            'correct app content',
            'standalone windows integrate native controls with a themed draggable title bar and omit shell navigation, assistant and shell keyboard shortcuts',
            'record creation persists across reload and reopening',
            'restoreLastApp preference does not replace the standalone target app',
            'custom screen remains interactive and fills available native window area',
            'single custom screen hides platform tabs and fills entire content area',
            'existing window reused without resetting bounds',
            'bounds saved after simulated move/resize completion, restored with native flags after closing and reopening',
            'shell remains unpinned regardless of app preference',
          ],
          limitation:
            'Checks native Electron window flags and real bounds with simulated move/resize completion events; does not perform manual dragging or switching macOS Spaces or full-screen apps.',
          overlay: restoredFlags,
        },
        null,
        2,
      ),
    );
    console.log('Overlay window smoke passed');
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}

void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
