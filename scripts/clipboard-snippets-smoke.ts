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
      if (!path.endsWith('/clipboard-probe')) return spawn(path, ...args);
      const child = new EventEmitter();
      child.stdout = new PassThrough();
      const emit = value => child.stdout.write(JSON.stringify(value) + '\\n');
      child.stdin = new Writable({ write(chunk, encoding, done) {
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
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  const row = page.locator('.clipboard-row').filter({ hasText: '123 Example Street' });
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
  const snippet = (await state()).clips.find((clip) => clip.name === 'Delivery address')!;
  assert(snippet.snippet && snippet.pinned);
  assert.notEqual(snippet.id, originalId);
  await page
    .locator('.clipboard-row')
    .filter({ hasText: 'Delivery address' })
    .getByRole('button', { name: 'Изменить сниппет' })
    .click();
  await text.fill('');
  await expect(page.getByRole('button', { name: 'Сохранить', exact: true })).toBeDisabled();
  await text.fill('789 Example Street\nSample City');
  await name.fill('Home address');
  await page.getByRole('button', { name: 'Сохранить', exact: true }).click();
  assert.equal((await state()).clips.find((clip) => clip.name === 'Home address')!.id, snippet.id);
  const search = page.getByRole('combobox', { name: 'Найти в истории' });
  await search.fill('home sample');
  await expect(page.locator('.clipboard-row')).toHaveCount(1);
  await page.screenshot({ path: join(test.artifacts, 'snippet-history.png'), scale: 'css' });
  await page.locator('.clipboard-copy').click();
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).__snippetCopies.at(-1)))
    .toBe('789 Example Street\nSample City');
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
  await app.evaluate(() => {
    (globalThis as any).__snippetPasteEnabled = true;
  });
  await page.evaluate(() =>
    window.platform.call('clipboardHistory.preferences', { pasteOnSelect: true }),
  );
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  await expect.poll(async () => (await state()).pasteReady).toBe(true);
  await page
    .locator('.clipboard-row')
    .filter({ hasText: 'Home address' })
    .locator('.clipboard-copy')
    .click();
  await expect.poll(() => app.evaluate(() => (globalThis as any).__snippetPastes)).toBe(1);
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
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
  await page.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await expect(page.locator('.clipboard-error')).toContainText('изменился');
  await expect(page.getByRole('textbox', { name: 'Текст', exact: true })).toHaveValue(
    'Unsaved local edit',
  );
  await page.getByRole('textbox', { name: 'Текст', exact: true }).press('Escape');
  await expect(page.getByRole('form', { name: 'Редактор сниппета' })).toHaveCount(0);
  assert.equal(
    (await state()).clips.find((clip) => clip.id === snippet.id)!.content,
    'Remote edit',
  );
  assert.equal(
    await app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows().some((win) => win.isVisible()),
    ),
    false,
  );
  console.log(
    'Snippets desktop passed: create, edit, validation, search, restart, copy from history/shelf, synthetic paste dispatch, and conflict recovery. OS clipboard, focus, shortcuts, Keychain and AX remain isolated.',
  );
}
runDesktopTest('clipboard-snippets', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
