import { runDesktopTest, type DesktopTest } from './desktop-test';
import { clipId } from '../../src/main/clipboard-history';
import { expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import type { ClipboardState } from '../../src/shared/clipboard';

async function main(test: DesktopTest) {
  const profile = test.profile;
  const app = await test.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
  });
  try {
    const panel = await app.firstWindow();
    await panel.locator('.launcher').waitFor();
    await expect
      .poll(() =>
        panel.evaluate(() =>
          window.platform.call('clipboardHistory.state').then((s) => s.registered),
        ),
      )
      .toBe(true);
    await panel.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', {
        hoverEnabled: false,
        pasteOnSelect: false,
      }),
    );
    await test.backupClipboard(app);
    // Substitute only the OS action boundaries; storage and IPC stay real.
    await app.evaluate(async ({ shell, dialog }) => {
      const qa = globalThis as any;
      qa.originalOpen = shell.openExternal;
      qa.originalSave = dialog.showSaveDialog;
      qa.opened = [];
      qa.dialogs = [];
      shell.openExternal = async (url) => {
        qa.opened.push(url);
      };
      // Substitute the OS boundary only: real IPC, history, PNG bytes and file writes remain in use.
      dialog.showSaveDialog = async (owner: any, options?: any) => {
        qa.dialogs.push(options);
        owner.emit('blur');
        await new Promise((resolve) => setTimeout(resolve, 120));
        return qa.saveResult ?? { canceled: true };
      };
    });
    const clips = () =>
      panel.evaluate(() =>
        window.platform.call<ClipboardState>('clipboardHistory.state').then((s) => s.clips),
      );
    const show = async () => {
      await panel.evaluate(() => window.platform.call('clipboardHistory.show'));
      await expect(panel.getByRole('option').first()).toBeVisible();
      await expect(search).toBeFocused();
    };
    const copy = (text: string) =>
      app.evaluate(async ({ clipboard }, value) => clipboard.writeText(value), text);
    const search = panel.getByRole('combobox', { name: 'Найти в истории' });
    const preview = panel.getByRole('region', { name: 'Просмотр записи' });
    const source = 'Привет, World!\r\n  Вторая строка\r\n\r\nАбзац 🦔';
    await copy(source);
    await test.keepClipboardFixture(panel, clipId('text', source));
    await show();
    await search.fill('World');
    await search.press('Meta+Enter');
    await expect(preview.getByRole('button', { name: 'ПРОПИСНЫЕ', exact: true })).toHaveAttribute(
      'aria-keyshortcuts',
      'Meta+1',
    );
    await panel.keyboard.press('Meta+1');
    await expect(preview.locator('pre')).toHaveText(source.toUpperCase());
    await expect(preview.getByRole('status')).toContainText('Оригинал сохранён');
    assert.equal((await clips())[0].content, source);
    await panel.screenshot({ path: join(test.artifacts, 'clipboard-actions-text.png') });
    await panel.keyboard.press('Backspace');
    await expect(preview).toHaveCount(0);
    await expect(search).toBeFocused();
    await expect(search).toHaveValue('World');
    await search.press('Backspace');
    await expect(search).toHaveValue('Worl');
    await search.press('Meta+Enter');
    await preview.dispatchEvent('keydown', { key: '1', metaKey: true, repeat: true });
    await expect(preview.locator('pre')).toHaveText(source);
    await panel.keyboard.press('Meta+1');
    await expect(preview.getByRole('button', { name: 'Показать оригинал' })).toHaveAttribute(
      'aria-keyshortcuts',
      'Meta+3',
    );
    await panel.keyboard.press('Meta+3');
    await expect(preview.locator('pre')).toHaveText(source);
    await expect(panel.getByRole('button', { name: 'Назад к списку', exact: true })).toBeFocused();
    await panel.keyboard.press('Meta+1');
    await expect(preview.locator('pre')).toHaveText(source.toUpperCase());
    await preview.getByRole('button', { name: 'Копировать', exact: true }).click();
    assert.equal(await app.evaluate(({ clipboard }) => clipboard.readText()), source.toUpperCase());
    await show();
    assert.equal((await clips()).length, 1);
    assert.equal((await clips())[0].content, source);
    await search.press('Meta+Enter');
    await panel.keyboard.press('Meta+2');
    await expect(preview.locator('pre')).toHaveText(source.toLowerCase());
    await panel.getByRole('button', { name: 'Назад к списку', exact: true }).press('Shift+Enter');
    assert.equal(await app.evaluate(({ clipboard }) => clipboard.readText()), source.toLowerCase());
    await show();
    await search.press('Meta+Enter');
    await preview.getByRole('button', { name: 'ПРОПИСНЫЕ', exact: true }).click();
    await panel.getByRole('button', { name: 'Действия с историей' }).click();
    await panel.getByRole('button', { name: 'Копировать без вставки · ⇧↵' }).click();
    await expect
      .poll(() => app.evaluate(({ clipboard }) => clipboard.readText()))
      .toBe(source.toUpperCase());
    await copy('https://example.com/path?q=1#part');
    await expect.poll(async () => (await clips()).length).toBe(2);
    await show();
    await search.fill('https');
    const openLink = panel.getByRole('button', { name: 'Открыть ссылку в браузере' });
    await expect(openLink).toBeVisible();
    await expect(openLink).toHaveAttribute('aria-keyshortcuts', 'Meta+Alt+1');
    await expect
      .poll(() =>
        panel
          .locator('.clipboard-shelf')
          .evaluate((element) =>
            element.getAnimations().some((animation) => animation.playState === 'running'),
          ),
      )
      .toBe(false);
    await panel.screenshot({ path: join(test.artifacts, 'clipboard-actions-link-list.png') });
    await search.press('Meta+Enter');
    assert.deepEqual(await app.evaluate(() => (globalThis as any).opened), []);
    await expect(preview.getByRole('button', { name: 'Открыть ссылку в браузере' })).toHaveCount(0);
    await panel.keyboard.press('Backspace');
    await expect(search).toBeFocused();
    await openLink.click();
    assert.deepEqual(await app.evaluate(() => (globalThis as any).opened), [
      'https://example.com/path?q=1#part',
    ]);
    await show();
    await search.fill('https');
    await search.press('Meta+Alt+1');
    await expect.poll(() => app.evaluate(() => (globalThis as any).opened.length)).toBe(2);
    assert.deepEqual(await app.evaluate(() => (globalThis as any).opened), [
      'https://example.com/path?q=1#part',
      'https://example.com/path?q=1#part',
    ]);
    await copy('javascript:alert(1)');
    await expect.poll(async () => (await clips()).length).toBe(3);
    await show();
    await search.fill('javascript');
    await expect(openLink).toHaveCount(0);
    await search.press('Meta+Alt+1');
    assert.equal(await app.evaluate(() => (globalThis as any).opened.length), 2);
    await search.press('Meta+Enter');
    await expect(preview.getByRole('button', { name: 'Открыть ссылку в браузере' })).toHaveCount(0);
    await expect(preview.getByRole('button', { name: 'строчные', exact: true })).toBeDisabled();
    await panel.keyboard.press('Meta+2');
    await expect(preview.locator('pre')).toHaveText('javascript:alert(1)');
    await expect(preview.getByRole('button', { name: 'Показать оригинал' })).toHaveCount(0);
    await expect(preview.getByRole('button', { name: 'строчные', exact: true })).toHaveAttribute(
      'title',
      'Исходный текст уже в этом виде',
    );
    const invalid = (await clips()).find((c) => c.content.startsWith('javascript'))!;
    await assert.rejects(
      panel.evaluate((id) => window.platform.call('clipboardHistory.openUrl', { id }), invalid.id),
      /HTTP/,
    );
    await assert.rejects(
      panel.evaluate(
        (id) => window.platform.call('clipboardHistory.saveImage', { id }),
        invalid.id,
      ),
      /только для изображений/,
    );
    await app.evaluate(async ({ clipboard, ClipboardItem, nativeImage }) => {
      const bytes = nativeImage
        .createFromBitmap(Buffer.alloc(1200 * 900 * 4, 255), { width: 1200, height: 900 })
        .toPNG();
      await clipboard.write([
        new ClipboardItem({
          'image/png': new Blob([new Uint8Array(bytes)], { type: 'image/png' }),
        }),
      ]);
    });
    await expect.poll(async () => (await clips()).length).toBe(4);
    await panel.getByRole('button', { name: 'Назад к списку', exact: true }).click();
    await search.fill('');
    const imageRow = panel
      .locator('.clipboard-row')
      .filter({ has: panel.getByRole('img', { name: 'Скопированное изображение' }) });
    await expect(imageRow.getByRole('button', { name: 'Открыть ссылку в браузере' })).toHaveCount(
      0,
    );
    const image = (await clips()).find((c) => c.kind === 'image')!;
    await assert.rejects(
      panel.evaluate(
        (id) => window.platform.call('clipboardHistory.copy', { id, transformation: 'upperCase' }),
        image.id,
      ),
      /только для текста/,
    );
    const save = imageRow.getByRole('button', { name: 'Сохранить изображение…' });
    await expect(save).toHaveAttribute('aria-keyshortcuts', 'Meta+Alt+1');
    await panel.screenshot({ path: join(test.artifacts, 'clipboard-actions-image-list.png') });
    await search.press('Meta+Alt+1');
    await expect(save).toBeEnabled();
    await expect(preview).toHaveCount(0);
    assert.equal(
      await panel.evaluate(() => window.platform.call('shelf.presentation').then((s) => s.visible)),
      true,
      'Dialog blur and cancellation keep the shelf open',
    );
    await expect(panel.getByText('Изображение сохранено', { exact: true })).toHaveCount(0);
    const path = join(profile, 'saved.png');
    await app.evaluate((_, filePath) => {
      (globalThis as any).saveResult = { canceled: false, filePath };
    }, path);
    await save.click();
    await expect(panel.getByText('Изображение сохранено', { exact: true })).toBeVisible();
    const saved = await readFile(path);
    assert.equal(
      clipId('image', saved.toString('base64')),
      image.id,
      'Save uses the captured PNG bytes',
    );
    assert.deepEqual(
      await app.evaluate(
        ({ nativeImage }, filePath) => nativeImage.createFromPath(filePath).getSize(),
        path,
      ),
      { width: 1200, height: 900 },
    );
    await expect(save).toBeEnabled();
    await imageRow.getByRole('button', { name: 'Просмотреть запись' }).click();
    await expect(preview.getByRole('button', { name: 'ПРОПИСНЫЕ' })).toHaveCount(0);
    const previewSave = preview.getByRole('button', { name: 'Сохранить изображение…' });
    await expect(previewSave).toHaveAttribute('aria-keyshortcuts', 'Meta+1');
    await app.evaluate(
      (_, filePath) => {
        (globalThis as any).saveResult = { canceled: false, filePath };
      },
      join(profile, 'missing', 'failed.png'),
    );
    await panel.keyboard.press('Meta+1');
    await expect(panel.getByRole('alert')).toContainText('Не удалось сохранить изображение');
    await expect(previewSave).toBeEnabled();
    await panel.screenshot({ path: join(test.artifacts, 'clipboard-actions-save-error.png') });
    await app.evaluate((_, filePath) => {
      (globalThis as any).saveResult = { canceled: false, filePath };
    }, path);
    await previewSave.click();
    await expect(panel.getByText('Изображение сохранено', { exact: true })).toBeVisible();
    await expect(panel.getByRole('alert')).toHaveCount(0);
    const dialogs = await app.evaluate(() => (globalThis as any).dialogs);
    assert.equal(dialogs.length, 4);
    assert.deepEqual(dialogs[0].filters, [{ name: 'Изображение PNG', extensions: ['png'] }]);
    assert.equal((await clips()).length, 4);
    if (process.argv.includes('--native')) {
      await app.evaluate(({ dialog }) => {
        dialog.showSaveDialog = (globalThis as any).originalSave;
      });
      console.log('Native save dialog ready for cancellation.');
      await previewSave.click();
      await expect(previewSave).toBeEnabled({ timeout: 60000 });
      assert.equal(
        await panel.evaluate(() =>
          window.platform.call('shelf.presentation').then((s) => s.visible),
        ),
        true,
      );
      await expect(panel.getByText('Изображение сохранено', { exact: true })).toHaveCount(0);
      console.log('Native save dialog cancellation passed.');
    }
    await expect(previewSave).toBeEnabled();
    await expect(previewSave).toBeFocused();
    await panel.keyboard.press('Backspace');
    await expect(search).toBeFocused();
    await panel.getByRole('button', { name: 'Действия с историей' }).click();
    await panel.getByRole('button', { name: 'Очистить историю на всех связанных Mac…' }).click();
    await panel.keyboard.press('Backspace');
    await expect(panel.locator('.clipboard-confirm')).toHaveCount(0);
    await expect(search).toBeFocused();
    await search.press('Backspace');
    await expect(
      panel.getByRole('combobox', { name: 'Поиск по полке', exact: true }),
    ).toBeFocused();
    console.log(
      'Clipboard actions passed: Cmd+number shortcuts, Backspace navigation and text editing, result preview, original preservation, transformed copy, Shift+Enter, explicit validated URLs, PNG save, cancellation, dialog blur and write failure.',
    );
  } finally {
    await app
      .evaluate(async ({ shell, dialog }) => {
        const qa = globalThis as any;
        if (qa.originalOpen) shell.openExternal = qa.originalOpen;
        if (qa.originalSave) dialog.showSaveDialog = qa.originalSave;
      })
      .catch(() => {});
  }
}
runDesktopTest('clipboard-actions', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
