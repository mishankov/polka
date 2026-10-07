import { build } from 'esbuild';
import { expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdir, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { runDesktopTest, type DesktopTest } from './desktop-test';
import type { ClipboardState } from '../src/shared/clipboard';

async function main(test: DesktopTest) {
  const entry = join(test.profile, 'ocr-fixture.cjs');
  const fixtures = await Promise.all(
    ['english', 'russian', 'mixed', 'empty', 'failure'].map(async (name) => ({
      name,
      content: (await readFile(`tests/fixtures/image-text/${name}.png`)).toString('base64'),
    })),
  );
  // Real encrypted history, native Vision indexer, shelf handlers and renderer.
  // Only the fixture's clipboard, global shortcuts and native reveal are stubbed:
  // this test neither reads/writes the shared clipboard nor steals desktop focus.
  await build({
    stdin: {
      contents: `
      import { app, BrowserWindow, clipboard, dialog, globalShortcut, ipcMain, safeStorage } from 'electron';
      import { ClipboardHistory } from './src/main/clipboard-history';
      import { createShelf } from './src/main/shelf';
      import { IMAGE_TEXT_VERSION } from './src/main/image-text';
      import { join } from 'node:path';
      app.setPath('userData', ${JSON.stringify(test.profile)});
      app.getAppPath = () => ${JSON.stringify(resolve('.'))};
      clipboard.read = async () => [];
      globalShortcut.register = () => true;
      globalShortcut.unregister = () => {};
      globalThis.copies = [];
      dialog.showSaveDialog = async owner => {
        owner.emit('blur');
        return new Promise(resolve => { globalThis.finishSave = () => resolve({ canceled: true }); });
      };
      clipboard.write = async items => {
        const values = {};
        for (const type of items[0].types) {
          const value = await items[0].getType(type);
          values[type] = value instanceof Blob ? Buffer.from(await value.arrayBuffer()).toString('base64') : value;
        }
        globalThis.copies.push(values);
      };
      let shelf;
      let quitting = false;
      let ready = false;
      ipcMain.handle('platform:call', async (_, method, params = {}) => {
        if (method === 'shelf.appearance') return { dark: true, contrast: false, reducedTransparency: false };
        if (method === 'launcher.getPreferences') return { accelerator: 'CommandOrControl+Shift+Space', registered: true };
        if (method.startsWith('clipboardHistory.') || method.startsWith('shelf.')) return shelf.handle(method, params);
        if (method === 'launcher.apps' || method === 'launcher.macApps') return [];
        if (method === 'launcher.usage') return {};
        if (method === 'launcher.show') return shelf.show('keyboard', 'apps');
        if (method === 'updates.status') return { status: 'unavailable', currentVersion: '0.1.15' };
      });
      app.whenReady().then(async () => {
        const history = new ClipboardHistory(join(${JSON.stringify(test.profile)}, 'clipboard-history/history.enc'), {
          encode: text => safeStorage.encryptString(text), decode: bytes => safeStorage.decryptString(bytes),
        }, () => {});
        await history.initialize();
        await history.preferences({ pasteOnSelect: false, hoverEnabled: false });
        for (const fixture of ${JSON.stringify(fixtures)}) await history.add('image', fixture.content, 'data:image/png;base64,' + fixture.content);
        const failed = history.imageTextImages().find(clip => clip.content === ${JSON.stringify(fixtures.find((f) => f.name === 'failure')!.content)});
        await history.saveImageText(failed.id, failed.incarnation, { version: IMAGE_TEXT_VERSION, status: 'failed', text: '', languages: [] });
        shelf = createShelf(${JSON.stringify(test.profile)}, window => {
          window.show = () => {};
          window.focus = () => {};
          window.isFocused = () => true;
        }, () => {
          for (const window of BrowserWindow.getAllWindows()) window.webContents.send('platform:event', { type: 'clipboardHistory.changed' });
        }, () => quitting);
        globalThis.shelf = shelf;
        await shelf.start();
        ready = true;
        await shelf.show('keyboard', 'apps');
      });
      globalThis.fixtureReady = () => ready;
      app.on('before-quit', event => {
        if (quitting) return;
        event.preventDefault(); quitting = true;
        shelf.stop().then(() => app.quit());
      });
    `,
      resolveDir: resolve('.'),
      sourcefile: 'ocr-fixture.ts',
      loader: 'ts',
    },
    outfile: entry,
    bundle: true,
    platform: 'node',
    format: 'cjs',
    external: ['electron'],
    define: { __dirname: JSON.stringify(resolve('out/main')) },
  });
  const app = await test.launch({ args: [entry] });
  const page = await app.firstWindow();
  const state = () =>
    page.evaluate(() => window.platform.call<ClipboardState>('clipboardHistory.state'));
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).fixtureReady()), { timeout: 30000 })
    .toBe(true);
  await expect
    .poll(async () => (await state()).clips.filter((c) => c.ocr).length, { timeout: 90000 })
    .toBe(5);
  assert.equal((await state()).clips.filter((c) => c.ocr?.status === 'ready').length, 3);
  assert.equal((await state()).clips.filter((c) => c.ocr?.status === 'empty').length, 1);
  assert.equal((await state()).clips.filter((c) => c.ocr?.status === 'failed').length, 1);
  assert(
    (await state()).clips.every((c) => c.content === ''),
    'Full PNG never crosses state IPC',
  );
  const artifacts = resolve('artifacts/issue-11');
  await mkdir(artifacts, { recursive: true });
  const input = page.getByRole('combobox', { name: 'Поиск по полке', exact: true });
  await input.fill('Доставка');
  await expect(page.locator('.launcher-result[data-kind=clip]')).toHaveCount(2);
  await expect(page.locator('.launcher-result[data-kind=clip]').first()).toContainText('Доставка');
  await page.screenshot({ path: join(artifacts, 'shelf-search.png'), scale: 'css' });
  await app.evaluate(() => (globalThis as any).shelf.show('keyboard', 'clipboard', 'Aurora Север'));
  const search = page.getByRole('combobox', { name: 'Найти в истории', exact: true });
  await expect(search).toHaveValue('Aurora Север');
  await expect(page.locator('.clipboard-row')).toHaveCount(1);
  await expect(page.locator('.clipboard-row')).toContainText('Aurora');
  await page.screenshot({ path: join(artifacts, 'history-search.png'), scale: 'css' });
  await search.press('Meta+Enter');
  await expect(page.getByRole('region', { name: 'Распознанный текст', exact: true })).toContainText(
    'Доставка',
  );
  const recognized = page.locator('.clipboard-image-text pre');
  assert.equal(await recognized.evaluate((e) => getComputedStyle(e).userSelect), 'text');
  const fullText = await recognized.innerText();
  const save = page.getByRole('button', { name: 'Сохранить изображение…', exact: true });
  await save.click();
  await expect(save).toBeDisabled();
  await app.evaluate(() => (globalThis as any).finishSave());
  await expect(save).toBeEnabled();
  await expect(save).toBeFocused();
  await page.screenshot({ path: join(artifacts, 'image-preview.png'), scale: 'css' });
  await page.getByRole('button', { name: 'Копировать текст', exact: true }).click();
  await expect.poll(() => app.evaluate(() => (globalThis as any).copies.length)).toBe(1);
  const textCopy = await app.evaluate(() => (globalThis as any).copies.at(-1));
  assert.equal(Buffer.from(textCopy['text/plain'], 'base64').toString(), fullText);
  assert(!('image/png' in textCopy));
  // Searching by OCR words and selecting the matching row still copies pixels.
  await app.evaluate(() => (globalThis as any).shelf.show('keyboard', 'clipboard', 'Aurora Север'));
  await expect(search).toBeFocused();
  await expect(page.locator('.clipboard-row')).toHaveCount(1);
  await search.press('Enter');
  await expect.poll(() => app.evaluate(() => (globalThis as any).copies.length)).toBe(2);
  const imageCopy = await app.evaluate(() => (globalThis as any).copies.at(-1));
  assert.equal(imageCopy['image/png'], fixtures.find((f) => f.name === 'mixed')!.content);
  assert(!('text/plain' in imageCopy));
  await app.evaluate(() => (globalThis as any).shelf.show('keyboard', 'clipboard'));
  const failed = (await state()).clips.find((c) => c.ocr?.status === 'failed')!;
  await page.locator(`#clip-${failed.id}`).press('Meta+Enter');
  await expect(
    page.getByRole('button', { name: 'Повторить распознавание', exact: true }),
  ).toBeEnabled();
  await expect(page.locator('.clipboard-preview-content')).toHaveAttribute('aria-busy', 'false');
  await page.evaluate(() =>
    Promise.all(document.getAnimations().map((animation) => animation.finished)),
  );
  await page.screenshot({ path: join(artifacts, 'recognition-failed.png'), scale: 'css' });
  await page.getByRole('button', { name: 'Повторить распознавание', exact: true }).click();
  await expect(page.getByRole('region', { name: 'Распознанный текст', exact: true })).toContainText(
    'Распознаём',
  );
  await expect
    .poll(async () => (await state()).clips.find((c) => c.id === failed.id)?.ocr?.status, {
      timeout: 30000,
    })
    .toBe('ready');
  await page.getByRole('button', { name: 'Назад к списку', exact: true }).click();
  const empty = (await state()).clips.find((c) => c.ocr?.status === 'empty')!;
  await page.locator(`#clip-${empty.id}`).press('Meta+Enter');
  await expect(page.getByRole('region', { name: 'Распознанный текст', exact: true })).toContainText(
    'не найден',
  );
  await expect(page.getByRole('button', { name: 'Копировать текст', exact: true })).toHaveCount(0);
  await page.screenshot({ path: join(artifacts, 'recognition-empty.png'), scale: 'css' });
  const saved = await readFile(join(test.profile, 'clipboard-history/history.enc'));
  assert(!saved.includes(Buffer.from('Aurora')));
  test.assertNoRendererErrors();
  console.log(
    'OCR desktop passed: encrypted backfill, Russian/English/mixed search, excerpts, selectable text, explicit text copy, unchanged image selection, empty/failure/retry. No shared clipboard or desktop focus used.',
  );
}
runDesktopTest('image-text', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
