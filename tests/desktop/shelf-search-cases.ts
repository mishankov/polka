import { join } from 'node:path';
import { expect, type ElectronApplication, type Page } from '@playwright/test';
import assert from 'node:assert/strict';
import type { DesktopTest } from './desktop-test';

export function shelfSearchContext(test: DesktopTest, app: ElectronApplication, page: Page) {
  const input = page.getByRole('combobox', { name: 'Поиск по полке', exact: true });
  const rows = page.locator('.launcher-result');
  const actions = () => app.evaluate(() => (globalThis as any).fixture.actions);
  const lastAction = async (method: string, params: Record<string, unknown>) => {
    await expect.poll(async () => (await actions()).at(-1)).toEqual({ method, params });
    await expect(
      page.locator('[role="listbox"][aria-busy], [role="grid"][aria-busy]'),
    ).toHaveAttribute('aria-busy', 'false');
  };
  const historyInput = page.getByRole('combobox', { name: 'Найти в истории' });
  const historyRows = page.locator('.clipboard-row');
  const historyMenu = page.getByRole('button', { name: 'Действия с историей', exact: true });
  const emojiInput = page.getByRole('combobox', { name: 'Найти эмодзи', exact: true });
  const emojiGrid = page.getByRole('grid', { name: 'Эмодзи для вставки' });
  return {
    test,
    app,
    page,
    input,
    rows,
    actions,
    lastAction,
    historyInput,
    historyRows,
    historyMenu,
    emojiInput,
    emojiGrid,
  };
}
type Context = ReturnType<typeof shelfSearchContext>;

