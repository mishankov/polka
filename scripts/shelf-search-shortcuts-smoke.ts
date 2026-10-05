import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'polka-search-shortcuts-'));
  const entry = join(profile, 'main.cjs');
  const fixtureSource = stripTypeScriptTypes(
    await readFile(resolve('scripts/shelf-search-fixture.ts'), 'utf8'),
  ).replace('export function', 'function');
  await writeFile(
    entry,
    `
    const { app, BrowserWindow, ipcMain } = require('electron');
    app.setPath('userData', ${JSON.stringify(profile)});
    ${fixtureSource}
    const fixture = createShelfSearchFixture();
    ipcMain.handle('platform:call', (_, method, params) => fixture.call(method, params));
    global.fixture = fixture;
    app.whenReady().then(() => {
      const window = new BrowserWindow({ width: 720, height: 740, webPreferences: { preload: ${JSON.stringify(resolve('out/preload/index.js'))} } });
      fixture.onEvent(event => window.webContents.send('platform:event', event));
      window.loadFile(${JSON.stringify(resolve('out/renderer/index.html'))});
    });
  `,
  );
  const app = await electron.launch({ args: [entry] });
  try {
    const page = await app.firstWindow();
    const errors: string[] = [];
    page.on('pageerror', (error) => errors.push(error.message));
    const input = page.getByRole('combobox', { name: 'Поиск по полке', exact: true });
    const rows = page.locator('.launcher-result');
    const actions = () => app.evaluate(() => (globalThis as any).fixture.actions);
    const lastAction = async (method: string, params: Record<string, unknown>) => {
      await expect.poll(async () => (await actions()).at(-1)).toEqual({ method, params });
      await expect(page.locator('#launcher-results')).toHaveAttribute('aria-busy', 'false');
    };
    await expect(input).toBeFocused();
    await expect(rows).toHaveCount(11);
    assert.deepEqual(
      await rows.locator('kbd').allTextContents(),
      Array.from({ length: 9 }, (_, i) => `⌘${i + 1}`),
    );
    await expect(rows.nth(9)).not.toHaveAttribute('aria-keyshortcuts');
    await page.mouse.move(0, 0);
    await rows.first().focus();
    await input.focus();
    await page.evaluate(() =>
      Promise.all(document.getAnimations().map((animation) => animation.finished)),
    );
    await page.screenshot({
      path: '/tmp/everything-shelf-search-shortcuts-apps.png',
      scale: 'css',
    });

    await input.press('Meta+9');
    await lastAction('launcher.openMac', { id: 'mac:Safari' });
    await expect(rows.first()).toHaveAttribute('aria-selected', 'true');
    await input.press('ArrowUp');
    await expect(rows.last()).toHaveAttribute('aria-selected', 'true');
    await input.press('Enter');
    await lastAction('launcher.openMac', { id: 'mac:TextEdit' });

    await input.fill('2+2');
    await expect(rows).toHaveCount(6);
    await input.press('Meta+1');
    await lastAction('shelf.copyCalculation', { expression: '2+2' });
    await expect(rows.first()).toContainText('Скопировано');
    await expect(input).toBeFocused();
    await expect(rows.nth(1)).toHaveAttribute('aria-keyshortcuts', 'Meta+2');
    await page.evaluate(
      () =>
        new Promise<void>((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
        ),
    );
    await page.screenshot({
      path: '/tmp/everything-shelf-search-shortcuts-groups.png',
      scale: 'css',
    });
    await input.press('Meta+2');
    await lastAction('launcher.openMac', { id: 'mac:Calculator' });
    await input.press('Meta+3');
    await lastAction('clipboardHistory.select', { id: 'clip-3' });

    await input.fill('пример');
    await expect(rows).toHaveCount(4);
    assert.deepEqual(await rows.locator('kbd').allTextContents(), ['⌘1', '⌘2', '⌘3', '⌘4']);
    await input.press('Meta+2');
    await lastAction('clipboardHistory.select', { id: 'clip-2' });
    await expect(rows.first()).toHaveAttribute('aria-selected', 'true');
    await input.press('ArrowDown');
    await input.press('Shift+Enter');
    await lastAction('clipboardHistory.copy', { id: 'clip-2' });
    await rows.nth(2).click({ modifiers: ['Shift'] });
    await lastAction('clipboardHistory.copy', { id: 'clip-1' });
    await input.focus();

    // A pending action blocks number shortcuts, Enter and mouse activation together.
    await app.evaluate(() => (globalThis as any).fixture.hold());
    const beforePending = (await actions()).length;
    await input.press('Meta+1');
    await expect.poll(async () => (await actions()).length).toBe(beforePending + 1);
    await input.press('Meta+2');
    await input.press('Enter');
    await expect(rows.first()).toBeDisabled();
    assert.equal((await actions()).length, beforePending + 1);
    await app.evaluate(() => (globalThis as any).fixture.release());
    await expect(rows.first()).toBeEnabled();

    const beforeIgnored = (await actions()).length;
    for (const role of ['dialog', 'menu', 'listbox']) {
      await page.evaluate((role) => {
        const overlay = document.createElement('div');
        overlay.id = 'test-overlay';
        overlay.setAttribute('role', role);
        document.body.append(overlay);
      }, role);
      await input.press('Meta+1');
      await page.evaluate(() => document.getElementById('test-overlay')!.remove());
    }
    await input.evaluate((element) => {
      element.dispatchEvent(
        new KeyboardEvent('keydown', {
          key: '1',
          metaKey: true,
          isComposing: true,
          bubbles: true,
          cancelable: true,
        }),
      );
      element.dispatchEvent(
        new KeyboardEvent('keydown', {
          key: '1',
          metaKey: true,
          repeat: true,
          bubbles: true,
          cancelable: true,
        }),
      );
      const event = new KeyboardEvent('keydown', {
        key: '1',
        metaKey: true,
        bubbles: true,
        cancelable: true,
      });
      event.preventDefault();
      element.dispatchEvent(event);
    });
    await page.getByRole('button', { name: 'Настройки', exact: true }).focus();
    await page.keyboard.press('Meta+1');
    await input.focus();
    await input.press('Meta+9');
    await input.press('Control+1');
    await input.press('Alt+Meta+1');
    await input.press('Shift+Meta+1');
    await input.fill('nothing matches this');
    await expect(rows).toHaveCount(0);
    await input.press('Meta+1');
    assert.equal((await actions()).length, beforeIgnored);

    await input.fill('пример');
    await input.press('Meta+4');
    await expect(page.getByRole('combobox', { name: 'Найти в истории' })).toHaveValue('пример');
    assert.deepEqual((await actions()).at(-1), {
      method: 'clipboardHistory.show',
      params: { query: 'пример' },
    });
    const beforeHistory = (await actions()).length;
    await page.getByRole('combobox', { name: 'Найти в истории' }).press('Meta+1');
    assert.equal((await actions()).length, beforeHistory);

    await page.evaluate(() => window.platform.call('launcher.show'));
    await expect(input).toBeFocused();
    await input.press('Meta+1');
    await expect(page.getByRole('combobox', { name: 'Найти в истории' })).toHaveValue('');
    await page.evaluate(() => window.platform.call('shelf.settings'));
    await expect(page.getByRole('tab', { name: 'Основные', exact: true })).toBeVisible();
    const beforeSettings = (await actions()).length;
    await page.keyboard.press('Meta+1');
    assert.equal((await actions()).length, beforeSettings);
    assert.deepEqual(errors, []);
    console.log(
      'Shelf search shortcuts passed: displayed order, all result actions, query updates, pending actions, overlays, settings, history and existing navigation.',
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
