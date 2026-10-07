import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { expect } from '@playwright/test';
import { readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { SettingsStore } from '../src/main/settings-store';
import { runDesktopTest, type DesktopTest } from './desktop-test';

const id = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA';
async function main(test: DesktopTest) {
  const store = new SettingsStore(test.profile);
  await store.handle('settings.set', { key: 'shelfIntroduced', value: true });
  await store.handle('settings.set', { key: 'mediaIndicatorEnabled', value: false });
  store.close();
  const marker = join(test.profile, 'runs.jsonl');
  const finish = join(test.profile, 'finish');
  const command = join(test.profile, 'shortcuts-cli.cjs');
  // Exercise the production IPC/service/spawn boundary with a disposable command
  // process. No installed personal shortcut, clipboard, Keychain or AX access.
  await writeFile(
    command,
    `
    const fs = require('node:fs');
    const [action, argument] = process.argv.slice(2);
    if (action === 'list') {
      process.stdout.write('Безопасная тестовая команда (${id})\\n');
    } else if (action === 'run') {
      fs.appendFileSync(${JSON.stringify(marker)}, JSON.stringify({action, argument}) + '\\n');
      if (argument !== '${id}') { console.error('Identifier was changed before execution'); process.exit(1); }
      const timer = setInterval(() => {
        if (!fs.existsSync(${JSON.stringify(finish)})) return;
        clearInterval(timer);
        const result = fs.readFileSync(${JSON.stringify(finish)}, 'utf8');
        fs.unlinkSync(${JSON.stringify(finish)});
        if (result === 'failed') { console.error('Synthetic permission error'); process.exit(1); }
        if (result === 'cancelled') { console.error('The user cancelled.'); process.exit(1); }
        process.exit(0);
      }, 25);
    } else process.exit(2);
  `,
  );
  const bootstrap = join(test.profile, 'main.cjs');
  await writeFile(
    bootstrap,
    `
    const {app, clipboard, safeStorage, screen, globalShortcut} = require('electron');
    const {EventEmitter} = require('node:events');
    const {PassThrough, Writable} = require('node:stream');
    const cp = require('node:child_process');
    const {promisify} = require('node:util');
    app.getAppPath = () => ${JSON.stringify(process.cwd())};
    safeStorage.isEncryptionAvailable = () => true;
    safeStorage.encryptString = value => Buffer.from(value);
    safeStorage.decryptString = bytes => bytes.toString();
    clipboard.read = async () => [];
    clipboard.write = async () => { throw Error('Unexpected clipboard write'); };
    // Avoid registering the production global accelerator on the shared desktop.
    globalShortcut.register = () => true;
    globalShortcut.unregister = () => {};
    globalShortcut.unregisterAll = () => {};
    const spawn = cp.spawn, execFile = cp.execFile;
    const redirect = (path, args, options) => path === '/usr/bin/shortcuts'
      ? [process.execPath, [${JSON.stringify(command)}, ...args], {...options, env: {...process.env, ELECTRON_RUN_AS_NODE: '1'}}]
      : [path, args, options];
    cp.execFile = (path, args, options, callback) => execFile(...redirect(path, args, options), callback);
    cp.execFile[promisify.custom] = (path, args, options) => promisify(execFile)(...redirect(path, args, options));
    cp.spawn = (path, args, options) => {
      if (!path.endsWith('/clipboard-probe')) {
        if (path === '/usr/bin/shortcuts' && global.__nativeShortcutRun) return spawn(path, args, options);
        return spawn(...redirect(path, args, options));
      }
      const child = new EventEmitter();
      child.stdout = new PassThrough();
      child.stdin = new Writable({write(chunk, encoding, done) { done(); }});
      child.kill = signal => { child.emit('exit', null, signal || 'SIGTERM'); child.stdout.end(); return true; };
      queueMicrotask(() => {
        child.stdout.write(JSON.stringify({type: 'screens', displays: [{id: screen.getPrimaryDisplay().id, x:0, width:0, height:0}]}) + '\\n');
        child.stdout.write(JSON.stringify({type: 'ready'}) + '\\n');
      });
      return child;
    };
    require(${JSON.stringify(resolve('out/main/index.js'))});
  `,
  );
  const app = await test.launch({ args: [bootstrap] });
  const page = await app.firstWindow();
  await test.shelfReady(app, page, 'Поиск по полке');
  const input = page.getByRole('combobox', { name: 'Поиск по полке', exact: true });
  const row = page.locator('.launcher-result[data-kind="shortcut"]');
  const status = page.locator('.shortcut-run-status');
  const runs = async () =>
    (await readFile(marker, 'utf8').catch(() => ''))
      .trim()
      .split('\n')
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  await input.fill('Безопасная тестовая');
  await expect(row).toHaveCount(1);
  await input.press('Enter');
  await expect.poll(runs).toHaveLength(1);
  assert.equal((await runs())[0].argument, id, 'Pass the installed native identifier unchanged');
  await expect(status).toContainText('Выполняется…');
  await expect(status).toBeInViewport();
  await input.press('Enter');
  await expect(row).toBeDisabled();
  assert.equal((await runs()).length, 1);
  await writeFile(finish, 'completed');
  await expect(status).toContainText('Выполнено');
  await expect(row).toBeEnabled();
  await row.click();
  await expect.poll(runs).toHaveLength(2);
  await writeFile(finish, 'failed');
  await expect(status).toContainText('Synthetic permission error');
  await expect(status).toBeInViewport();
  await page.screenshot({ path: join(test.artifacts, 'process-error.png'), scale: 'css' });
  await input.focus();
  await input.press('Meta+1');
  await expect.poll(runs).toHaveLength(3);
  await writeFile(finish, 'cancelled');
  await expect(status).toContainText('Отменено');
  if (process.argv.includes('--native')) {
    // Exercise the actual macOS executable only with a confirmed absent UUID.
    // A real command failure must reach the visible status through production IPC.
    const installed = await promisify(execFile)('/usr/bin/shortcuts', [
      'list',
      '--show-identifiers',
    ]);
    assert(
      !installed.stdout.toLowerCase().includes(id.toLowerCase()),
      'Native failure fixture must not identify an installed personal shortcut',
    );
    await app.evaluate(() => {
      (globalThis as any).__nativeShortcutRun = true;
    });
    await row.click();
    await expect(status).toContainText('Не удалось выполнить');
    await expect(status.locator('span')).not.toBeEmpty();
    await expect(status).toBeInViewport();
    assert.equal(
      (await runs()).length,
      3,
      'Native failure uses the real command, not the fixture process',
    );
    await page.screenshot({ path: join(test.artifacts, 'native-unavailable.png'), scale: 'css' });
  }
  test.assertNoRendererErrors();
  await test.close(app, true);
  console.log(
    'Production shortcut IPC and CLI process: keyboard/mouse activation, exact native identifier, responsive running status, duplicate guard, completion, error and cancellation passed.',
  );
}
void runDesktopTest('macos-shortcuts-integration', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
