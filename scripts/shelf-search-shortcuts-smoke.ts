import { runDesktopTest, type DesktopTest } from './desktop-test';
import { expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { join, resolve } from 'node:path';

async function main(test: DesktopTest) {
  const profile = test.profile;
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
      // Renderer interactions do not require OS activation or compete for native focus.
      const window = new BrowserWindow({ show: false, width: 720, height: 740, webPreferences: { preload: ${JSON.stringify(resolve('out/preload/index.js'))} } });
      fixture.onEvent(event => window.webContents.send('platform:event', event));
      window.loadFile(${JSON.stringify(resolve('out/renderer/index.html'))});
    });
  `,
  );
  const app = await test.launch({ args: [entry] });
  {
    const page = await app.firstWindow();
    const errors: string[] = [];
    page.on('pageerror', (error) => errors.push(error.message));
    const input = page.getByRole('combobox', { name: 'Поиск по полке', exact: true });
    const rows = page.locator('.launcher-result');
    const actions = () => app.evaluate(() => (globalThis as any).fixture.actions);
    const lastAction = async (method: string, params: Record<string, unknown>) => {
      await expect.poll(async () => (await actions()).at(-1)).toEqual({ method, params });
      await expect(
        page.locator('[role="listbox"][aria-busy], [role="grid"][aria-busy]'),
      ).toHaveAttribute('aria-busy', 'false');
    };
    await expect(input).toBeFocused();
    // This fixture opens from its initial snapshot without sending shelf.shown.
    // Cold startup must still acknowledge the rendered opening to the main process.
    await expect
      .poll(() => app.evaluate(() => (globalThis as any).fixture.shownRevisions))
      .toContain(0);
    await expect(rows).toHaveCount(11);
    await expect(rows.locator('kbd')).toHaveText(Array.from({ length: 9 }, (_, i) => `⌘${i + 1}`));
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
    await expect(rows.nth(1)).toContainText('Safari');
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

    await input.fill('10 inches in cm');
    await expect(rows.first()).toContainText('25.4 cm');
    await expect(rows.first()).toContainText('10 in → cm');
    await input.press('Enter');
    await lastAction('shelf.copyCalculation', { expression: '10 inches in cm' });
    await expect(rows.first()).toContainText('Скопировано');
    await expect(input).toBeFocused();
    await input.fill('100 метров в сантиметрах');
    await expect(rows.first()).toContainText('10000 cm');
    await expect(rows.first()).toContainText('100 m → cm');
    await input.press('Enter');
    await lastAction('shelf.copyCalculation', { expression: '100 метров в сантиметрах' });
    await expect(rows.first()).toContainText('Скопировано');
    await expect(input).toBeFocused();
    await input.fill('2026-07-15 18:00 Moscow in London');
    await expect(rows.first()).toContainText('16:00 Лондон');
    await expect(rows.first()).toContainText('2026-07-15');
    await expect(rows.first()).toContainText('UTC+01:00');
    await rows.first().click();
    await lastAction('shelf.copyCalculation', {
      expression: '2026-07-15 18:00 Moscow in London',
      sourceDate: '2026-07-15',
    });
    await expect(rows.first()).toContainText('Скопировано');
    await expect(input).toBeFocused();
    await page.screenshot({ path: '/tmp/everything-shelf-time-conversion.png', scale: 'css' });
    await input.fill('2026-11-01 01:30 New York in UTC');
    await expect(page.locator('.launcher-calculation-status')).toContainText('встречается дважды');
    await expect(rows).toHaveCount(0);
    const beforeInvalidConversion = (await actions()).length;
    await input.press('Enter');
    assert.equal((await actions()).length, beforeInvalidConversion);
    await input.fill('10 inches in');
    await expect(page.locator('.launcher-calculation-status')).toContainText(
      'Укажите единицу результата',
    );
    await expect(rows).toHaveCount(0);

    await input.fill('пример');
    await expect(rows).toHaveCount(4);
    await expect(rows.locator('kbd')).toHaveText(['⌘1', '⌘2', '⌘3', '⌘4']);
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

    // Matching and learned ranking must use the same order as arrows and number shortcuts.
    await input.fill('safri');
    await expect(rows).toHaveCount(1);
    await expect(rows.first()).toContainText('Safari');
    await input.press('Enter');
    await lastAction('launcher.openMac', { id: 'mac:Safari' });
    await input.fill('ЫФАФКШ');
    await expect(rows).toHaveCount(1);
    await input.press('Meta+1');
    await lastAction('launcher.openMac', { id: 'mac:Safari' });
    await input.fill('ut');
    await expect(rows).toHaveCount(1);
    await expect(rows.first()).toContainText('Terminal');
    await input.press('Meta+1');
    await lastAction('launcher.openMac', { id: 'mac:Terminal' });
    await input.fill('cal');
    await expect(rows).toHaveCount(2);
    await expect(rows.first()).toContainText('Calculator');
    await input.press('ArrowDown');
    await expect(rows.nth(1)).toHaveAttribute('aria-selected', 'true');
    await input.press('Enter');
    await lastAction('launcher.openMac', { id: 'mac:Calendar' });
    // The selected ID stays selected even when its row moves to the top.
    await expect(rows.first()).toContainText('Calendar');
    await expect(rows.first()).toHaveAttribute('aria-selected', 'true');
    await expect(rows.first()).toHaveAttribute('aria-keyshortcuts', 'Meta+1');
    await input.press('Meta+1');
    await lastAction('launcher.openMac', { id: 'mac:Calendar' });
    await page.evaluate(() => window.platform.call('launcher.show'));
    await expect(input).toHaveValue('');
    await input.fill('cal');
    await expect(rows.first()).toContainText('Calendar');
    await input.press('Meta+2');
    await lastAction('launcher.openMac', { id: 'mac:Calculator' });

    await input.fill('пример');
    await input.press('Meta+4');
    await expect(page.getByRole('combobox', { name: 'Найти в истории' })).toHaveValue('пример');
    assert.deepEqual((await actions()).at(-1), {
      method: 'clipboardHistory.show',
      params: { query: 'пример' },
    });
    const historyInput = page.getByRole('combobox', { name: 'Найти в истории' });
    const historyRows = page.locator('.clipboard-row');
    await expect(historyInput).toBeFocused();
    // Autofocus happens before the asynchronous history request has populated the rows.
    await expect(historyRows.locator('kbd')).toHaveText(['⌘1', '⌘2', '⌘3', '⌘4']);
    await historyInput.press('Meta+2');
    await lastAction('clipboardHistory.select', { id: 'clip-2' });
    await expect(historyRows.first().getByRole('option')).toHaveAttribute('aria-selected', 'true');

    await app.evaluate(() => (globalThis as any).fixture.setClipCount(12));
    await historyInput.fill('');
    await expect(historyRows).toHaveCount(12);
    await expect(historyRows.locator('kbd')).toHaveText(
      Array.from({ length: 9 }, (_, i) => `⌘${i + 1}`),
    );
    await expect(historyRows.nth(9).getByRole('option')).not.toHaveAttribute('aria-keyshortcuts');
    await historyInput.press('Meta+9');
    await lastAction('clipboardHistory.select', { id: 'clip-3' });
    // Pinning changes the same displayed order that number shortcuts use.
    await historyRows.last().getByRole('option').focus();
    await historyRows.last().getByRole('button', { name: 'Закрепить запись', exact: true }).click();
    await expect(historyRows.first()).toContainText('Заметка 1:');
    await historyInput.focus();
    await historyInput.press('Meta+1');
    await lastAction('clipboardHistory.select', { id: 'clip-0' });
    await historyInput.fill('Заметка 12:');
    await expect(historyRows).toHaveCount(1);
    await expect(historyRows.first().getByRole('option')).toHaveAttribute(
      'aria-keyshortcuts',
      'Meta+1',
    );
    await historyInput.press('Meta+1');
    await lastAction('clipboardHistory.select', { id: 'clip-11' });
    // select also remains the existing copy action when automatic paste is disabled.
    await app.evaluate(() => (globalThis as any).fixture.setPasteOnSelect(false));
    await expect(page.locator('.clipboard-footer')).toContainText('копировать');
    await historyInput.press('Meta+1');
    await lastAction('clipboardHistory.select', { id: 'clip-11' });
    await historyInput.press('Shift+Enter');
    await lastAction('clipboardHistory.copy', { id: 'clip-11' });

    const beforeHistoryIgnored = (await actions()).length;
    await historyInput.press('Meta+9');
    await historyInput.fill('no history matches');
    await expect(historyRows).toHaveCount(0);
    await historyInput.press('Meta+1');
    await historyInput.fill('');
    await expect(historyRows).toHaveCount(12);
    await historyInput.press('Meta+Enter');
    await expect(page.getByRole('region', { name: 'Просмотр записи' })).toBeVisible();
    await page.keyboard.press('Meta+1');
    await page.keyboard.press('Escape');
    await expect(historyInput).toBeFocused();
    const historyMenu = page.getByRole('button', { name: 'Действия с историей', exact: true });
    await historyMenu.click();
    // The history menu uses role=group; its explicit open state must guard the input too.
    await historyInput.dispatchEvent('keydown', {
      key: '1',
      metaKey: true,
      bubbles: true,
      cancelable: true,
    });
    await page.keyboard.press('Meta+1');
    await page
      .getByRole('button', { name: 'Очистить историю на всех связанных Mac…', exact: true })
      .click();
    await expect(
      page.getByRole('heading', { name: 'Удалить историю на всех связанных Mac?' }),
    ).toBeVisible();
    await page.keyboard.press('Meta+1');
    await page.keyboard.press('Escape');
    await expect(historyInput).toBeFocused();
    for (const role of ['dialog', 'menu', 'listbox']) {
      await page.evaluate((role) => {
        const overlay = document.createElement('div');
        overlay.id = 'test-history-overlay';
        overlay.setAttribute('role', role);
        document.body.append(overlay);
      }, role);
      await historyInput.press('Meta+1');
      await page.evaluate(() => document.getElementById('test-history-overlay')!.remove());
    }
    await historyInput.dispatchEvent('keydown', {
      key: '1',
      metaKey: true,
      isComposing: true,
      bubbles: true,
    });
    await historyInput.dispatchEvent('keydown', {
      key: '1',
      metaKey: true,
      repeat: true,
      bubbles: true,
    });
    assert.equal((await actions()).length, beforeHistoryIgnored);

    await app.evaluate(() => (globalThis as any).fixture.hold());
    await historyInput.press('Meta+1');
    await expect.poll(async () => (await actions()).length).toBe(beforeHistoryIgnored + 1);
    await historyInput.press('Meta+2');
    await historyInput.press('Enter');
    await expect(historyRows.first().getByRole('option')).toBeDisabled();
    assert.equal((await actions()).length, beforeHistoryIgnored + 1);
    await app.evaluate(() => (globalThis as any).fixture.release());
    await expect(historyRows.first().getByRole('option')).toBeEnabled();
    for (let i = 0; i < 9; i++) await historyInput.press('ArrowDown');
    await expect(historyRows.nth(9).getByRole('option')).toHaveAttribute('aria-selected', 'true');
    await historyInput.press('Enter');
    await lastAction('clipboardHistory.select', { id: 'clip-3' });
    await historyInput.fill('пример');
    await expect(historyRows.first().getByRole('option')).toHaveAttribute('aria-selected', 'true');
    await page.mouse.move(0, 0);
    await page.screenshot({ path: '/tmp/everything-clipboard-number-shortcuts.png', scale: 'css' });

    await page.evaluate(() => window.platform.call('launcher.show'));
    await expect(input).toBeFocused();
    await input.press('Meta+1');
    await expect(page.getByRole('combobox', { name: 'Найти в истории' })).toHaveValue('');

    // Emoji uses the same selection/copy gestures and permission states as history.
    await app.evaluate(() => {
      const fixture = (globalThis as any).fixture;
      fixture.setPasteOnSelect(true);
      fixture.setPasteAccess('required');
    });
    const allow = page.getByRole('button', { name: /Разрешить…$/ });
    await expect(allow).toBeVisible();
    await expect(page.locator('.clipboard-paste-permission')).toContainText('Универсальный доступ');
    await app.evaluate(() => (globalThis as any).fixture.navigate('emoji'));
    const emojiInput = page.getByRole('combobox', { name: 'Найти эмодзи', exact: true });
    const emojiGrid = page.getByRole('grid', { name: 'Эмодзи для вставки' });
    await expect(emojiInput).toBeFocused();
    await expect(allow).toBeVisible();
    await expect(page.locator('.clipboard-paste-permission')).toContainText(
      'эмодзи только копируется',
    );
    await expect(page.locator('.emoji-footer')).toContainText('копировать');
    await emojiInput.fill('🔥');
    await emojiInput.press('Enter');
    await lastAction('shelf.selectEmoji', { id: '1f525' });
    await emojiInput.press('Shift+Enter');
    await lastAction('shelf.copyEmoji', { id: '1f525' });
    await emojiInput.press('ArrowDown');
    await page.keyboard.press('Shift+Enter');
    await lastAction('shelf.copyEmoji', { id: '1f525' });
    const fire = emojiGrid.getByRole('gridcell', { name: 'огонь · fire', exact: true });
    await fire.click();
    await lastAction('shelf.selectEmoji', { id: '1f525' });
    await fire.click({ modifiers: ['Shift'] });
    await lastAction('shelf.selectEmoji', { id: '1f525' });
    await page.getByRole('button', { name: 'Копировать', exact: true }).click();
    await lastAction('shelf.copyEmoji', { id: '1f525' });

    await app.evaluate(() => (globalThis as any).fixture.hold());
    const beforePermission = (await actions()).length;
    await allow.click();
    await expect(emojiGrid).toHaveAttribute('aria-busy', 'true');
    await expect(allow).toBeDisabled();
    await emojiInput.press('Enter');
    assert.equal((await actions()).length, beforePermission + 1);
    await app.evaluate(() => (globalThis as any).fixture.release());
    await lastAction('clipboardHistory.requestPasteAccess', {});
    await expect(emojiGrid).toHaveAttribute('aria-busy', 'false');
    await expect(allow).toBeVisible();
    await app.evaluate(() =>
      (globalThis as any).fixture.setAccessError('Permission request failed'),
    );
    await allow.click();
    await expect(page.locator('.clipboard-error')).toContainText('Permission request failed');
    await expect(emojiInput).toBeFocused();
    await app.evaluate(() => (globalThis as any).fixture.setAccessError(''));
    await allow.click();
    await expect(page.locator('.clipboard-error')).toHaveCount(0);
    await expect(emojiGrid).toHaveAttribute('aria-busy', 'false');
    await page.screenshot({ path: '/tmp/everything-emoji-paste-permission.png', scale: 'css' });

    await app.evaluate(() => (globalThis as any).fixture.setPasteAccess('granted', true));
    await expect(page.locator('.clipboard-paste-hint')).toHaveCount(0);
    await expect(page.locator('.emoji-footer')).toContainText('вставить');
    await app.evaluate(() => (globalThis as any).fixture.setPasteAccess('granted', false));
    await expect(page.locator('.emoji-footer')).toContainText('копировать');
    await app.evaluate(() => (globalThis as any).fixture.setPasteAccess('unavailable'));
    await expect(page.locator('.clipboard-paste-hint')).toContainText(
      'Автовставка пока недоступна',
    );
    await expect(allow).toHaveCount(0);
    await app.evaluate(() => (globalThis as any).fixture.setPasteOnSelect(false));
    await expect(page.locator('.clipboard-paste-hint')).toHaveCount(0);
    await expect(page.locator('.emoji-footer')).toContainText('копировать');
    await emojiInput.press('Enter');
    await lastAction('shelf.selectEmoji', { id: '1f525' });
    await page.evaluate(() => window.platform.call('shelf.settings'));
    await expect(page.getByRole('tab', { name: 'Основные', exact: true })).toBeVisible();
    const beforeSettings = (await actions()).length;
    await page.keyboard.press('Meta+1');
    assert.equal((await actions()).length, beforeSettings);
    assert.deepEqual(errors, []);
    console.log(
      'Shelf, clipboard history and emoji actions passed: shortcuts, selection/copy gestures, permission states, request retry, pending actions and navigation.',
    );
  }
}

void runDesktopTest('shelf-search-shortcuts', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
