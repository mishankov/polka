import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { shelfGeometry } from '../src/main/clipboard-hover';

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
  let savedClipboard: { type: string; bytes?: string; bookmark?: unknown }[][] = [];
  let originalClipboardSaved = false;
  function watch() {
    app
      .context()
      .on('page', (page) => page.on('pageerror', (reason) => errors.push(reason.message)));
  }
  watch();
  try {
    let shell = await app.firstWindow();
    await shell.locator('.launcher').waitFor();
    await expect
      .poll(() =>
        shell.evaluate(() =>
          window.platform.call('clipboardHistory.state').then((state) => state.registered),
        ),
      )
      .toBe(true);
    // Keep the real pointer from opening the shelf before the test's hover phase.
    await shell.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', {
        hoverEnabled: false,
        pasteOnSelect: false,
      }),
    );
    // Back up all formats in memory and restore on exit; never print the user's clipboard.
    savedClipboard = await app.evaluate(async ({ clipboard }) => {
      return Promise.all(
        (await clipboard.read())
          .filter((item) => item.types.length > 0)
          .map((item) =>
            Promise.all(
              item.types.map(async (type) => {
                const data = await item.getType(type);
                return data instanceof Blob
                  ? { type, bytes: Buffer.from(await data.arrayBuffer()).toString('base64') }
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
    // The main shelf combines arithmetic, app launch and clipboard search.
    await shell.evaluate(() => window.platform.call('launcher.show'));
    const mainSearch = shell.getByRole('combobox', { name: 'Поиск по полке', exact: true });
    await expect(mainSearch).toBeFocused();
    await mainSearch.fill('1250 * 3');
    await expect(shell.locator('.launcher-calculation strong')).toHaveText('3750');
    await expect(shell.locator('.launcher-footer')).toContainText('копировать результат');
    assert.equal(await mainSearch.evaluate((el) => el.getBoundingClientRect().height), 56);
    await mainSearch.press('Enter');
    await expect(shell.locator('.launcher-calculation')).toContainText('Скопировано');
    assert.equal(await app.evaluate(({ clipboard }) => clipboard.readText()), '3750');
    await mainSearch.fill('10 inches in cm');
    await expect(shell.locator('.launcher-calculation strong')).toHaveText('25.4 cm');
    await mainSearch.press('Enter');
    await expect(shell.locator('.launcher-calculation')).toContainText('Скопировано');
    assert.equal(await app.evaluate(({ clipboard }) => clipboard.readText()), '25.4 cm');
    await mainSearch.fill('2026-07-15 18:00 Moscow in London');
    await expect(shell.locator('.launcher-calculation strong')).toHaveText('16:00 Лондон');
    await shell.locator('.launcher-calculation').click();
    await expect(shell.locator('.launcher-calculation')).toContainText('Скопировано');
    assert.equal(
      await app.evaluate(({ clipboard }) => clipboard.readText()),
      '16:00 · 2026-07-15 · Лондон (UTC+01:00)',
    );
    // Copy an undated query using the displayed source date, even after midnight.
    await shell.evaluate(() =>
      window.platform.call('shelf.copyCalculation', {
        expression: '18:00 Moscow in London',
        sourceDate: '2026-01-15',
      }),
    );
    assert.equal(
      await app.evaluate(({ clipboard }) => clipboard.readText()),
      '15:00 · 2026-01-15 · Лондон (UTC+00:00)',
    );
    await mainSearch.fill('2026-03-08 02:30 New York in UTC');
    await expect(shell.locator('.launcher-calculation-status')).toContainText(
      'Такого местного времени нет',
    );
    await mainSearch.press('Enter');
    assert.equal(
      await app.evaluate(({ clipboard }) => clipboard.readText()),
      '15:00 · 2026-01-15 · Лондон (UTC+00:00)',
    );
    assert(
      await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .find((win) => win.webContents.getURL().includes('mode=shelf'))!
          .isVisible(),
      ),
    );
    await expect(mainSearch).toBeFocused();
    await mainSearch.fill('1 / 0');
    await expect(shell.getByText('На ноль делить нельзя')).toBeVisible();
    await expect(shell.locator('.launcher-calculation')).toHaveCount(0);
    await mainSearch.fill('12 +');
    await expect(shell.getByText('Продолжите выражение…')).toBeVisible();
    await mainSearch.fill('15% от 240');
    await expect(shell.locator('.launcher-calculation strong')).toHaveText('36');
    await shell.locator('.launcher-calculation').click();
    await expect(mainSearch).toBeFocused();
    await expect(shell.locator('.launcher-calculation')).toContainText('Скопировано');
    assert.equal(await app.evaluate(({ clipboard }) => clipboard.readText()), '36');
    await shell.screenshot({ path: '/tmp/everything-shelf-calculator.png' });
    assert.equal((await clips()).length, 2, 'Calculator copying must not add history entries');
    await mainSearch.fill('пример');
    const shelfClips = shell.locator('.launcher-result[data-kind="clip"]');
    await expect(shelfClips).toHaveCount(2);
    await expect(shelfClips.first()).toHaveAttribute('aria-selected', 'true');
    await mainSearch.press('ArrowDown');
    await expect(shelfClips.nth(1)).toHaveAttribute('aria-selected', 'true');
    await mainSearch.press('Shift+Enter');
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows()
            .find((win) => win.webContents.getURL().includes('mode=shelf'))!
            .isVisible(),
        ),
      )
      .toBe(false);
    assert.equal(
      await app.evaluate(({ clipboard }) => clipboard.readText()),
      'Первый пример: план проекта',
    );
    await shell.evaluate(() => window.platform.call('launcher.show'));
    await expect(mainSearch).toHaveValue('');
    await expect(shelfClips).toHaveCount(0);
    const existingPanel = app.windows().find((page) => page.url().includes('mode=shelf'));
    const opening = existingPanel ? Promise.resolve(existingPanel) : app.waitForEvent('window');
    await shell.evaluate(() => window.platform.call('clipboardHistory.show'));
    let panel = await opening;
    const panelId = await app.evaluate(
      ({ BrowserWindow }) =>
        BrowserWindow.getAllWindows().find((win) =>
          win.webContents.getURL().includes('mode=shelf'),
        )!.id,
    );
    const visible = () =>
      app.evaluate(({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.isVisible(), panelId);
    const search = panel.getByRole('combobox', { name: 'Найти в истории' });
    await expect(search).toBeFocused();
    await expect
      .poll(() =>
        panel
          .locator('.clipboard-shelf')
          .evaluate((element) =>
            element.getAnimations().some((animation) => animation.playState === 'running'),
          ),
      )
      .toBe(false);
    await expect(panel.getByRole('option')).toHaveCount(2);
    await search.press('Meta+Enter');
    await expect(panel.getByRole('region', { name: 'Просмотр записи' })).toBeVisible();
    await expect(panel.locator('.clipboard-preview pre')).toHaveText(
      'Второй пример: https://example.com/reference',
    );
    await panel.keyboard.press('Escape');
    await expect(search).toBeFocused();
    assert(await visible(), 'Closing the preview must keep the shelf open');
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
    await expect(panel.getByRole('button', { name: 'Приостановить запись' })).toHaveCount(0);
    await shell.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', { paused: true }),
    );
    await copy('Paused clipboard QA');
    await new Promise((resolve) => setTimeout(resolve, 650));
    assert.equal((await clips()).length, 2);
    await shell.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', { paused: false }),
    );
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
    const imageRow = panel
      .locator('.clipboard-row')
      .filter({ has: panel.getByRole('img', { name: 'Скопированное изображение' }) });
    await expect.poll(visible).toBe(true);
    await imageRow.hover();
    await imageRow.getByRole('button', { name: 'Просмотреть запись' }).click();
    await expect(
      panel.getByRole('img', { name: 'Просмотр скопированного изображения' }),
    ).toBeVisible();
    await panel.getByRole('button', { name: 'Назад', exact: true }).click();
    await expect(search).toBeFocused();
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
    const savedIds = (await clips()).map((clip: any) => clip.id);
    const longText =
      'Обсудить макет на следующей встрече: поиск\n' +
      'Проверить поиск, изображения и длинные записи.\n'.repeat(20);
    for (const text of [
      longText,
      'Поиск: npm run typecheck',
      'Поиск: https://example.com/design',
      'Поиск: сначала найти, затем скопировать',
    ]) {
      const count = (await clips()).length;
      await copy(text);
      await expect.poll(async () => (await clips()).length).toBe(count + 1);
    }
    await shell.evaluate(() => window.platform.call('launcher.show'));
    await mainSearch.fill('поиск');
    await expect(shelfClips).toHaveCount(3);
    await shell.screenshot({ path: '/tmp/everything-shelf-search.png' });
    const moreClips = shell.getByRole('option', { name: /Показать все записи/ });
    await expect(moreClips).toContainText('4');
    await moreClips.click();
    await expect(search).toHaveValue('поиск');
    await expect(panel.getByRole('option')).toHaveCount(4);
    // An explicit clipboard opening must reset the forwarded query.
    await shell.evaluate(() => window.platform.call('clipboardHistory.show'));
    await expect(search).toHaveValue('');
    await search.fill('Обсудить макет');
    await search.press('Meta+Enter');
    await expect(panel.locator('.clipboard-preview pre')).toHaveText(longText);
    await panel.keyboard.press('Escape');
    await expect(search).toHaveValue('Обсудить макет');
    await search.fill('');
    await expect(panel.getByRole('option')).toHaveCount(7);
    const shelf = panel.locator('.clipboard-shelf');
    const originalLayout = await shelf.evaluate((el) => ({
      style: el.getAttribute('style')!,
      notched: el.hasAttribute('data-notched'),
    }));
    try {
      // Cover the CI runner's notchless layout even when running on a MacBook.
      for (const topInset of [0, 32]) {
        const geometry = shelfGeometry(
          { x: 0, y: 0, width: 1440, height: 900 },
          { id: 1, x: 620, width: 200, height: topInset },
        );
        await shelf.evaluate((el, geometry) => {
          const element = el as HTMLElement;
          element.style.height = `${geometry.panel.height}px`;
          element.style.setProperty('--notch-inset', `${geometry.topInset}px`);
          element.style.setProperty('--notch-width', `${geometry.target.width}px`);
          element.toggleAttribute('data-notched', geometry.topInset > 0);
        }, geometry);
        const rowHeight = await panel
          .locator('.clipboard-row')
          .first()
          .evaluate((el) => el.getBoundingClientRect().height);
        const availableHeight = await panel
          .locator('.clipboard-results')
          .evaluate((el) => el.clientHeight);
        assert(
          rowHeight <= 64 && Math.floor((availableHeight - 12) / rowHeight) >= 6,
          `Shelf must fit at least six compact entries (inset=${topInset}, row=${rowHeight}, results=${availableHeight})`,
        );
      }
    } finally {
      await shelf.evaluate((el, original) => {
        el.setAttribute('style', original.style);
        el.toggleAttribute('data-notched', original.notched);
      }, originalLayout);
    }
    await search.hover();
    await expect(panel.locator('.mantine-Tooltip-tooltip')).toHaveCount(0);
    await mkdir('artifacts', { recursive: true });
    await panel.screenshot({ path: 'artifacts/clipboard-shelf.png' });
    for (const clip of await clips()) {
      if (!savedIds.includes(clip.id))
        await shell.evaluate(
          (id) => window.platform.call('clipboardHistory.remove', { id }),
          clip.id,
        );
    }
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
    await shell.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', { hoverEnabled: true }),
    );
    await new Promise((resolve) => setTimeout(resolve, 180));
    await app.evaluate(() => {
      (globalThis as any).__qaCursor.y -= 100;
    });
    await expect.poll(visible).toBe(true);
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.isFocused(), panelId),
      )
      .toBe(true);
    await expect(panel.getByRole('combobox', { name: 'Поиск по полке' })).toBeFocused();
    await panel.keyboard.press('Enter');
    await expect(search).toBeFocused();
    await app.evaluate(({ BrowserWindow }, id) => {
      const bounds = BrowserWindow.fromId(id)!.getBounds();
      (globalThis as any).__qaCursor = { x: bounds.x + 100, y: bounds.y + 100 };
    }, panelId);
    await new Promise((resolve) => setTimeout(resolve, 700));
    assert(await visible());
    // Hover opens the app list; Enter opens the first built-in, then keyboard copying works.
    await panel.keyboard.press('ArrowDown');
    await expect(panel.getByRole('option').nth(1)).toHaveAttribute('aria-selected', 'true');
    await panel.keyboard.press('ArrowUp');
    await expect(panel.getByRole('option').first()).toHaveAttribute('aria-selected', 'true');
    await panel.keyboard.press('Enter');
    await expect.poll(visible).toBe(false);
    assert.equal(
      await app.evaluate(({ clipboard }) => clipboard.readText()),
      'Первый пример: план проекта',
    );
    // Leave and re-enter the target to check hover departure after explicit dismissal.
    await app.evaluate(() => {
      (globalThis as any).__qaCursor = { x: 0, y: 500 };
    });
    await new Promise((resolve) => setTimeout(resolve, 180));
    await app.evaluate(({ screen }) => {
      const { bounds } = screen.getPrimaryDisplay();
      (globalThis as any).__qaCursor = {
        x: Math.round(bounds.x + bounds.width / 2),
        y: bounds.y + 1,
      };
    });
    await expect.poll(visible).toBe(true);
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
    await shell.locator('.launcher').waitFor();
    await expect.poll(async () => (await clips()).length).toBe(3);
    const restored = await shell.evaluate(() => window.platform.call('clipboardHistory.state'));
    assert.equal(restored.preferences.paused, true);
    assert.equal(restored.preferences.hoverEnabled, false);
    assert.equal(restored.preferences.retentionDays, 30);
    assert.equal(restored.preferences.accelerator, 'Control+Alt+Shift+F11');
    assert.equal(restored.clips.filter((clip: any) => clip.pinned).length, 1);
    const reopened = Promise.resolve(shell);
    await shell.evaluate(() => window.platform.call('clipboardHistory.show'));
    panel = await reopened;
    await panel.getByRole('button', { name: 'Действия с историей' }).click();
    await panel.getByRole('button', { name: 'Очистить историю на всех связанных Mac…' }).click();
    await panel.getByRole('button', { name: 'Отмена', exact: true }).click();
    await expect(panel.getByRole('option')).toHaveCount(3);
    await panel.getByRole('button', { name: 'Действия с историей' }).click();
    await panel.getByRole('button', { name: 'Очистить историю на всех связанных Mac…' }).click();
    await panel.getByRole('button', { name: 'Удалить на всех связанных Mac', exact: true }).click();
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
                      entry.bytes !== undefined
                        ? new Blob([Buffer.from(entry.bytes, 'base64')])
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
