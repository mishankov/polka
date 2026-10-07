import assert from 'node:assert/strict';
import { expect } from '@playwright/test';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { ClipboardHistory } from '../src/main/clipboard-history';
import { shelfGeometry } from '../src/main/clipboard-hover';
import { SettingsStore } from '../src/main/settings-store';
import type { ClipboardState } from '../src/shared/clipboard';
import { runDesktopTest, type DesktopTest } from './desktop-test';

async function main(test: DesktopTest) {
  await mkdir(test.artifacts, { recursive: true });
  const settings = new SettingsStore(test.profile);
  await settings.handle('settings.set', { key: 'shelfIntroduced', value: true });
  await settings.handle('settings.set', { key: 'mediaIndicatorEnabled', value: false });
  settings.close();
  const history = new ClipboardHistory(
    join(test.profile, 'clipboard-history/history.enc'),
    {
      encode: (text) => Buffer.from(text),
      decode: (bytes) => bytes.toString(),
    },
    () => {},
  );
  await history.initialize();
  await history.preferences({ hoverEnabled: false, pasteOnSelect: false, accelerator: '' });
  await history.add('text', 'Synthetic private note', 'Synthetic private note');
  const id = history.snapshot().clips[0].id;
  const fakeApp = join(test.profile, 'Private Editor.app');
  await mkdir(join(fakeApp, 'Contents'), { recursive: true });
  await writeFile(
    join(fakeApp, 'Contents/Info.plist'),
    `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.private</string><key>CFBundleName</key><string>Private Editor</string></dict></plist>`,
  );
  const bootstrap = join(test.profile, 'privacy.cjs');
  await writeFile(
    bootstrap,
    `
    const { app, clipboard, safeStorage, screen, dialog, globalShortcut } = require('electron');
    const { EventEmitter } = require('node:events');
    const { PassThrough, Writable } = require('node:stream');
    const childProcess = require('node:child_process');
    const realNow = Date.now;
    global.__privacyNow = undefined;
    Date.now = () => global.__privacyNow ?? realNow();
    app.getAppPath = () => ${JSON.stringify(process.cwd())};
    safeStorage.isEncryptionAvailable = () => true;
    safeStorage.encryptString = value => Buffer.from(value);
    safeStorage.decryptString = bytes => bytes.toString();
    globalShortcut.register = () => true;
    globalShortcut.unregister = () => {};
    global.__privacyWrites = 0;
    global.__privacyReads = 0;
    global.__privacyCount = 0;
    global.__privacyText = '';
    clipboard.read = async () => {
      global.__privacyReads++;
      return [ { types: ['text/plain'], getType: async () => new Blob([global.__privacyText]) } ];
    };
    clipboard.write = async () => { global.__privacyWrites++; };
    dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [${JSON.stringify(fakeApp)}] });
    const spawn = childProcess.spawn;
    childProcess.spawn = (path, ...args) => {
      if (!path.endsWith('/clipboard-probe')) return spawn(path, ...args);
      const child = new EventEmitter();
      child.stdout = new PassThrough();
      const emit = value => child.stdout.write(JSON.stringify(value) + '\\n');
      child.stdin = new Writable({ write(chunk, encoding, done) {
        const command = JSON.parse(String(chunk));
        queueMicrotask(() => emit({ type: 'paste.reply', id: command.id, result: { trusted: false, unchanged: String(global.__privacyCount) === command.count } }));
        done();
      } });
      child.kill = signal => { child.emit('exit', null, signal || 'SIGTERM'); child.stdout.end(); return true; };
      global.__privacyCopy = (text, sourceBundleId) => {
        global.__privacyText = text; global.__privacyCount++;
        emit({ type: 'clipboard', count: global.__privacyCount, sourceBundleId });
      };
      queueMicrotask(() => {
        emit({ type: 'screens', displays: [{ id: screen.getPrimaryDisplay().id, x: 0, width: 0, height: 0 }] });
        emit({ type: 'ready' });
      });
      return child;
    };
    require(${JSON.stringify(resolve('out/main/index.js'))});
  `,
  );
  let app = await test.launch({ args: [bootstrap] });
  let page = await app.firstWindow();
  const state = () =>
    page.evaluate(() => window.platform.call<ClipboardState>('clipboardHistory.state'));
  await expect.poll(async () => (await state()).helper.status).toBe('running');
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  await test.shelfReady(app, page, 'Найти в истории');
  const shelf = page.locator('.clipboard-shelf');
  const originalLayout = await shelf.evaluate((el) => ({
    style: el.getAttribute('style')!,
    notched: el.hasAttribute('data-notched'),
  }));
  try {
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
      const rowHeight = await page
        .locator('.clipboard-row')
        .first()
        .evaluate((el) => el.getBoundingClientRect().height);
      const availableHeight = await page
        .locator('.clipboard-results')
        .evaluate((el) => el.clientHeight);
      assert(
        rowHeight <= 64 && Math.floor((availableHeight - 12) / rowHeight) >= 6,
        `Shelf must fit six entries (inset=${topInset}, row=${rowHeight}, results=${availableHeight})`,
      );
    }
  } finally {
    await shelf.evaluate((el, original) => {
      el.setAttribute('style', original.style);
      el.toggleAttribute('data-notched', original.notched);
    }, originalLayout);
  }
  await page.getByRole('button', { name: 'Действия с историей', exact: true }).click();
  await page.getByRole('button', { name: 'Пауза на 15 минут', exact: true }).click();
  const until = (await state()).preferences.pauseUntil!;
  assert(until > Date.now() + 14 * 60000 && until <= Date.now() + 15 * 60000);
  await expect(page.locator('.clipboard-heading')).toContainText('Запись на паузе до');
  await page.screenshot({ path: join(test.artifacts, 'privacy-paused-history.png'), scale: 'css' });
  await app.evaluate(() =>
    (globalThis as any).__privacyCopy('Paused secret', 'com.example.allowed'),
  );
  await expect.poll(() => app.evaluate(() => (globalThis as any).__privacyReads)).toBe(0);
  await test.close(app, true);
  app = await test.launch({ args: [bootstrap] });
  page = await app.firstWindow();
  await expect.poll(async () => (await state()).helper.status).toBe('running');
  assert.equal((await state()).preferences.pauseUntil, until);
  const settingsReady = app.waitForEvent('window');
  await page.evaluate(() => window.platform.call('shelf.settings', { section: 'clipboard' }));
  const settingsPage = await settingsReady;
  await expect(
    settingsPage.getByRole('tab', { name: 'Буфер обмена', exact: true }),
  ).toHaveAttribute('aria-selected', 'true');
  await settingsPage.getByRole('button', { name: 'Исключить приложение…', exact: true }).click();
  await expect(
    settingsPage.getByRole('button', { name: 'Разрешить копии из Private Editor' }),
  ).toBeVisible();
  await settingsPage.screenshot({
    path: join(test.artifacts, 'privacy-settings.png'),
    fullPage: true,
    scale: 'css',
  });
  await settingsPage.getByRole('button', { name: 'Возобновить запись', exact: true }).click();
  await expect.poll(async () => (await state()).preferences.paused).toBe(false);
  await app.evaluate(() =>
    (globalThis as any).__privacyCopy('Excluded secret', 'com.example.private'),
  );
  await app.evaluate(() => (globalThis as any).__privacyCopy('Unknown secret', undefined));
  // A round-trip state call waits for these change signals to be handled.
  assert.equal((await state()).clips.length, 1);
  assert.equal(await app.evaluate(() => (globalThis as any).__privacyReads), 0);
  await app.evaluate(() =>
    (globalThis as any).__privacyCopy('Allowed synthetic copy', 'com.example.allowed'),
  );
  await expect.poll(async () => (await state()).clips.length).toBe(2);
  await settingsPage.getByRole('button', { name: 'Пауза до возобновления', exact: true }).click();
  assert.equal((await state()).preferences.pauseUntil, undefined);
  await settingsPage.getByRole('button', { name: 'Возобновить запись', exact: true }).click();
  await settingsPage.close();
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  await test.shelfReady(app, page, 'Найти в истории');
  const exclusionSettings = app.waitForEvent('window');
  await page.getByRole('button', { name: /Исключено приложений: 1/ }).click();
  const exclusionPage = await exclusionSettings;
  await expect(
    exclusionPage.getByRole('tab', { name: 'Буфер обмена', exact: true }),
  ).toHaveAttribute('aria-selected', 'true');
  await exclusionPage.close();
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  await test.shelfReady(app, page, 'Найти в истории');
  const input = page.getByRole('combobox', { name: 'Найти в истории', exact: true });
  await input.fill('Synthetic private note');
  await input.press('Meta+Enter');
  await page.getByRole('button', { name: 'Оставить на этом Mac…', exact: true }).click();
  await expect(page.getByRole('dialog')).toContainText(
    'Уже полученные копии останутся на других Mac',
  );
  await page.screenshot({
    path: join(test.artifacts, 'local-only-confirmation.png'),
    scale: 'css',
  });
  await page.getByRole('button', { name: 'Отмена', exact: true }).click();
  assert.equal((await state()).clips.find((clip) => clip.id === id)?.localOnly, undefined);
  await page.getByRole('button', { name: 'Оставить на этом Mac…', exact: true }).click();
  await page.getByRole('button', { name: 'Оставить на этом Mac', exact: true }).click();
  await expect
    .poll(async () => (await state()).clips.find((clip) => clip.id === id)?.localOnly)
    .toBe(true);
  await expect(page.getByRole('dialog')).not.toBeVisible();
  await page.getByRole('button', { name: 'Назад к списку', exact: true }).click();
  await expect(page.getByText('Только этот Mac ·', { exact: true })).toBeVisible();
  await page.screenshot({ path: join(test.artifacts, 'local-only-history.png'), scale: 'css' });
  assert.equal(await app.evaluate(() => (globalThis as any).__privacyWrites), 0);
  await test.close(app, true);
  app = await test.launch({ args: [bootstrap] });
  page = await app.firstWindow();
  await expect.poll(async () => (await state()).helper.status).toBe('running');
  assert.equal((await state()).clips.find((clip) => clip.id === id)?.localOnly, true);
  assert.equal((await state()).preferences.excludedApps[0].bundleId, 'com.example.private');
  await page.evaluate(() => window.platform.call('clipboardHistory.pause15'));
  const deadline = (await state()).preferences.pauseUntil!;
  await app.evaluate((_electron, deadline) => {
    (globalThis as any).__privacyNow = deadline + 1;
  }, deadline);
  await expect.poll(async () => (await state()).preferences.pauseUntil).toBe(undefined);
  assert.equal((await state()).preferences.paused, false);
  const settingsAgain = app.waitForEvent('window');
  await page.evaluate(() => window.platform.call('shelf.settings'));
  const finalSettings = await settingsAgain;
  await finalSettings.getByRole('tab', { name: 'Буфер обмена', exact: true }).click();
  await finalSettings.getByRole('button', { name: 'Разрешить копии из Private Editor' }).click();
  await expect.poll(async () => (await state()).preferences.excludedApps.length).toBe(0);
  await app.evaluate(() =>
    (globalThis as any).__privacyCopy('Unknown allowed after removing exclusion', undefined),
  );
  await expect
    .poll(async () =>
      (await state()).clips.some(
        (clip) => clip.content === 'Unknown allowed after removing exclusion',
      ),
    )
    .toBe(true);
  await finalSettings.close();
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  await test.shelfReady(app, page, 'Найти в истории');
  const finalInput = page.getByRole('combobox', { name: 'Найти в истории', exact: true });
  await finalInput.fill('Synthetic private note');
  await finalInput.press('Meta+Enter');
  await page.getByRole('button', { name: 'Разрешить синхронизацию…', exact: true }).click();
  await page.getByRole('button', { name: 'Разрешить синхронизацию', exact: true }).click();
  await expect
    .poll(async () => (await state()).clips.find((clip) => clip.id === id)?.localOnly)
    .toBe(undefined);
  assert.equal(await app.evaluate(() => (globalThis as any).__privacyWrites), 0);
  test.assertNoRendererErrors();
  await test.close(app, true);
  console.log(
    'Privacy passed: pause/restart/deadline, exclusions, local-only confirmation/persistence; zero clipboard writes.',
  );
}
void runDesktopTest('clipboard-privacy', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
