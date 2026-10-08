import assert from 'node:assert/strict';
import { expect } from '@playwright/test';
import { writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { SettingsStore } from '../../src/main/settings-store';
import { runDesktopTest, type DesktopTest } from './desktop-test';

async function main(test: DesktopTest) {
  const settings = new SettingsStore(test.profile);
  await settings.handle('settings.set', { key: 'shelfIntroduced', value: true });
  await settings.handle('settings.set', { key: 'mediaIndicatorEnabled', value: false });
  settings.close();
  const bootstrap = join(test.profile, 'cold-startup.cjs');
  await writeFile(
    bootstrap,
    `
    const { app, BrowserWindow, clipboard, globalShortcut, ipcMain, safeStorage, screen } = require('electron');
    const { EventEmitter } = require('node:events');
    const { PassThrough, Writable } = require('node:stream');
    const childProcess = require('node:child_process');
    app.getAppPath = () => ${JSON.stringify(resolve('.'))};
    safeStorage.isEncryptionAvailable = () => true;
    safeStorage.encryptString = value => Buffer.from(value);
    safeStorage.decryptString = bytes => bytes.toString();
    clipboard.read = async () => [];
    global.__copies = 0;
    clipboard.write = async () => { global.__copies++; };
    globalShortcut.register = () => true;
    globalShortcut.unregister = () => {};
    global.__shows = 0;
    global.__focuses = 0;
    app.on('browser-window-created', (_, window) => {
      // Keep this fixture hidden: no desktop focus or other app is affected.
      window.show = () => { global.__shows++; };
      window.focus = () => { global.__focuses++; };
    });
    const handle = ipcMain.handle.bind(ipcMain);
    let acknowledgement;
    ipcMain.handle = (channel, handler) => handle(channel, async (event, method, ...params) => {
      if (channel === 'platform:call' && method === 'shelf.didShow') {
        acknowledgement ||= new Promise(resolve => {
          const start = Date.now();
          setTimeout(() => { global.__ackDelay = Date.now() - start; resolve(); }, 2500);
        });
        await acknowledgement;
      }
      return handler(event, method, ...params);
    });
    const spawn = childProcess.spawn;
    childProcess.spawn = (path, ...args) => {
      if (!path.endsWith('/clipboard-probe') && !path.endsWith('/file-shelf-probe')) return spawn(path, ...args);
      const child = new EventEmitter();
      child.stdout = new PassThrough();
      child.stderr = new PassThrough();
      const emit = value => child.stdout.write(JSON.stringify(value) + '\\n');
      child.stdin = new Writable({ write(chunk, encoding, done) {
        if (path.endsWith('/clipboard-probe')) {
          const command = JSON.parse(String(chunk));
          queueMicrotask(() => emit({ type: 'paste.reply', id: command.id, result: { trusted: false } }));
        }
        done();
      } });
      child.kill = signal => { child.emit('exit', 0, signal); child.stdout.end(); return true; };
      if (path.endsWith('/clipboard-probe')) queueMicrotask(() => {
        emit({ type: 'screens', displays: [{ id: screen.getPrimaryDisplay().id, x: 0, width: 0, height: 0 }] });
        emit({ type: 'ready' });
      });
      return child;
    };
    require(${JSON.stringify(resolve('out/main/index.js'))});
  `,
  );
  const app = await test.launch({ args: [bootstrap] });
  const page = await app.firstWindow();
  await expect.poll(() => app.evaluate(() => (globalThis as any).__shows)).toBe(1);
  assert.ok((await app.evaluate(() => (globalThis as any).__ackDelay)) >= 2500);
  assert.equal(await app.evaluate(() => (globalThis as any).__focuses), 1);
  assert.equal(app.process().exitCode, null);
  const search = page.getByRole('combobox', { name: 'Поиск по полке', exact: true });
  await search.fill('2 + 2');
  await expect(page.getByRole('option').first()).toContainText('4');
  await search.press('Enter');
  await expect.poll(() => app.evaluate(() => (globalThis as any).__copies)).toBe(1);
  await page.screenshot({ path: join(test.artifacts, 'cold-startup.png') });
  await test.close(app, true);
  console.log(
    'Cold shelf startup passed: delayed renderer acknowledgement, live app and keyboard calculation; clipboard, encryption, shortcuts, native helpers and desktop focus remain isolated.',
  );
}

void runDesktopTest('shelf-startup', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
