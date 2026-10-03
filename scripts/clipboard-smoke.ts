import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-clipboard-'));
  const launch = () =>
    electron.launch({
      ...(process.env.EVERYTHING_EXECUTABLE
        ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
        : { args: [resolve('.')] }),
      env: { ...process.env, EVERYTHING_PROFILE: profile },
    });
  let app = await launch();
  const errors: string[] = [];
  let savedClipboard: { type: string; bytes?: number[]; bookmark?: unknown }[][] = [];
  let originalClipboardSaved = false;
  function watch() {
    app
      .context()
      .on('page', (page) => page.on('pageerror', (reason) => errors.push(reason.message)));
  }
  watch();
  try {
    let shell = await app.firstWindow();
    await shell.locator('.home-page').waitFor();
    await expect
      .poll(() =>
        shell.evaluate(() =>
          window.platform.call('clipboardHistory.state').then((state) => state.registered),
        ),
      )
      .toBe(true);
    // Back up all formats in memory and restore on exit; never print the user's clipboard.
    savedClipboard = await app.evaluate(async ({ clipboard }) => {
      return Promise.all(
        (await clipboard.read()).map((item) =>
          Promise.all(
            item.types.map(async (type) => {
              const data = await item.getType(type);
              return data instanceof Blob
                ? { type, bytes: Array.from(new Uint8Array(await data.arrayBuffer())) }
                : { type, bookmark: data };
            }),
          ),
        ),
      );
    });
    originalClipboardSaved = true;
    // Ensure the helper has started before changing the clipboard.
    await new Promise((resolve) => setTimeout(resolve, 700));
    assert.equal(
      (await shell.evaluate(() => window.platform.call('clipboardHistory.state'))).error,
      undefined,
    );
    const copy = (text: string) =>
      app.evaluate(async ({ clipboard }, text) => {
        await clipboard.writeText(text);
      }, text);
    const clips = () =>
      shell.evaluate(() =>
        window.platform.call('clipboardHistory.state').then((state) => state.clips),
      );
    await copy('Первый пример: план проекта');
    await expect.poll(async () => (await clips()).length).toBe(1);
    await copy('Второй пример: https://example.com/reference');
    await expect.poll(async () => (await clips()).length).toBe(2);
    const opening = app.waitForEvent('window');
    await shell.evaluate(() => window.platform.call('clipboardHistory.show'));
    let panel = await opening;
    const panelId = await app.evaluate(
      ({ BrowserWindow }) =>
        BrowserWindow.getAllWindows().find((win) =>
          win.webContents.getURL().includes('mode=clipboard'),
        )!.id,
    );
    const visible = () =>
      app.evaluate(({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.isVisible(), panelId);
    const search = panel.getByRole('combobox', { name: 'Найти в истории' });
    await expect(search).toBeFocused();
    await expect(panel.getByRole('option')).toHaveCount(2);
    await search.fill('план');
    await expect(panel.getByRole('option')).toHaveCount(1);
    await panel.getByRole('button', { name: 'Закрепить запись', exact: true }).click();
    await expect(
      panel.getByRole('button', { name: 'Открепить запись', exact: true }),
    ).toBeVisible();
    await search.press('Enter');
    await expect.poll(visible).toBe(false);
    assert.equal(
      await app.evaluate(({ clipboard }) => clipboard.readText()),
      'Первый пример: план проекта',
    );
    await shell.evaluate(() => window.platform.call('clipboardHistory.show'));
    await expect(panel.getByRole('option')).toHaveCount(2);
    await expect(panel.getByRole('option').first()).toContainText('Первый пример');
    await panel.getByRole('button', { name: 'Приостановить запись' }).click();
    await copy('Paused clipboard QA');
    await new Promise((resolve) => setTimeout(resolve, 650));
    assert.equal((await clips()).length, 2);
    await panel.getByRole('button', { name: 'Продолжить запись' }).click();
    await app.evaluate(async ({ clipboard, ClipboardItem }) => {
      await clipboard.write([
        new ClipboardItem({
          'text/plain': 'Concealed QA',
          'electron application/osclipboard;format="org.nspasteboard.ConcealedType"': new Blob([
            '',
          ]),
        }),
      ]);
    });
    await new Promise((resolve) => setTimeout(resolve, 650));
    assert.equal((await clips()).length, 2);
    await app.evaluate(async ({ clipboard, ClipboardItem, nativeImage }) => {
      const image = nativeImage.createFromBitmap(
        Buffer.from(Array.from({ length: 64 * 40 }, () => [110, 170, 200, 255]).flat()),
        { width: 64, height: 40 },
      );
      if (image.isEmpty()) throw Error('QA image is empty');
      await clipboard.write([
        new ClipboardItem({
          'image/png': new Blob([new Uint8Array(image.toPNG())], { type: 'image/png' }),
        }),
      ]);
    });
    await expect.poll(async () => (await clips()).length).toBe(3);
    await expect(panel.getByRole('img', { name: 'Скопированное изображение' })).toBeVisible();
    await panel
      .getByRole('option')
      .filter({ has: panel.getByRole('img', { name: 'Скопированное изображение' }) })
      .click();
    await expect.poll(visible).toBe(false);
    assert(await app.evaluate(({ clipboard }) => clipboard.has('image/png')));
    await shell.evaluate(() => window.platform.call('clipboardHistory.show'));
    await search.fill('невозможный запрос');
    await panel.getByText('Ничего не найдено').waitFor();
    await search.fill('');
    await search.hover();
    await expect(panel.locator('.mantine-Tooltip-tooltip')).toHaveCount(0);
    await mkdir('artifacts', { recursive: true });
    await panel.screenshot({ path: 'artifacts/clipboard-shelf.png' });
    await panel.keyboard.press('Escape');
    await expect.poll(visible).toBe(false);
    // Drive the real pointer polling entrypoint with a deterministic top-edge position.
    await app.evaluate(({ screen }) => {
      (globalThis as any).__realCursor = screen.getCursorScreenPoint;
      const { bounds } = screen.getPrimaryDisplay();
      (globalThis as any).__qaCursor = {
        x: Math.round(bounds.x + bounds.width / 2),
        y: bounds.y + 1,
      };
      screen.getCursorScreenPoint = () => (globalThis as any).__qaCursor;
    });
    // Leave the hot zone first to reset dismissal suppression.
    await app.evaluate(() => {
      (globalThis as any).__qaCursor.y += 100;
    });
    await new Promise((resolve) => setTimeout(resolve, 180));
    await app.evaluate(() => {
      (globalThis as any).__qaCursor.y -= 100;
    });
    await expect.poll(visible).toBe(true);
    assert.equal(
      await app.evaluate(({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.isFocused(), panelId),
      false,
    );
    await app.evaluate(({ BrowserWindow }, id) => {
      const bounds = BrowserWindow.fromId(id)!.getBounds();
      (globalThis as any).__qaCursor = { x: bounds.x + 100, y: bounds.y + 100 };
    }, panelId);
    await new Promise((resolve) => setTimeout(resolve, 700));
    assert(await visible());
    await app.evaluate(() => {
      (globalThis as any).__qaCursor = { x: 0, y: 500 };
    });
    await expect.poll(visible).toBe(false);
    await app.evaluate(({ screen }) => {
      screen.getCursorScreenPoint = (globalThis as any).__realCursor;
    });
    // Rebinding uses the registered OS callback, and a conflicting replacement keeps it intact.
    await app.evaluate(({ globalShortcut }) => {
      const register = globalShortcut.register.bind(globalShortcut);
      globalShortcut.register = (accelerator, callback) => {
        const ok = register(accelerator, callback);
        if (ok) (globalThis as any).__clipboardShortcut = callback;
        return ok;
      };
    });
    await shell.evaluate(() =>
      window.platform.call('clipboardHistory.shortcut', { accelerator: 'Control+Alt+Shift+F11' }),
    );
    const conflict = await shell.evaluate(async () => {
      try {
        await window.platform.call('clipboardHistory.shortcut', {
          accelerator: 'CommandOrControl+Shift+Space',
        });
        return false;
      } catch {
        return true;
      }
    });
    assert(conflict);
    assert.equal(
      (await shell.evaluate(() => window.platform.call('clipboardHistory.state'))).preferences
        .accelerator,
      'Control+Alt+Shift+F11',
    );
    await app.evaluate(() => (globalThis as any).__clipboardShortcut());
    await expect.poll(visible).toBe(true);
    await expect(search).toBeFocused();
    await app.evaluate(() => (globalThis as any).__clipboardShortcut());
    await expect.poll(visible).toBe(false);
    // Settings persist alongside encrypted history; close via the app's normal flush path.
    await shell.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', {
        paused: true,
        hoverEnabled: false,
        retentionDays: 30,
      }),
    );
    const encrypted = await readFile(join(profile, 'clipboard-history', 'history.enc'));
    assert(!encrypted.includes(Buffer.from('Первый пример')));
    await app.close();
    app = await launch();
    watch();
    shell = await app.firstWindow();
    await shell.locator('.home-page').waitFor();
    await expect.poll(async () => (await clips()).length).toBe(3);
    const restored = await shell.evaluate(() => window.platform.call('clipboardHistory.state'));
    assert.equal(restored.preferences.paused, true);
    assert.equal(restored.preferences.hoverEnabled, false);
    assert.equal(restored.preferences.retentionDays, 30);
    assert.equal(restored.preferences.accelerator, 'Control+Alt+Shift+F11');
    assert.equal(restored.clips.filter((clip: any) => clip.pinned).length, 1);
    const reopened = app.waitForEvent('window');
    await shell.evaluate(() => window.platform.call('clipboardHistory.show'));
    panel = await reopened;
    await panel.getByRole('button', { name: 'Очистить…' }).click();
    await panel.getByRole('button', { name: 'Удалить всю историю', exact: true }).click();
    await expect.poll(async () => (await clips()).length).toBe(0);
    await panel.getByText('Здесь появится скопированное').waitFor();
    assert.deepEqual(errors, []);
    console.log(
      'Clipboard smoke passed: capture, search, pins, pause, sensitive exclusion, images, hover, encryption, restart and clear.',
    );
  } finally {
    if (originalClipboardSaved)
      await app
        .evaluate(async ({ clipboard, ClipboardItem }, items) => {
          if (!items.length) {
            clipboard.clear();
            return;
          }
          await clipboard.write(
            items.map(
              (item) =>
                new ClipboardItem(
                  Object.fromEntries(
                    item.map((entry) => [
                      entry.type,
                      entry.bytes
                        ? new Blob([new Uint8Array(entry.bytes)])
                        : (entry.bookmark as any),
                    ]),
                  ),
                ),
            ),
          );
        }, savedClipboard)
        .catch(() => {});
    await app.close().catch(() => {});
    await rm(profile, { recursive: true, force: true });
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
