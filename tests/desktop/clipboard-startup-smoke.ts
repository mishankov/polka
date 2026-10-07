import assert from 'node:assert/strict';
import { expect } from '@playwright/test';
import { writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { ClipboardHistory } from '../../src/main/clipboard-history';
import { SettingsStore } from '../../src/main/settings-store';
import type { ClipboardState } from '../../src/shared/clipboard';
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
  await history.preferences({ hoverEnabled: false });
  await history.add('text', 'Saved before update', 'Saved before update');
  const bootstrap = join(test.profile, 'startup.cjs');
  await writeFile(
    bootstrap,
    `
    const { app, clipboard, safeStorage, screen } = require('electron');
    const { EventEmitter } = require('node:events');
    const { PassThrough, Writable } = require('node:stream');
    const childProcess = require('node:child_process');
    app.getAppPath = () => ${JSON.stringify(process.cwd())};
    // No fixture contents touch the user's clipboard, Keychain or AX permissions.
    safeStorage.isEncryptionAvailable = () => true;
    safeStorage.encryptString = value => Buffer.from(value);
    safeStorage.decryptString = bytes => bytes.toString();
    clipboard.read = async () => [];
    global.__startupWrites = 0;
    clipboard.write = async () => { global.__startupWrites++; };
    global.__startupAttempts = 0;
    const spawn = childProcess.spawn;
    childProcess.spawn = (path, ...args) => {
      if (!path.endsWith('/clipboard-probe')) return spawn(path, ...args);
      global.__startupAttempts++;
      const child = new EventEmitter();
      child.stdout = new PassThrough();
      const emit = value => child.stdout.write(JSON.stringify(value) + '\\n');
      child.stdin = new Writable({ write(chunk, encoding, done) {
        const command = JSON.parse(String(chunk));
        queueMicrotask(() => emit({ type: 'paste.reply', id: command.id, result: { trusted: false } }));
        done();
      } });
      child.kill = signal => {
        child.emit('exit', null, signal || 'SIGTERM');
        child.stdout.end();
        return true;
      };
      global.__releaseStartupProbe = () => emit({ type: 'ready' });
      // Every attempt repeats screen geometry, as the native helper does.
      queueMicrotask(() => emit({ type: 'screens', displays: [
        { id: screen.getPrimaryDisplay().id, x: 0, width: 0, height: 0 }
      ] }));
      return child;
    };
    require(${JSON.stringify(resolve('out/main/index.js'))});
  `,
  );
  const app = await test.launch({ args: [bootstrap] });
  const page = await app.firstWindow();
  // Nothing releases ready until the test says so: automatic opening must be
  // independent of the startup promise, even if the helper never responds.
  await test.shelfReady(app, page, 'Поиск по полке');
  const state = () =>
    page.evaluate(() => window.platform.call<ClipboardState>('clipboardHistory.state'));
  assert.equal((await state()).helper.status, 'starting');
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  await test.shelfReady(app, page, 'Найти в истории');
  const input = page.getByRole('combobox', { name: 'Найти в истории', exact: true });
  const startup = page.locator('.clipboard-helper-status');
  await expect(startup).toContainText('Запускаем наблюдение за буфером обмена…');
  await expect(startup).toContainText('запись только копируется');
  await expect(page.getByRole('option', { name: /Saved before update/ })).toBeEnabled();
  await input.fill('Saved');
  await input.press('Shift+Enter');
  await expect.poll(() => app.evaluate(() => (globalThis as any).__startupWrites)).toBe(1);
  // Copying dismisses the shelf by design; reopen it before observing retries.
  await test.shelfHidden(app, page);
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  await test.shelfReady(app, page, 'Найти в истории');
  await input.fill('Saved');
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).__startupAttempts), { timeout: 15000 })
    .toBe(2);
  await test.shelfReady(app, page, 'Найти в истории');
  await expect(input).toHaveValue('Saved');
  await expect(startup).toBeVisible();
  await expect(page.locator('.clipboard-error')).toHaveCount(0);
  await page.screenshot({ path: join(test.artifacts, 'clipboard-retrying.png'), scale: 'css' });
  const settingsReady = app.waitForEvent('window');
  await page.evaluate(() => window.platform.call('shelf.settings'));
  const settingsPage = await settingsReady;
  await settingsPage.getByRole('tab', { name: 'Буфер обмена', exact: true }).click();
  await expect(settingsPage.locator('.clipboard-helper-status')).toBeVisible();
  await expect(settingsPage.getByText(/не удалось проверить разрешение/)).toHaveCount(0);
  await settingsPage.screenshot({
    path: join(test.artifacts, 'settings-retrying.png'),
    scale: 'css',
    fullPage: true,
  });
  await settingsPage.close();
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  await test.shelfReady(app, page, 'Найти в истории');
  await input.fill('Saved');
  await app.evaluate(() => (globalThis as any).__releaseStartupProbe());
  await expect.poll(async () => (await state()).helper.status).toBe('running');
  await expect(startup).toHaveCount(0);
  await test.shelfReady(app, page, 'Найти в истории');
  await expect(input).toHaveValue('Saved');
  test.assertNoRendererErrors();
  await test.close(app, true);
  console.log(
    'Clipboard startup passed: automatic opening, copy during retries and live recovery.',
  );
}

void runDesktopTest('clipboard-startup', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
