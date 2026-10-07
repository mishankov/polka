import { build } from 'esbuild';
import { expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdir, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { runDesktopTest, type DesktopTest } from './desktop-test';
import type { ClipboardState } from '../src/shared/clipboard';

async function main(test: DesktopTest) {
  const syntheticRecognition = process.env.POLKA_SKIP_NATIVE_OCR === '1';
  const entry = join(test.profile, 'ocr-fixture.cjs');
  const fixtures = await Promise.all(
    ['english', 'russian', 'mixed', 'empty', 'failure'].map(async (name) => ({
      name,
      content: (await readFile(`tests/fixtures/image-text/${name}.png`)).toString('base64'),
    })),
  );
  // Real encrypted history, indexer, shelf handlers and renderer. Local runs use
  // native Vision; hosted CI substitutes only the recognition function because
  // Apple's accurate model cannot compile on that runner.
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
      globalThis.ocrActions = [];
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
        if (method === 'clipboardHistory.copyImageText' || method === 'clipboardHistory.retryImageText') globalThis.ocrActions.push(method);
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
    plugins: syntheticRecognition
      ? [
          {
            name: 'synthetic-vision',
            setup(builder) {
              builder.onResolve({ filter: /^\.\/image-text$/ }, () => ({
                path: 'synthetic-vision',
                namespace: 'synthetic-vision',
              }));
              builder.onLoad({ filter: /.*/, namespace: 'synthetic-vision' }, () => ({
                contents: `
                  export { ImageTextIndexer } from './src/main/image-text';
                  import { setTimeout } from 'node:timers/promises';
                  const texts = {
                    english: 'Project Aurora\\nDelivery confirmed\\nInvoice 2048',
                    russian: 'Проект Север\\nДоставка подтверждена\\nСчёт 2048',
                    mixed: 'Project Aurora / Проект Север\\nDelivery confirmed / Доставка подтверждена\\nInvoice 2048 / Счёт 2048',
                    empty: '',
                    failure: 'Retry succeeded',
                  };
                  const fixtures = ${JSON.stringify(fixtures)};
                  export async function recognizeImageText(path, content, signal) {
                    // Keep recognition asynchronous so pending/retry states and
                    // actual indexer scheduling remain exercised in CI.
                    await setTimeout(250, undefined, { signal });
                    const fixture = fixtures.find(f => f.content === content);
                    if (!fixture) throw Error('Unexpected synthetic OCR input');
                    return { text: texts[fixture.name], languages: ['ru-RU', 'en-US'] };
                  }
                `,
                resolveDir: resolve('.'),
                loader: 'ts',
              }));
            },
          },
        ]
      : [],
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
  const preview = page.getByRole('region', { name: 'Просмотр записи', exact: true });
  const textButton = page.getByRole('button', { name: 'Копировать текст', exact: true });
  await expect(textButton).toHaveAttribute('aria-keyshortcuts', 'Meta+2');
  await expect(textButton).toContainText('⌘2');
  const ocrActions = () => app.evaluate(() => (globalThis as any).ocrActions.length);
  const shortcut = (extra = {}) =>
    preview.dispatchEvent('keydown', {
      key: 'é',
      code: 'Digit2',
      metaKey: true,
      ...extra,
    });
  async function ignoredShortcuts() {
    const count = await ocrActions();
    await shortcut({ repeat: true });
    await shortcut({ isComposing: true });
    await shortcut({ ctrlKey: true });
    await shortcut({ altKey: true });
    await shortcut({ shiftKey: true });
    await page.evaluate(() => {
      const dialog = document.createElement('section');
      dialog.id = 'ocr-shortcut-dialog';
      dialog.setAttribute('role', 'dialog');
      document.body.append(dialog);
    });
    await shortcut();
    await page.locator('#ocr-shortcut-dialog').evaluate((e) => e.remove());
    await state(); // Flush preceding IPC from the same renderer before comparing.
    assert.equal(await ocrActions(), count);
  }
  await ignoredShortcuts();
  const save = page.getByRole('button', { name: 'Сохранить изображение…', exact: true });
  await expect(save).toHaveAttribute('aria-keyshortcuts', 'Meta+1');
  await save.focus();
  await page.keyboard.press('Meta+1');
  await expect(save).toBeDisabled();
  await expect(textButton).toBeDisabled();
  await shortcut();
  await state();
  assert.equal(await ocrActions(), 0, 'Save dialog/busy state blocks extraction');
  await app.evaluate(() => (globalThis as any).finishSave());
  await expect(save).toBeEnabled();
  await expect(save).toBeFocused();
  await page.screenshot({ path: join(artifacts, 'image-preview.png'), scale: 'css' });
  await textButton.click();
  await expect.poll(() => app.evaluate(() => (globalThis as any).copies.length)).toBe(1);
  const textCopy = await app.evaluate(() => (globalThis as any).copies.at(-1));
  assert.equal(Buffer.from(textCopy['text/plain'], 'base64').toString(), fullText);
  assert(!('image/png' in textCopy));
  await app.evaluate(() => (globalThis as any).shelf.show('keyboard', 'clipboard', 'Aurora Север'));
  await expect(search).toBeFocused();
  await expect(search).toBeEnabled();
  await expect(page.locator('.clipboard-row')).toHaveCount(1);
  await search.press('Meta+Enter');
  await shortcut(); // Physical digit binding works with a non-English character.
  await expect.poll(() => app.evaluate(() => (globalThis as any).copies.length)).toBe(2);
  assert.deepEqual(await app.evaluate(() => (globalThis as any).copies.at(-1)), textCopy);
  // Searching by OCR words and selecting the matching row still copies pixels.
  await app.evaluate(() => (globalThis as any).shelf.show('keyboard', 'clipboard', 'Aurora Север'));
  await expect(search).toBeFocused();
  await expect(page.locator('.clipboard-row')).toHaveCount(1);
  await search.press('Enter');
  await expect.poll(() => app.evaluate(() => (globalThis as any).copies.length)).toBe(3);
  const imageCopy = await app.evaluate(() => (globalThis as any).copies.at(-1));
  assert.equal(imageCopy['image/png'], fixtures.find((f) => f.name === 'mixed')!.content);
  assert(!('text/plain' in imageCopy));
  await app.evaluate(() => (globalThis as any).shelf.show('keyboard', 'clipboard'));
  await expect(search).toBeFocused();
  const retainedQuery = await search.inputValue();
  const failed = (await state()).clips.find((c) => c.ocr?.status === 'failed')!;
  await page.locator(`#clip-${failed.id}`).press('Meta+Enter');
  const retry = page.getByRole('button', { name: 'Повторить распознавание', exact: true });
  await expect(retry).toBeEnabled();
  await expect(retry).toHaveAttribute('aria-keyshortcuts', 'Meta+2');
  await expect(retry).toContainText('⌘2');
  await ignoredShortcuts();
  await expect(page.locator('.clipboard-preview-content')).toHaveAttribute('aria-busy', 'false');
  await page.evaluate(() =>
    Promise.all(document.getAnimations().map((animation) => animation.finished)),
  );
  await page.screenshot({ path: join(artifacts, 'recognition-failed.png'), scale: 'css' });
  await retry.focus();
  await shortcut();
  await expect(page.getByRole('region', { name: 'Распознанный текст', exact: true })).toContainText(
    'Распознаём',
  );
  await expect
    .poll(async () => (await state()).clips.find((c) => c.id === failed.id)?.ocr?.status, {
      timeout: 30000,
    })
    .toBe('ready');
  await expect(page.getByRole('button', { name: 'Назад к списку', exact: true })).toBeFocused();
  await page.keyboard.press('Backspace');
  await expect(search).toBeFocused();
  await expect(search).toHaveValue(retainedQuery);
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
    `OCR desktop passed (${syntheticRecognition ? 'synthetic recognition; native Vision excluded' : 'native Vision'}): encrypted backfill, Russian/English/mixed search, excerpts, selectable text, explicit text copy, unchanged image selection, empty/failure/retry, shortcut metadata, keyboard actions/focus, non-English physical digits, composition/repeat/busy/dialog guards. No shared clipboard or desktop focus used.`,
  );
}
runDesktopTest('image-text', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