// Each case receives a newly launched renderer and a fresh main-process fixture.
export const shelfSearchCases: {
  id: string;
  name: string;
  run: (context: Context) => Promise<void>;
}[] = [
  {
    id: 'catalog',
    name: 'Startup acknowledgement and cached catalog recovery',
    async run({ test, app, page, input, rows, lastAction }) {
      await expect(input).toBeFocused();
      // This fixture opens from its initial snapshot without sending shelf.shown.
      // Cold startup must still acknowledge the rendered opening to the main process.
      await expect
        .poll(() => app.evaluate(() => (globalThis as any).fixture.shownRevisions))
        .toContain(0);
      await expect(rows).toHaveCount(11);
      await expect(rows.locator('kbd')).toHaveText(
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
        path: join(test.artifacts, 'shelf-search-shortcuts-apps.png'),
        scale: 'css',
      });

      // An Apps presentation must already contain the cached catalog when it is
      // acknowledged, even if the refresh request is held or ultimately fails.
      const catalogRequests = await app.evaluate(() => (globalThis as any).fixture.macAppRequests);
      await app.evaluate(() => (globalThis as any).fixture.holdMacApps());
      await app.evaluate(() => (globalThis as any).fixture.navigate('clipboard'));
      await expect(page.getByRole('combobox', { name: 'Найти в истории' })).toBeFocused();
      await page.getByRole('button', { name: 'Назад к приложениям', exact: true }).click();
      await expect(input).toBeFocused();
      await expect
        .poll(() => app.evaluate(() => (globalThis as any).fixture.catalogAtShow.at(-1)))
        .toBe(10);
      await expect(rows).toHaveCount(11);
      await expect
        .poll(() => app.evaluate(() => (globalThis as any).fixture.macAppRequests))
        .toBeGreaterThan(catalogRequests);
      await input.fill('Calculator');
      await expect(rows).toHaveCount(1);
      await input.fill('');
      // Reopening in the same renderer must retain the same catalog too.
      await app.evaluate(() => (globalThis as any).fixture.hide());
      await app.evaluate(() => (globalThis as any).fixture.navigate('apps'));
      await expect(input).toBeFocused();
      await expect
        .poll(() => app.evaluate(() => (globalThis as any).fixture.catalogAtShow.at(-1)))
        .toBe(10);
      await expect(rows).toHaveCount(11);
      await app.evaluate(() => {
        (globalThis as any).fixture.setExtraMacApp('New app');
        (globalThis as any).fixture.releaseMacApps();
      });
      await expect(rows).toHaveCount(12);
      await expect(rows.filter({ hasText: 'New app' })).toHaveCount(1);
      // Launching a cached result during refresh must retain the newly learned
      // ranking when the earlier usage response finally completes.
      const beforeUsageRefresh = await app.evaluate(
        () => (globalThis as any).fixture.macAppRequests,
      );
      await app.evaluate(() => {
        (globalThis as any).fixture.holdMacApps();
        (globalThis as any).fixture.navigate('apps');
      });
      await expect(input).toBeFocused();
      await expect
        .poll(() => app.evaluate(() => (globalThis as any).fixture.macAppRequests))
        .toBeGreaterThan(beforeUsageRefresh);
      await rows.filter({ hasText: 'TextEdit' }).click();
      await lastAction('launcher.openMac', { id: 'mac:TextEdit' });
      await expect(rows.nth(1)).toContainText('TextEdit');
      await app.evaluate(() => {
        (globalThis as any).fixture.setExtraMacApp('Updated catalog');
        (globalThis as any).fixture.releaseMacApps();
      });
      await expect(rows.filter({ hasText: 'Updated catalog' })).toHaveCount(1);
      await expect(rows.nth(1)).toContainText('TextEdit');
      await app.evaluate(() => {
        (globalThis as any).fixture.holdMacApps();
        (globalThis as any).fixture.navigate('apps');
      });
      await expect(input).toBeFocused();
      await expect
        .poll(() => app.evaluate(() => (globalThis as any).fixture.catalogAtShow.at(-1)))
        .toBe(11);
      await app.evaluate(() => (globalThis as any).fixture.releaseMacApps('Catalog unavailable'));
      await expect(page.getByRole('alert')).toContainText('Catalog unavailable');
      await expect(rows).toHaveCount(12);
      await app.evaluate(() => {
        (globalThis as any).fixture.setExtraMacApp('');
        (globalThis as any).fixture.resetUsage();
        (globalThis as any).fixture.releaseMacApps();
      });
      await page.getByRole('button', { name: 'Обновить список', exact: true }).click();
      await expect(page.getByRole('alert')).toHaveCount(0);
      await expect(rows).toHaveCount(11);
    },
  },
  {
    id: 'calculations',
    name: 'App shortcuts, calculations and invalid conversions',
    async run({ test, page, input, rows, actions, lastAction }) {
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
        path: join(test.artifacts, 'shelf-search-shortcuts-groups.png'),
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
      await page.screenshot({
        path: join(test.artifacts, 'shelf-time-conversion.png'),
        scale: 'css',
      });
      await input.fill('2026-11-01 01:30 New York in UTC');
      await expect(page.locator('.launcher-calculation-status')).toContainText(
        'встречается дважды',
      );
      await expect(rows).toHaveCount(0);
      const beforeInvalidConversion = (await actions()).length;
      await input.press('Enter');
      assert.equal((await actions()).length, beforeInvalidConversion);
      await input.fill('10 inches in');
      await expect(page.locator('.launcher-calculation-status')).toContainText(
        'Укажите единицу результата',
      );
      await expect(rows).toHaveCount(0);
    },
  },
  {
    id: 'search-actions',
    name: 'Mixed search actions and shortcut guards',
    async run({ test, app, page, input, rows, actions, lastAction }) {
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
        await input.press('Enter');
        await input.press('Shift+Enter');
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
    },
  },
  {
    id: 'ranking',
    name: 'Fuzzy matching, keyboard layouts and learned ranking',
    async run({ test, page, input, rows, actions, lastAction }) {
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
    },
  },
  {
    id: 'clipboard',
    name: 'Clipboard shortcuts, pinning, dialogs and pending actions',
    async run({
      test,
      app,
      page,
      input,
      rows,
      actions,
      lastAction,
      historyInput,
      historyRows,
      historyMenu,
    }) {
      await input.fill('пример');
      await input.press('Meta+4');
      await expect(page.getByRole('combobox', { name: 'Найти в истории' })).toHaveValue('пример');
      assert.deepEqual((await actions()).at(-1), {
        method: 'clipboardHistory.show',
        params: { query: 'пример' },
      });
      await expect(historyInput).toBeFocused();
      // Autofocus happens before the asynchronous history request has populated the rows.
      await expect(historyRows.locator('kbd')).toHaveText(['⌘1', '⌘2', '⌘3', '⌘4']);
      await historyInput.press('Meta+2');
      await lastAction('clipboardHistory.select', { id: 'clip-2' });
      await expect(historyRows.first().getByRole('option')).toHaveAttribute(
        'aria-selected',
        'true',
      );

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
      await historyRows
        .last()
        .getByRole('button', { name: 'Закрепить запись', exact: true })
        .click();
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
      await expect(historyRows.first().getByRole('option')).toHaveAttribute(
        'aria-selected',
        'true',
      );
      await page.mouse.move(0, 0);
      await page.screenshot({
        path: join(test.artifacts, 'clipboard-number-shortcuts.png'),
        scale: 'css',
      });

      await page.evaluate(() => window.platform.call('launcher.show'));
      await expect(input).toBeFocused();
      await input.press('Meta+1');
      await expect(page.getByRole('combobox', { name: 'Найти в истории' })).toHaveValue('');
    },
  },
  {
    id: 'emoji',
    name: 'Emoji actions, paste permissions and helper startup',
    async run({ test, app, page, actions, lastAction, historyInput, emojiInput, emojiGrid }) {
      // Establish the pinned history entry used by the helper-startup assertions.
      await app.evaluate(async () => {
        const fixture = (globalThis as any).fixture;
        fixture.setClipCount(12);
        await fixture.call('clipboardHistory.pin', { id: 'clip-0', pinned: true });
        fixture.navigate('clipboard');
      });
      await expect(historyInput).toBeFocused();
      // Emoji uses the same selection/copy gestures and permission states as history.
      await app.evaluate(() => {
        const fixture = (globalThis as any).fixture;
        fixture.setPasteOnSelect(true);
        fixture.setPasteAccess('required');
      });
      const allow = page.getByRole('button', { name: /Разрешить…$/ });
      await expect(allow).toBeVisible();
      await expect(page.locator('.clipboard-paste-permission')).toContainText(
        'Универсальный доступ',
      );
      await app.evaluate(() => (globalThis as any).fixture.navigate('emoji'));
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
      await page.screenshot({
        path: join(test.artifacts, 'emoji-paste-permission.png'),
        scale: 'css',
      });

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
      await app.evaluate(() => (globalThis as any).fixture.setHelper({ status: 'starting' }));
      const startup = page.locator('.clipboard-helper-status');
      await expect(startup).toContainText('Запускаем наблюдение за буфером обмена…');
      await expect(startup).toContainText('эмодзи только копируется');
      await page.screenshot({ path: join(test.artifacts, 'emoji-starting.png'), scale: 'css' });
      await expect(page.getByText('Автовставка пока недоступна.', { exact: false })).toHaveCount(0);
      await app.evaluate(() => (globalThis as any).fixture.navigate('clipboard'));
      const clipboardInput = page.getByRole('combobox', { name: 'Найти в истории', exact: true });
      await expect(clipboardInput).toBeFocused();
      await expect(startup).toContainText('запись только копируется');
      await clipboardInput.fill('Заметка');
      await clipboardInput.press('Enter');
      await lastAction('clipboardHistory.select', { id: 'clip-0' });
      await page.screenshot({ path: join(test.artifacts, 'clipboard-starting.png'), scale: 'css' });
      await app.evaluate(() => (globalThis as any).fixture.setPasteOnSelect(false));
      await expect(startup).toContainText('Запускаем наблюдение за буфером обмена…');
      await expect(startup).not.toContainText('только копируется');
      await app.evaluate(() => (globalThis as any).fixture.setHelper({ status: 'running' }));
      await expect(startup).toHaveCount(0);
      await expect(clipboardInput).toHaveValue('Заметка');
      await app.evaluate(() => (globalThis as any).fixture.navigate('emoji'));
      await expect(emojiInput).toBeFocused();
      await emojiInput.fill('🔥');
      await app.evaluate(() => (globalThis as any).fixture.setPasteOnSelect(false));
      await expect(page.locator('.clipboard-paste-hint')).toHaveCount(0);
      await expect(page.locator('.emoji-footer')).toContainText('копировать');
      await emojiInput.press('Enter');
      await lastAction('shelf.selectEmoji', { id: '1f525' });
      // Numbered emoji actions work from search and grid focus, with one action per key.
      await expect(emojiGrid.locator('kbd')).toHaveText(
        Array.from(
          { length: Math.min(9, await emojiGrid.getByRole('gridcell').count()) },
          (_, i) => `⌘${i + 1}`,
        ),
      );
      await emojiInput.press('Meta+1');
      await lastAction('shelf.selectEmoji', { id: '1f525' });
      const beforeEmojiIgnored = (await actions()).length;
      for (const options of [{ repeat: true }, { isComposing: true }]) {
        await emojiInput.dispatchEvent('keydown', {
          key: '1',
          code: 'Digit1',
          metaKey: true,
          bubbles: true,
          ...options,
        });
        await emojiInput.dispatchEvent('keydown', { key: 'Enter', bubbles: true, ...options });
      }
      await page.getByRole('combobox', { name: 'Оттенок кожи' }).press('Escape');
      assert.equal((await actions()).length, beforeEmojiIgnored);
    },
  },
  {
    id: 'restoration',
    name: 'Browsing, preview and draft restoration across reopen',
    async run({ test, app, page, historyInput, historyRows, historyMenu, emojiInput, emojiGrid }) {
      // A resumed built-in restores browsing state; direct entry starts fresh.
      await app.evaluate(() => (globalThis as any).fixture.navigate('clipboard'));
      await app.evaluate(() => (globalThis as any).fixture.setClipCount(12));
      await historyInput.fill('пример');
      await historyInput.press('ArrowDown');
      await historyInput.press('ArrowDown');
      const selectedClip = await historyRows
        .getByRole('option', { selected: true })
        .getAttribute('id');
      await page.locator('#clipboard-results').evaluate((element) => {
        element.scrollTop = 100;
      });
      await expect
        .poll(() => page.locator('#clipboard-results').evaluate((el) => el.scrollTop))
        .toBe(100);
      await app.evaluate(() => (globalThis as any).fixture.hide());
      await expect(page.locator('.clipboard-shelf')).toHaveClass(/is-closed/);
      await app.evaluate(() => (globalThis as any).fixture.navigate('clipboard', '', 'resume'));
      await expect(historyInput).toHaveValue('пример');
      await expect(historyInput).toBeFocused();
      await expect(historyRows.getByRole('option', { selected: true })).toHaveAttribute(
        'id',
        selectedClip!,
      );
      await expect
        .poll(() => page.locator('#clipboard-results').evaluate((el) => el.scrollTop))
        .toBe(100);
      await app.evaluate(
        (_, id) =>
          (globalThis as any).fixture.setClipText(
            id,
            'Заметка: пример длинного текста\n'.repeat(100),
          ),
        selectedClip!.replace(/^clip-/, ''),
      );
      await historyInput.press('Meta+Enter');
      const preview = page.getByRole('region', { name: 'Просмотр записи' });
      const back = page.getByRole('button', { name: 'Назад к списку', exact: true });
      await expect(back).toBeFocused();
      await expect(page.locator('.clipboard-back')).toHaveCount(1);
      await expect(preview.getByRole('button', { name: /Назад/ })).toHaveCount(0);
      await page.keyboard.press('Meta+1');
      await expect(preview.locator('pre')).toContainText('ЗАМЕТКА');
      const transformed = await preview.locator('pre').textContent();
      await preview.locator('.clipboard-preview-content').evaluate((el) => {
        el.scrollTop = 180;
      });
      await expect
        .poll(() => preview.locator('.clipboard-preview-content').evaluate((el) => el.scrollTop))
        .toBe(180);
      await app.evaluate(() => (globalThis as any).fixture.hide());
      await app.evaluate(() => (globalThis as any).fixture.navigate('clipboard', '', 'resume'));
      await expect(preview).toBeVisible();
      await expect(preview.locator('pre')).toHaveText(transformed!);
      await expect
        .poll(() => preview.locator('.clipboard-preview-content').evaluate((el) => el.scrollTop))
        .toBe(180);
      await expect(back).toBeFocused();
      await back.press('Enter');
      await expect(historyInput).toHaveValue('пример');
      await expect(historyInput).toBeFocused();
      await historyInput.press('Meta+Enter');
      await app.evaluate(() => (globalThis as any).fixture.hide());
      await app.evaluate(() => (globalThis as any).fixture.setClipCount(0));
      await app.evaluate(() => (globalThis as any).fixture.navigate('clipboard', '', 'resume'));
      await expect(preview).toHaveCount(0);
      await expect(historyRows).toHaveCount(0);
      await app.evaluate(() => (globalThis as any).fixture.setClipCount(4));
      await app.evaluate(() => (globalThis as any).fixture.navigate('clipboard'));
      await expect(historyInput).toHaveValue('');
      await historyMenu.click();
      await app.evaluate(() => (globalThis as any).fixture.hide());
      await app.evaluate(() => (globalThis as any).fixture.navigate('clipboard', '', 'resume'));
      await expect(historyMenu).toHaveAttribute('aria-expanded', 'false');
      await expect(historyInput).toBeFocused();
      await historyMenu.click();
      await page
        .getByRole('button', { name: 'Очистить историю на всех связанных Mac…', exact: true })
        .click();
      await app.evaluate(() => (globalThis as any).fixture.hide());
      await app.evaluate(() => (globalThis as any).fixture.navigate('clipboard', '', 'resume'));
      await expect(
        page.getByRole('heading', { name: 'Удалить историю на всех связанных Mac?' }),
      ).toHaveCount(0);
      await expect(historyRows).toHaveCount(4);

      await app.evaluate(() => (globalThis as any).fixture.navigate('emoji'));
      await emojiInput.fill('лайк');
      await page.getByRole('combobox', { name: 'Оттенок кожи' }).selectOption('🏽');
      await emojiInput.press('ArrowDown');
      const selectedEmoji = await emojiGrid.locator('[aria-selected="true"]').getAttribute('id');
      await app.evaluate(() => (globalThis as any).fixture.hide());
      await app.evaluate(() => (globalThis as any).fixture.navigate('emoji', '', 'resume'));
      await expect(emojiInput).toHaveValue('лайк');
      await expect(emojiInput).toBeFocused();
      await expect(page.getByRole('combobox', { name: 'Оттенок кожи' })).toHaveValue('🏽');
      await expect(emojiGrid.locator('[aria-selected="true"]')).toHaveAttribute(
        'id',
        selectedEmoji!,
      );
      await emojiInput.fill('');
      const category = page.getByRole('tab').nth(1);
      await category.click();
      const categoryId = await category.getAttribute('id');
      await emojiGrid.evaluate((el) => {
        el.scrollTop = 150;
      });
      await emojiGrid.evaluate(
        () =>
          new Promise<void>((resolve) =>
            requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
          ),
      );
      const emojiScroll = await emojiGrid.evaluate((el) => el.scrollTop);
      await app.evaluate(() => (globalThis as any).fixture.hide());
      await app.evaluate(() => (globalThis as any).fixture.navigate('emoji', '', 'resume'));
      await expect(page.locator('#' + categoryId)).toHaveAttribute('aria-selected', 'true');
      await expect.poll(() => emojiGrid.evaluate((el) => el.scrollTop)).toBe(emojiScroll);
      await expect(emojiGrid.locator('kbd')).toHaveText(
        Array.from({ length: 9 }, (_, i) => `⌘${i + 1}`),
      );
      await app.evaluate(() => (globalThis as any).fixture.navigate('emoji'));
      await expect(emojiInput).toHaveValue('');
      await expect(page.getByRole('combobox', { name: 'Оттенок кожи' })).toHaveValue('default');
      await expect(page.getByRole('tab').first()).toHaveAttribute('aria-selected', 'true');

      // An unacknowledged preparation cannot erase the last committed browsing context.
      await emojiInput.fill('original emoji query');
      await app.evaluate(() => (globalThis as any).fixture.setAcknowledgeShows(false));
      await app.evaluate(() => (globalThis as any).fixture.navigate('clipboard'));
      await historyInput.fill('discarded query');
      await app.evaluate(() => (globalThis as any).fixture.hide());
      await app.evaluate(() => (globalThis as any).fixture.setAcknowledgeShows(true));
      await app.evaluate(() => (globalThis as any).fixture.navigate('emoji', '', 'resume'));
      await expect(emojiInput).toHaveValue('original emoji query');
    },
  },
  {
    id: 'updates',
    name: 'Compact update notices and bilingual release notes',
    async run({ test, app, page, rows, actions }) {
      // Verify the compact notice at the real shelf width, not just the wider fixture.
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(560, 560));
      // Update notice has exactly two compact rows and shares the results scroller.
      await app.evaluate(() => (globalThis as any).fixture.navigate('apps'));
      await expect(rows).toHaveCount(11);
      const notice = page.getByRole('region', { name: 'Доступно обновление Полки 0.5.0' });
      for (const status of ['checking', 'downloading', 'ready', 'installing', 'error']) {
        await app.evaluate(
          (_, status) =>
            (globalThis as any).fixture.setUpdateState({
              status,
              currentVersion: '0.4.0',
              version: '0.5.0',
              progress: 38,
              notification: 'visible',
              message: 'Long error explanation '.repeat(20),
              releaseNotes: {
                ru: 'Полные примечания '.repeat(100),
                en: 'Full release notes '.repeat(100),
              },
            }),
          status,
        );
        await expect(notice).toBeVisible();
        const geometry = await notice.evaluate((el) => {
          const children = [...el.children] as HTMLElement[];
          const rect = el.getBoundingClientRect();
          return {
            rows: children.length,
            height: rect.height,
            width: rect.width,
            actionRows: new Set(
              [...el.querySelectorAll('button')].map((button) =>
                Math.round(button.getBoundingClientRect().top),
              ),
            ).size,
            shared: !!el.closest('.launcher-scroll'),
            noHorizontalOverflow: el.scrollWidth <= el.clientWidth,
            overflow: getComputedStyle(el).overflowY,
          };
        });
        assert.equal(geometry.rows, 2);
        assert.equal(geometry.actionRows, 1);
        assert(geometry.height < 90, JSON.stringify(geometry));
        assert(geometry.shared);
        assert(geometry.noHorizontalOverflow, JSON.stringify(geometry));
        assert.equal(geometry.overflow, 'visible');
        await expect(notice.locator('.update-release-notes')).toHaveCount(0);
      }
      await app.evaluate(() =>
        (globalThis as any).fixture.setUpdateState({
          status: 'ready',
          currentVersion: '0.4.0',
          version: '0.5.0',
          notification: 'visible',
          releaseNotes: { ru: 'Полные примечания', en: 'Full release notes' },
        }),
      );
      await page.screenshot({ path: join(test.artifacts, 'compact-update-notice.png') });
      await page.locator('.launcher-scroll').evaluate((el) => {
        el.scrollTop = el.scrollHeight;
      });
      assert(
        (await notice.boundingBox())!.y < (await page.locator('.launcher-search').boundingBox())!.y,
      );
      await page.locator('.launcher-scroll').evaluate((el) => {
        el.scrollTop = 0;
      });
      await notice.getByRole('button', { name: 'Что нового', exact: true }).click();
      await expect(page.getByRole('tab', { name: 'О приложении', exact: true })).toHaveAttribute(
        'aria-selected',
        'true',
      );
      await expect(page.locator('.update-release-notes-body')).toContainText('Полные примечания');
      await page.getByRole('button', { name: 'English', exact: true }).click();
      await expect(page.locator('.update-release-notes-body')).toContainText('Full release notes');
      await page.evaluate(() => window.platform.call('shelf.settings'));
      await expect(page.getByRole('tab', { name: 'Основные', exact: true })).toHaveAttribute(
        'aria-selected',
        'true',
      );

      const beforeSettings = (await actions()).length;
      await page.keyboard.press('Meta+1');
      assert.equal((await actions()).length, beforeSettings);
    },
  },
];
