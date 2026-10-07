import assert from 'node:assert/strict';
import { expect } from '@playwright/test';
import { writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { ClipboardHistory } from '../src/main/clipboard-history';
import { SettingsStore } from '../src/main/settings-store';
import type { ClipboardState } from '../src/shared/clipboard';
import { runDesktopTest, type DesktopTest } from './desktop-test';

async function main(test: DesktopTest) {
  const settings = new SettingsStore(test.profile);
  await settings.handle('settings.set', { key: 'shelfIntroduced', value: true });
  await settings.handle('settings.set', { key: 'mediaIndicatorEnabled', value: false });
  settings.close();
  const history = new ClipboardHistory(
    join(test.profile, 'clipboard-history/history.enc'),
    { encode: (text) => Buffer.from(text), decode: (bytes) => bytes.toString() },
    () => {},
  );
  await history.initialize();
  await history.preferences({ hoverEnabled: false, pasteOnSelect: false });
  await history.add('text', '123 Example Street\nSample City', '123 Example Street\nSample City');
  const originalId = history.snapshot().clips[0].id;
  await history.pin(originalId, true);
  await history.add('text', 'Standard reply', 'Standard reply');
  const bootstrap = join(test.profile, 'snippets.cjs');
  await writeFile(
    bootstrap,
    `
    const { app, BrowserWindow, clipboard, safeStorage, globalShortcut } = require('electron');
    const { EventEmitter } = require('node:events');
    const { PassThrough, Writable } = require('node:stream');
    const childProcess = require('node:child_process');
    app.getAppPath = () => ${JSON.stringify(process.cwd())};
    // Exercise the real main/IPC/renderer/storage code without shared OS surfaces.
    BrowserWindow.prototype.show = function() {};
    BrowserWindow.prototype.focus = function() {};
    BrowserWindow.prototype.isFocused = function() { return true; };
    const shortcuts = new Set();
    globalShortcut.register = key => { shortcuts.add(key); return true; };
    globalShortcut.unregister = key => shortcuts.delete(key);
    globalShortcut.unregisterAll = () => shortcuts.clear();
    globalShortcut.isRegistered = key => shortcuts.has(key);
    safeStorage.isEncryptionAvailable = () => true;
    safeStorage.encryptString = value => Buffer.from(value);
    safeStorage.decryptString = bytes => bytes.toString();
    clipboard.read = async () => [];
    global.__snippetCopies = [];
    global.__snippetPastes = 0;
    clipboard.write = async items => {
      const blob = await items[0].getType('text/plain');
      global.__snippetCopies.push(typeof blob === 'string' ? blob : await blob.text());
    };
    const spawn = childProcess.spawn;
    childProcess.spawn = (path, ...args) => {
      if (!path.endsWith('/clipboard-probe') && !path.endsWith('/file-shelf-probe'))
        return spawn(path, ...args);
      const child = new EventEmitter();
      child.stdout = new PassThrough();
      const emit = value => child.stdout.write(JSON.stringify(value) + '\\n');
      child.stdin = new Writable({ write(chunk, encoding, done) {
        if (path.endsWith('/file-shelf-probe')) { done(); return; }
        const command = JSON.parse(String(chunk));
        const result = global.__snippetPasteEnabled
          ? { trusted: true, ...(command.method === 'capture' ? { token: '00000000-0000-4000-8000-000000000001' } : {}), ...(command.method === 'paste' ? { sent: true } : {}) }
          : { trusted: false };
        if (command.method === 'paste') global.__snippetPastes++;
        queueMicrotask(() => emit({ type: 'paste.reply', id: command.id, result }));
        done();
      } });
      child.kill = signal => { child.emit('exit', null, signal || 'SIGTERM'); child.stdout.end(); return true; };
      setTimeout(() => emit({ type: 'ready' }), 20);
      return child;
    };
    require(${JSON.stringify(resolve('out/main/index.js'))});
  `,
  );
  let app = await test.launch({ args: [bootstrap] });
  let page = await app.firstWindow();
  const state = () =>
    page.evaluate(() => window.platform.call<ClipboardState>('clipboardHistory.state'));
  await expect(page.getByRole('combobox', { name: 'Поиск по полке' })).toBeVisible();
  await page.getByRole('combobox', { name: 'Поиск по полке' }).fill('snippets');
  await page.screenshot({ path: join(test.artifacts, 'snippets-launcher.png'), scale: 'css' });
  await page.getByRole('option', { name: /^Сниппеты / }).click();
  await expect(page.getByRole('combobox', { name: 'Найти сниппет' })).toBeVisible();
  await expect(page.locator('.clipboard-row')).toHaveCount(0);
  await expect(page.getByText('Сохраните готовый текст', { exact: true })).toBeVisible();
  const create = page.getByRole('button', { name: 'Создать сниппет', exact: true });
  await expect(create).toHaveAttribute('aria-keyshortcuts', 'Meta+N');
  await expect(create).toContainText('⌘N');
  await page.screenshot({ path: join(test.artifacts, 'snippets-empty.png'), scale: 'css' });
  // Reproduce the narrow action column beside a wide MacBook notch, without
  // changing the shared display or interacting with any visible OS window.
  const shelfStyle = await page.locator('.clipboard-shelf').evaluate((element) => {
    const previous = {
      style: element.getAttribute('style'),
      notched: element.getAttribute('data-notched'),
    };
    element.setAttribute('data-notched', 'true');
    (element as HTMLElement).style.setProperty('--notch-width', '220px');
    (element as HTMLElement).style.setProperty('--notch-inset', '32px');
    return previous;
  });
  const geometry = await create.evaluate((element) => {
    const button = element.getBoundingClientRect();
    const content = element.querySelector('.clipboard-create-content')!.getBoundingClientRect();
    const shelf = element.closest('.clipboard-shelf')!.getBoundingClientRect();
    const range = document.createRange();
    range.selectNodeContents(element.querySelector('.clipboard-create-content > span')!);
    return {
      labelLines: range.getClientRects().length,
      height: button.height,
      left: button.left,
      right: button.right,
      notchRight: shelf.left + shelf.width / 2 + 110,
      shelfRight: shelf.right,
      horizontalCenterOffset: (content.left + content.right - button.left - button.right) / 2,
      verticalCenterOffset: (content.top + content.bottom - button.top - button.bottom) / 2,
      itemCenterOffsets: Array.from(
        element.querySelector('.clipboard-create-content')!.children,
      ).map((child) => {
        const bounds = child.getBoundingClientRect();
        return (bounds.top + bounds.bottom - button.top - button.bottom) / 2;
      }),
    };
  });
  assert.equal(geometry.labelLines, 1, 'Create label must remain on one line beside the notch');
  assert(geometry.height <= 28, 'Create button must retain its compact height');
  assert(geometry.left > geometry.notchRight && geometry.right < geometry.shelfRight);
  assert(
    Math.abs(geometry.horizontalCenterOffset) <= 0.5,
    'Center the complete button content horizontally',
  );
  assert(
    Math.abs(geometry.verticalCenterOffset) <= 0.5,
    'Center the complete button content vertically',
  );
  assert(
    geometry.itemCenterOffsets.every((offset) => Math.abs(offset) <= 0.5),
    'Align icon, label and shortcut vertically',
  );
  await page.screenshot({
    path: join(test.artifacts, 'snippets-notched-normal.png'),
    scale: 'css',
  });
  await create.hover();
  await page.screenshot({ path: join(test.artifacts, 'snippets-notched.png'), scale: 'css' });
  await create.screenshot({ path: join(test.artifacts, 'snippet-create-button.png') });
  await page.locator('.clipboard-shelf').evaluate((element, previous) => {
    for (const [attribute, value] of [
      ['style', previous.style],
      ['data-notched', previous.notched],
    ]) {
      if (value === null) element.removeAttribute(attribute!);
      else element.setAttribute(attribute!, value!);
    }
  }, shelfStyle);
  await create.click();
  await expect(page.getByRole('textbox', { name: 'Название (необязательно)' })).toBeFocused();
  await page.getByRole('textbox', { name: 'Название (необязательно)' }).press('Escape');
  const initialSearch = page.getByRole('combobox', { name: 'Найти сниппет' });
  await initialSearch.press('n');
  await expect(initialSearch).toHaveValue('n');
  await initialSearch.evaluate((element) => {
    for (const extra of [{ repeat: true }, { isComposing: true }, { shiftKey: true }])
      element.dispatchEvent(
        new KeyboardEvent('keydown', {
          key: 'n',
          code: 'KeyN',
          metaKey: true,
          bubbles: true,
          ...extra,
        }),
      );
  });
  await expect(create).toBeVisible();
  await initialSearch.press('Meta+n');
  await expect(page.getByRole('textbox', { name: 'Название (необязательно)' })).toBeFocused();
  await page.getByRole('textbox', { name: 'Название (необязательно)' }).fill('Payment details');
  await page
    .getByRole('textbox', { name: 'Текст', exact: true })
    .fill('Synthetic account: EXAMPLE-123');
  await page.getByRole('textbox', { name: 'Текст', exact: true }).press('Meta+n');
  await expect(page.getByRole('textbox', { name: 'Название (необязательно)' })).toHaveValue(
    'Payment details',
  );
  await page.evaluate(() => window.platform.call('clipboardHistory.hide'));
  await page.evaluate(() => window.platform.call('launcher.show'));
  await expect(page.getByRole('textbox', { name: 'Название (необязательно)' })).toHaveValue(
    'Payment details',
  );
  await expect(page.getByRole('textbox', { name: 'Текст', exact: true })).toHaveValue(
    'Synthetic account: EXAMPLE-123',
  );
  const save = page.getByRole('button', { name: 'Сохранить', exact: true });
  await expect(save).toHaveAttribute('aria-keyshortcuts', 'Meta+Enter');
  await expect(save).toContainText('⌘↵');
  await page.getByRole('textbox', { name: 'Текст', exact: true }).evaluate((element) => {
    // One key gesture cannot create duplicate records while the first save is pending.
    for (let i = 0; i < 3; i++)
      element.dispatchEvent(
        new KeyboardEvent('keydown', {
          key: 'Enter',
          metaKey: true,
          bubbles: true,
          cancelable: true,
        }),
      );
  });
  await expect(page.locator('.clipboard-row')).toHaveCount(1);
  assert.equal(
    (await state()).snippets.find((clip) => clip.name === 'Payment details')!.pinned,
    true,
  );
  assert.equal((await state()).clips.length, 2);
  await page.getByRole('button', { name: 'Назад к приложениям', exact: true }).click();
  await expect(page.getByRole('combobox', { name: 'Поиск по полке' })).toBeVisible();
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  const row = page.locator('.clipboard-row').filter({ hasText: '123 Example Street' });
  await row.locator('.clipboard-copy').focus();
  await row.getByRole('button', { name: 'Создать сниппет' }).click();
  const name = page.getByRole('textbox', { name: 'Название (необязательно)' });
  const text = page.getByRole('textbox', { name: 'Текст', exact: true });
  await name.fill('Delivery address');
  await text.fill('456 Example Street\nSample City');
  // Editor keys must never trigger copy or navigation behind the form.
  await text.press('Shift+Enter');
  await expect.poll(() => app.evaluate(() => (globalThis as any).__snippetCopies.length)).toBe(0);
  await text.fill('456 Example Street\nSample City');
  await page.screenshot({ path: join(test.artifacts, 'snippet-editor.png'), scale: 'css' });
  await page.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await expect(
    page.locator('.clipboard-row').filter({ hasText: 'Delivery address' }),
  ).toContainText('456 Example Street');
  const snippet = (await state()).snippets.find((clip) => clip.name === 'Delivery address')!;
  assert(snippet.snippet && snippet.pinned);
  assert.notEqual(snippet.id, originalId);
  await page
    .locator('.clipboard-row')
    .filter({ hasText: 'Delivery address' })
    .getByRole('button', { name: 'Изменить сниппет' })
    .click();
  await text.fill('');
  await expect(page.getByRole('button', { name: 'Сохранить', exact: true })).toBeDisabled();
  await text.press('Meta+Enter');
  await expect(text).toHaveValue('');
  assert.equal(
    (await state()).snippets.find((clip) => clip.id === snippet.id)!.content,
    '456 Example Street\nSample City',
  );
  await text.fill('789 Example Street\nSample City');
  await name.fill('Home address');
  await name.evaluate((element) => {
    for (const extra of [{ repeat: true }, { isComposing: true }, { shiftKey: true }])
      element.dispatchEvent(
        new KeyboardEvent('keydown', {
          key: 'Enter',
          metaKey: true,
          bubbles: true,
          cancelable: true,
          ...extra,
        }),
      );
  });
  await expect(name).toHaveValue('Home address');
  assert.equal(
    (await state()).snippets.find((clip) => clip.id === snippet.id)!.name,
    'Delivery address',
  );
  await name.press('Meta+Enter');
  assert.equal(
    (await state()).snippets.find((clip) => clip.name === 'Home address')!.id,
    snippet.id,
  );
  assert.equal(
    (await state()).clips.find((clip) => clip.id === originalId)!.content,
    '123 Example Street\nSample City',
  );
  await expect(page.locator('.clipboard-row')).toHaveCount(2);
  await expect(page.locator('.clipboard-row').filter({ hasText: 'Standard reply' })).toHaveCount(0);
  await page.screenshot({ path: join(test.artifacts, 'snippets-app.png'), scale: 'css' });
  const search = page.getByRole('combobox', { name: 'Найти сниппет' });
  await search.press('Meta+Enter');
  await expect(page.locator('.clipboard-preview-content')).toBeVisible();
  // The physical shortcut also works with a Russian layout, from the preview.
  await page.locator('.clipboard-app').evaluate((element) => {
    element.dispatchEvent(
      new KeyboardEvent('keydown', {
        key: 'т',
        code: 'KeyN',
        metaKey: true,
        bubbles: true,
        cancelable: true,
      }),
    );
  });
  await expect(name).toHaveValue('');
  await expect(name).toBeFocused();
  await name.press('Escape');
  await expect(page.locator('.clipboard-row')).toHaveCount(2);
  await search.fill('home sample');
  await expect(page.locator('.clipboard-row')).toHaveCount(1);
  await page.screenshot({ path: join(test.artifacts, 'snippet-search.png'), scale: 'css' });
  await page.locator('.clipboard-copy').click();
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).__snippetCopies.at(-1)))
    .toBe('789 Example Street\nSample City');
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  await page.getByRole('combobox', { name: 'Найти в истории' }).fill('home sample');
  await expect(page.locator('.clipboard-row')).toHaveCount(0);
  await page.getByRole('combobox', { name: 'Найти в истории' }).fill('789 Example');
  await expect(page.locator('.clipboard-row')).toHaveCount(0);
  await page.getByRole('combobox', { name: 'Найти в истории' }).fill('');
  await expect(page.locator('.clipboard-row')).toHaveCount(2);
  await expect(page.locator('.clipboard-row').filter({ hasText: 'Home address' })).toHaveCount(0);
  await page.screenshot({ path: join(test.artifacts, 'snippet-history.png'), scale: 'css' });
  await page
    .locator('.clipboard-row')
    .filter({ hasText: '123 Example Street' })
    .locator('.clipboard-copy')
    .click();
  await expect.poll(() => app.evaluate(() => (globalThis as any).__snippetCopies.length)).toBe(2);
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).__snippetCopies.at(-1)))
    .toBe('123 Example Street\nSample City');
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  await page.getByRole('button', { name: 'Действия с историей', exact: true }).click();
  await page
    .getByRole('button', { name: 'Очистить историю на всех связанных Mac…', exact: true })
    .click();
  await expect(
    page.getByText('Сниппеты и текущий буфер обмена останутся на месте.', { exact: false }),
  ).toBeVisible();
  await page.getByRole('button', { name: 'Удалить на всех связанных Mac', exact: true }).click();
  await expect(page.locator('.clipboard-row')).toHaveCount(0);
  assert.equal((await state()).snippets.length, 2);
  await page.screenshot({ path: join(test.artifacts, 'history-cleared.png'), scale: 'css' });
  // Restart from the same isolated profile, then search by name on the main shelf.
  await test.close(app, true);
  app = await test.launch({ args: [bootstrap] });
  page = await app.firstWindow();
  const shelfSearch = page.getByRole('combobox', { name: 'Поиск по полке' });
  await shelfSearch.fill('home sample');
  await expect(page.locator('.launcher-result[data-kind="clip"]')).toHaveCount(1);
  await expect(page.locator('.launcher-result[data-kind="clip"]')).toContainText('Home address');
  await expect(page.getByRole('listbox', { name: 'Результаты поиска' })).toHaveAttribute(
    'aria-busy',
    'false',
  );
  await page.screenshot({ path: join(test.artifacts, 'snippet-shelf.png'), scale: 'css' });
  await page.locator('.launcher-result[data-kind="clip"]').click();
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).__snippetCopies.at(-1)))
    .toBe('789 Example Street\nSample City');
  const extraIds = await page.evaluate(async () => {
    const ids: string[] = [];
    for (let i = 0; i < 4; i++) {
      const result = await window.platform.call<{ id: string }>('clipboardHistory.createSnippet', {
        content: `snippet-overflow-fixture text ${i}`,
        name: `Extra snippet ${i}`,
      });
      ids.push(result.id);
    }
    return ids;
  });
  await page.evaluate(() => window.platform.call('launcher.show'));
  await shelfSearch.fill('snippet-overflow-fixture');
  const allSnippets = page.getByRole('option', { name: /^Показать все сниппеты / });
  await expect(allSnippets).toBeVisible();
  await expect(allSnippets).toHaveAttribute('aria-keyshortcuts', 'Meta+4');
  await shelfSearch.press('Meta+4');
  await expect(page.getByRole('combobox', { name: 'Найти сниппет' })).toHaveValue(
    'snippet-overflow-fixture',
  );
  await expect(page.locator('.clipboard-row')).toHaveCount(4);
  for (const id of extraIds)
    await page.evaluate((id) => window.platform.call('clipboardHistory.remove', { id }), id);
  await expect(page.locator('.clipboard-row')).toHaveCount(0);
  await page.evaluate(() => window.platform.call('clipboardHistory.hide'));
  await app.evaluate(() => {
    (globalThis as any).__snippetPasteEnabled = true;
  });
  await page.evaluate(() =>
    window.platform.call('clipboardHistory.preferences', { pasteOnSelect: true }),
  );
  await page.evaluate(() => window.platform.call('shelf.showSnippets'));
  await expect.poll(async () => (await state()).pasteReady).toBe(true);
  await page
    .locator('.clipboard-row')
    .filter({ hasText: 'Home address' })
    .locator('.clipboard-copy')
    .click();
  await expect.poll(() => app.evaluate(() => (globalThis as any).__snippetPastes)).toBe(1);
  await page.evaluate(() => window.platform.call('shelf.showSnippets'));
  const snippetSearch = page.getByRole('combobox', { name: 'Найти сниппет' });
  await expect(page.locator('.clipboard-row')).toHaveCount(2);
  await snippetSearch.fill('payment');
  await page.evaluate(() => window.platform.call('clipboardHistory.hide'));
  await page.evaluate(() => window.platform.call('launcher.show'));
  await expect(snippetSearch).toHaveValue('payment');
  await page.getByRole('button', { name: 'Назад к приложениям', exact: true }).click();
  await page.getByRole('combobox', { name: 'Поиск по полке' }).fill('Сниппеты');
  await page.getByRole('option', { name: /^Сниппеты / }).click();
  await expect(snippetSearch).toHaveValue('');
  await page.evaluate(() => window.platform.call('shelf.showSnippets'));
  await page
    .locator('.clipboard-row')
    .filter({ hasText: 'Home address' })
    .locator('.clipboard-copy')
    .focus();
  await page
    .locator('.clipboard-row')
    .filter({ hasText: 'Home address' })
    .getByRole('button', { name: 'Изменить сниппет' })
    .click();
  await page.getByRole('textbox', { name: 'Текст', exact: true }).fill('Unsaved local edit');
  await page.evaluate(
    (id) =>
      window.platform.call('clipboardHistory.edit', {
        id,
        content: 'Remote edit',
        name: 'Remote name',
        expected: { content: '789 Example Street\nSample City', name: 'Home address' },
      }),
    snippet.id,
  );
  await page.getByRole('textbox', { name: 'Текст', exact: true }).press('Meta+Enter');
  await expect(page.locator('.clipboard-error')).toContainText('изменился');
  await expect(page.getByRole('textbox', { name: 'Текст', exact: true })).toHaveValue(
    'Unsaved local edit',
  );
  await page.getByRole('textbox', { name: 'Текст', exact: true }).press('Escape');
  await expect(page.getByRole('form', { name: 'Редактор сниппета' })).toHaveCount(0);
  assert.equal(
    (await state()).snippets.find((clip) => clip.id === snippet.id)!.content,
    'Remote edit',
  );
  assert.equal(
    await app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows().some((win) => win.isVisible()),
    ),
    false,
  );
  console.log(
    'Standalone Snippets desktop passed: launcher entry, empty state, creation by button and ⌘N, shortcut hints, alignment, Russian layout, IME/repeat guards, draft preservation, saving from history without changing the source, separate search and collections, history clear preserves snippets, editor resume, edit, validation, restart, copy, shelf search, synthetic paste dispatch, and conflict recovery. OS clipboard, focus, shortcuts, Keychain and AX remain isolated.',
  );
}
runDesktopTest('clipboard-snippets', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
