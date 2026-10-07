import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { SettingsStore } from '../src/main/settings-store';
import { ClipboardHistory } from '../src/main/clipboard-history';
import type { ClipboardState } from '../src/shared/clipboard';

// Fault injection uses a disposable profile and an in-memory clipboard. It does
// not exercise the user's Keychain, pasteboard, or Accessibility settings.
async function main() {
  const root = await mkdtemp(join(tmpdir(), 'polka-storage-smoke-'));
  const profile = join(root, 'profile');
  const historyPath = join(profile, 'clipboard-history', 'history.enc');
  const syncPath = join(profile, 'clipboard-history', 'sync.enc');
  const artifacts = resolve('artifacts/clipboard-storage');
  await mkdir(join(profile, 'clipboard-history'), { recursive: true });
  await mkdir(artifacts, { recursive: true });
  const settings = new SettingsStore(profile);
  await settings.handle('settings.set', { key: 'mediaIndicatorEnabled', value: false });
  settings.close();
  const unreadable = Buffer.from('storage smoke encrypted fixture');
  await writeFile(historyPath, unreadable);
  await writeFile(syncPath, unreadable);
  const bootstrap = join(root, 'bootstrap.cjs');
  await writeFile(
    bootstrap,
    `
    const { app, clipboard, dialog, safeStorage } = require('electron');
    app.getAppPath = () => ${JSON.stringify(process.cwd())};
    global.__storageAlerts = [];
    global.__clipboardWrites = [];
    global.__failStorageWrites = false;
    dialog.showMessageBox = async (options) => { global.__storageAlerts.push(options); return { response: 0 }; };
    clipboard.read = async () => [];
    clipboard.write = async (items) => { global.__clipboardWrites.push(items); };
    safeStorage.isEncryptionAvailable = () => !global.__failStorageWrites;
    safeStorage.encryptString = (value) => Buffer.from(value);
    safeStorage.decryptString = (value) => {
      if (value.toString() === 'storage smoke encrypted fixture') {
        const reason = new Error('Injected storage smoke decrypt failure');
        reason.code = 'E_DECRYPT_FIXTURE';
        throw reason;
      }
      return value.toString();
    };
    require(${JSON.stringify(resolve('out/main/index.js'))});
  `,
  );
  const launch = () =>
    electron.launch({ args: [bootstrap], env: { ...process.env, EVERYTHING_PROFILE: profile } });
  let app: Awaited<ReturnType<typeof launch>> | undefined;
  try {
    app = await launch();
    let page = await app.firstWindow();
    const errors: string[] = [];
    page.on('pageerror', (error) => errors.push(error.message));
    const state = () =>
      page.evaluate(() => window.platform.call<ClipboardState>('clipboardHistory.state'));
    await expect.poll(async () => (await state()).helper.status).toBe('running');
    const failed = await state();
    assert.equal(failed.storage.diagnostic?.stage, 'decrypt');
    assert.equal(failed.storage.diagnostic?.code, 'E_DECRYPT_FIXTURE');
    assert.equal(failed.preferencesAvailable, false);
    assert.equal(failed.sync?.status, 'blocked');
    assert.equal(failed.preferences.pasteOnSelect, false);
    assert.equal(await app.evaluate(() => (globalThis as any).__storageAlerts.length), 1);
    await page.evaluate(() => window.platform.call('clipboardHistory.show'));
    await expect(page.getByRole('heading', { name: 'Буфер обмена', exact: true })).toBeVisible();
    await expect(page.getByText('История буфера недоступна', { exact: true })).toBeVisible();
    await expect(page.getByText('Здесь появится скопированное', { exact: true })).toHaveCount(0);
    await page.getByText('Подробности ошибки', { exact: true }).click();
    await expect(page.getByText(historyPath, { exact: true })).toBeVisible();
    await page.screenshot({ path: join(artifacts, 'history-unavailable.png') });
    await page.evaluate(() => window.platform.call('shelf.showEmoji'));
    await expect(page.getByRole('heading', { name: 'Эмодзи', exact: true })).toBeVisible();
    await page.evaluate(() => window.platform.call('shelf.selectEmoji', { id: '1f600' }));
    assert.equal(await app.evaluate(() => (globalThis as any).__clipboardWrites.length), 1);
    const settingsReady = app.waitForEvent('window');
    await page.evaluate(() => window.platform.call('shelf.settings'));
    const settingsPage = await settingsReady;
    settingsPage.on('pageerror', (error) => errors.push(error.message));
    await settingsPage.getByRole('tab', { name: 'Буфер обмена', exact: true }).click();
    await expect(
      settingsPage.getByRole('switch', {
        name: 'Сохранять скопированный текст и изображения',
        exact: true,
      }),
    ).toBeDisabled();
    await expect(
      settingsPage.getByRole('switch', {
        name: 'Вставлять выбранную запись в предыдущее поле',
        exact: true,
      }),
    ).toBeDisabled();
    await expect(
      settingsPage.getByText('Синхронизация остановлена: хранилище истории недоступно.', {
        exact: true,
      }),
    ).toBeVisible();
    await settingsPage.screenshot({
      path: join(artifacts, 'settings-unavailable.png'),
      fullPage: true,
    });
    await settingsPage.getByRole('tab', { name: 'Полка и сочетания', exact: true }).click();
    await expect(
      settingsPage.getByRole('switch', {
        name: 'Открывать полку при наведении к вырезу камеры',
        exact: true,
      }),
    ).toBeDisabled();
    await expect(
      settingsPage.getByRole('textbox', { name: 'Сочетание для запуска', exact: true }),
    ).toBeEnabled();
    await settingsPage.screenshot({ path: join(artifacts, 'launcher-settings-unavailable.png') });
    assert.equal(errors.length, 0);
    await app.close();
    app = undefined;
    assert.deepEqual(await readFile(historyPath), unreadable);
    assert.deepEqual(await readFile(syncPath), unreadable);
    assert.deepEqual((await readdir(join(profile, 'clipboard-history'))).sort(), [
      'history.enc',
      'sync.enc',
    ]);

    // Simulate restored access with a valid test file. Production has no reset.
    await rm(historyPath);
    const restored = new ClipboardHistory(
      historyPath,
      {
        encode: (text) => Buffer.from(text),
        decode: (bytes) => bytes.toString(),
      },
      () => {},
    );
    await restored.initialize();
    await restored.preferences({ hoverEnabled: false, pasteOnSelect: false });
    await restored.add('text', 'Saved before restart', 'Saved before restart');
    await writeFile(syncPath, JSON.stringify({ enabled: false, key: '', cert: '', peers: [] }));
    app = await launch();
    page = await app.firstWindow();
    page.on('pageerror', (error) => errors.push(error.message));
    await expect.poll(async () => (await state()).storage.status).toBe('ready');
    const healthy = await state();
    assert.equal(healthy.preferencesAvailable, true);
    assert.equal(healthy.registered, true);
    assert.equal(healthy.sync?.status, 'disabled');
    assert.equal(healthy.preferences.pasteOnSelect, false);
    assert.equal(await app.evaluate(() => (globalThis as any).__storageAlerts.length), 0);
    await page.evaluate(() => window.platform.call('clipboardHistory.show'));
    await expect(page.getByRole('option', { name: /Saved before restart/ })).toBeVisible();

    await app.evaluate(() => {
      (globalThis as any).__failStorageWrites = true;
    });
    await page.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', { retentionDays: 1 }).catch(() => {}),
    );
    await expect(page.getByText('История буфера недоступна', { exact: true })).toBeVisible();
    await expect(
      page.getByRole('button', { name: 'Закрепить запись', exact: true }),
    ).toBeDisabled();
    await expect(page.getByRole('button', { name: 'Удалить запись', exact: true })).toBeDisabled();
    await expect(page.getByRole('option', { name: /Saved before restart/ })).toBeEnabled();
    await page.screenshot({ path: join(artifacts, 'history-read-only.png') });
    await page.evaluate(async () => {
      const state = await window.platform.call<ClipboardState>('clipboardHistory.state');
      await window.platform.call('clipboardHistory.copy', { id: state.clips[0].id });
    });
    assert.equal(await app.evaluate(() => (globalThis as any).__clipboardWrites.length), 1);
    assert.equal(errors.length, 0);
    console.log(
      'Clipboard storage smoke passed: independent native startup, failure UI, file preservation, restart recovery, and read-only copying.',
    );
  } finally {
    await app?.close();
    await rm(root, { recursive: true, force: true });
  }
}
main().catch((reason) => {
  console.error(reason);
  process.exitCode = 1;
});
