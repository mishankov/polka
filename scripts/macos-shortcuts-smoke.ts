import { expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { readFile, writeFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { join, resolve } from 'node:path';
import { runDesktopTest, type DesktopTest } from './desktop-test';

const id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const imageId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
async function main(test: DesktopTest) {
  const bundle = join(test.profile, 'shortcuts.cjs');
  await build({
    entryPoints: ['src/main/macos-shortcuts.ts'],
    bundle: true,
    platform: 'node',
    format: 'cjs',
    outfile: bundle,
  });
  const settingsBundle = join(test.profile, 'settings.cjs');
  await build({
    entryPoints: ['src/main/settings-store.ts'],
    bundle: true,
    platform: 'node',
    format: 'cjs',
    outfile: settingsBundle,
  });
  const fixtureSource = stripTypeScriptTypes(
    await readFile(resolve('scripts/shelf-search-fixture.ts'), 'utf8'),
  ).replace('export function', 'function');
  const entry = join(test.profile, 'main.cjs');
  await writeFile(
    entry,
    `
    const { app, BrowserWindow, ipcMain } = require('electron');
    const { MacShortcuts } = require(${JSON.stringify(bundle)});
    const { SettingsStore } = require(${JSON.stringify(settingsBundle)});
    app.setPath('userData', ${JSON.stringify(test.profile)});
    ${fixtureSource}
    const fixture = createShelfSearchFixture();
    const store = new SettingsStore(${JSON.stringify(test.profile)});
    let catalog = [
      { id: '${id}', name: 'Подготовить встречу' },
      { id: '${imageId}', name: 'Изменить размер изображений' },
      { id: 'cccccccc-cccc-cccc-cccc-cccccccccccc', name: 'Длинное название команды для подготовки всех материалов к еженедельной встрече команды продукта' },
    ];
    let runs = 0, finish, outcome = 'completed', listError = false;
    const service = new MacShortcuts({
      read: () => store.handle('settings.get', {key: 'macShortcutsSelection'}),
      save: value => store.handle('settings.set', {key: 'macShortcutsSelection', value}),
      list: async () => { if (listError) throw Error('Unavailable'); return catalog; },
      run: async () => { runs++; await new Promise(done => {finish = done}); return {status: outcome, message: outcome === 'failed' ? 'Нет разрешения на доступ к файлам. Проверьте команду в приложении «Команды».' : undefined}; },
      changed: state => BrowserWindow.getAllWindows().forEach(w => w.webContents.send('platform:event', {type: 'macShortcuts.changed', state})),
    });
    global.fixture = fixture;
    global.shortcutTest = {
      get runs() { return runs; },
      finish: status => { outcome = status; finish(); },
      rename: () => { catalog[0] = {...catalog[0], name: 'Подготовить совещание'}; },
      remove: () => { catalog = catalog.filter(s => s.id !== '${imageId}'); },
      failList: enabled => { listError = enabled; },
      saved: () => store.handle('settings.get', {key: 'macShortcutsSelection'}),
    };
    ipcMain.handle('platform:call', (event, method, params = {}) => {
      if (method === 'macShortcuts.state') return service.state(params.refresh, params.discover);
      if (method === 'macShortcuts.select') return service.select(params.id, params.enabled);
      if (method === 'macShortcuts.run') return service.run(params.id);
      return fixture.call(method, params);
    });
    app.whenReady().then(() => {
      const window = new BrowserWindow({ show: false, width: 720, height: 740, webPreferences: {preload: ${JSON.stringify(resolve('out/preload/index.js'))}} });
      fixture.onEvent(event => window.webContents.send('platform:event', event));
      window.loadFile(${JSON.stringify(resolve('out/renderer/index.html'))});
    });
    app.on('will-quit', () => { service.stop(); store.close(); });
  `,
  );
  let app = await test.launch({ args: [entry] });
  let page = await app.firstWindow();
  const input = () => page.getByRole('combobox', { name: 'Поиск по полке', exact: true });
  const rows = () => page.locator('.launcher-result[data-kind="shortcut"]');
  const screenshot = async (name: string) => {
    await page.evaluate(() => Promise.all(document.getAnimations().map((a) => a.finished)));
    await page.screenshot({ path: join(test.artifacts, name), scale: 'css' });
  };
  const runs = () => app.evaluate(() => (globalThis as any).shortcutTest.runs);
  await expect(input()).toBeFocused();
  assert.equal(await runs(), 0);
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  await page.getByRole('tab', { name: 'Команды macOS' }).click();
  await expect(
    page.getByRole('checkbox', { name: 'Подготовить встречу', exact: true }),
  ).toBeVisible();
  await page.getByRole('checkbox', { name: 'Подготовить встречу', exact: true }).check();
  await page.getByRole('checkbox', { name: 'Изменить размер изображений', exact: true }).check();
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).shortcutTest.saved()))
    .toHaveLength(2);
  assert.equal(await runs(), 0);
  await expect(
    page.getByRole('checkbox', { name: 'Подготовить встречу', exact: true }),
  ).toBeEnabled();
  await expect(page.getByText('На полке: 2', { exact: true })).toBeVisible();
  await screenshot('settings.png');
  await page.getByRole('button', { name: 'Открыть полку' }).click();
  await input().fill('встречу');
  await expect(rows()).toHaveCount(1);
  await expect(rows()).toContainText('Команда macOS');
  assert.equal(await runs(), 0);
  await screenshot('search.png');
  await input().press('Enter');
  await expect.poll(runs).toBe(1);
  await input().press('Enter');
  await expect(rows()).toBeDisabled();
  assert.equal(await runs(), 1);
  await screenshot('running.png');
  // Search and other actions remain available while the OS waits for interaction.
  await input().fill('2+2');
  await input().press('Enter');
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).fixture.actions.at(-1)?.method))
    .toBe('shelf.copyCalculation');
  await app.evaluate(() => (globalThis as any).fixture.navigate('apps'));
  await input().fill('встречу');
  await input().press('Enter');
  assert.equal(await runs(), 1);
  await app.evaluate(() => (globalThis as any).shortcutTest.finish('completed'));
  await expect(page.locator('.shortcut-run-status')).toContainText('Выполнено');
  await expect(rows()).toBeEnabled();
  await rows().dispatchEvent('click', { detail: 2 });
  assert.equal(await runs(), 1);
  await rows().click();
  await expect.poll(runs).toBe(2);
  await app.evaluate(() => (globalThis as any).shortcutTest.finish('cancelled'));
  await expect(page.locator('.shortcut-run-status')).toContainText('Отменено');
  await rows().click();
  await expect.poll(runs).toBe(3);
  await app.evaluate(() => (globalThis as any).shortcutTest.finish('failed'));
  await expect(page.locator('.shortcut-run-status')).toContainText('Нет разрешения');
  await screenshot('error.png');
  await app.evaluate(() => {
    (globalThis as any).shortcutTest.rename();
    (globalThis as any).shortcutTest.remove();
  });
  await app.evaluate(() => (globalThis as any).fixture.navigate('apps'));
  await input().fill('совещание');
  await expect(rows()).toContainText('Подготовить совещание');
  await input().fill('изображений');
  await expect(rows()).toContainText('Нет на этом Mac');
  await expect(rows()).toBeDisabled();
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  await page.getByRole('tab', { name: 'Команды macOS' }).click();
  await expect(
    page.getByRole('checkbox', { name: 'Изменить размер изображений', exact: true }),
  ).toBeChecked();
  await screenshot('missing.png');
  await page.getByRole('checkbox', { name: 'Изменить размер изображений', exact: true }).uncheck();
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).shortcutTest.saved()))
    .toHaveLength(1);
  // Failed discovery retains the selected name and offers an explicit retry.
  await app.evaluate(() => (globalThis as any).shortcutTest.failList(true));
  await page.getByRole('button', { name: 'Обновить список', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('Выбранные команды сохранены');
  await expect(
    page.getByRole('checkbox', { name: 'Подготовить совещание', exact: true }),
  ).toBeChecked();
  await app.evaluate(() => (globalThis as any).shortcutTest.failList(false));
  await page.getByRole('button', { name: 'Обновить список', exact: true }).click();
  await expect(page.getByRole('alert')).toHaveCount(0);
  test.assertNoRendererErrors();
  await test.close(app, true);
  app = await test.launch({ args: [entry] });
  page = await app.firstWindow();
  await input().fill('встречу');
  await expect(rows()).toHaveCount(1);
  assert.equal(await runs(), 0);
  // No fixture action touches the user's clipboard or launches their apps.
  test.assertNoRendererErrors();
  console.log(
    'macOS Shortcuts UI: selection, persistence, keyboard/mouse run, duplicate guard, responsive calculation, reopen, completion, cancellation, errors, rename, removal and retry passed.',
  );
}
void runDesktopTest('macos-shortcuts', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
