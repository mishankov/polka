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
    store.handle('settings.set', {key: 'macShortcutsSelection', value: [{id: '${id}', name: 'Old choice'}]});
    let catalog = [
      { id: '${id}', name: 'Подготовить встречу' },
      { id: '${imageId}', name: 'Изменить размер изображений' },
      { id: 'cccccccc-cccc-cccc-cccc-cccccccccccc', name: 'Длинное название команды для проверки формата всех материалов большого проекта перед публикацией и отправкой заказчику' },
    ];
    let runs = 0, finish, outcome = 'completed', listError = false;
    const service = new MacShortcuts({
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
      add: () => { catalog.push({id: 'dddddddd-dddd-dddd-dddd-dddddddddddd', name: 'Подготовить отчёт'}); },
      many: () => { catalog = Array.from({length: 40}, (_, i) => ({id: i.toString(16).padStart(8, '0') + '-aaaa-aaaa-aaaa-aaaaaaaaaaaa', name: 'Тестовая команда ' + String(i).padStart(2, '0')})); },
      empty: () => { catalog = []; },
      failList: enabled => { listError = enabled; },
      saved: () => store.handle('settings.get', {key: 'macShortcutsSelection'}),
    };
    ipcMain.handle('platform:call', (event, method, params = {}) => {
      if (method === 'macShortcuts.state') return service.state(params.refresh);
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
  const input = () => page.getByRole('combobox', { name: /^(Поиск по полке|Найти команду)$/ });
  const rows = () => page.locator('.launcher-result[data-kind="shortcut"]');
  const folder = () => page.locator('.launcher-result[data-kind="shortcut-folder"]');
  const screenshot = async (name: string) => {
    await page.evaluate(() => Promise.all(document.getAnimations().map((a) => a.finished)));
    await page.screenshot({ path: join(test.artifacts, name), scale: 'css' });
  };
  const runs = () => app.evaluate(() => (globalThis as any).shortcutTest.runs);
  await expect(input()).toBeFocused();
  assert.equal(await runs(), 0);
  await expect(rows()).toHaveCount(0);
  await expect(folder()).toHaveCount(1);
  await expect(folder()).toHaveAttribute('aria-keyshortcuts', 'Enter');
  assert.equal(
    await page.locator('.launcher-result').last().getAttribute('data-kind'),
    'shortcut-folder',
    'The folder follows every app and individual shortcuts stay out of the default list',
  );
  await folder().scrollIntoViewIfNeeded();
  await screenshot('catalog.png');
  const parentScroll = await page
    .locator('.launcher-scroll')
    .evaluate((element) => element.scrollTop);
  await folder().click();
  await expect(rows()).toHaveCount(3);
  await page.getByRole('button', { name: 'Назад к приложениям', exact: true }).click();
  await expect(input()).toHaveValue('');
  await expect(input()).toBeFocused();
  await expect(folder()).toHaveAttribute('aria-selected', 'true');
  await expect
    .poll(() => page.locator('.launcher-scroll').evaluate((element) => element.scrollTop))
    .toBe(parentScroll);
  // Legacy opt-in settings cannot hide installed shortcuts or require setup.
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).shortcutTest.saved()))
    .toHaveLength(1);
  await page.getByRole('button', { name: 'Настройки', exact: true }).click();
  await expect(page.getByRole('tab', { name: 'Команды macOS' })).toHaveCount(0);
  await page.getByRole('button', { name: 'Открыть полку' }).click();
  await input().fill('shortcuts');
  await expect(folder()).toHaveCount(1);
  await expect(rows()).toHaveCount(0);
  await expect(folder()).toHaveAttribute('aria-keyshortcuts', 'Enter Meta+1');
  await screenshot('folder-search.png');
  for (const options of [{ repeat: true }, { isComposing: true }])
    await input().dispatchEvent('keydown', { key: 'Enter', code: 'Enter', ...options });
  await expect(page.getByRole('heading', { name: 'Команды macOS', exact: true })).toHaveCount(0);
  await input().press('Enter');
  await expect(page.getByRole('heading', { name: 'Команды macOS', exact: true })).toBeVisible();
  await expect(rows()).toHaveCount(3);
  assert.equal(await runs(), 0, 'Opening the folder never executes a command');
  for (const options of [{ repeat: true }, { isComposing: true }])
    await input().dispatchEvent('keydown', {
      key: 'х',
      code: 'BracketLeft',
      metaKey: true,
      ...options,
    });
  await expect(page.getByRole('heading', { name: 'Команды macOS', exact: true })).toBeVisible();
  await screenshot('folder.png');
  await input().fill('встречу');
  await expect(rows()).toHaveCount(1);
  const back = page.getByRole('button', { name: 'Назад к приложениям', exact: true });
  await expect(back).toHaveAttribute('aria-keyshortcuts', 'Meta+[');
  await back.click();
  await expect(input()).toHaveValue('shortcuts');
  await expect(input()).toBeFocused();
  await input().dispatchEvent('keydown', { key: '!', code: 'Digit1', metaKey: true });
  await expect(rows()).toHaveCount(3);
  await input().dispatchEvent('keydown', { key: 'х', code: 'BracketLeft', metaKey: true });
  await expect(input()).toHaveValue('shortcuts');
  await folder().click();
  await input().fill('встречу');
  await expect(rows()).toHaveCount(1);
  await expect(rows()).toContainText('Команда macOS');
  assert.equal(await runs(), 0);
  await screenshot('search.png');
  await expect(rows()).toHaveAttribute('aria-keyshortcuts', 'Enter Meta+1');
  for (const options of [{ repeat: true }, { isComposing: true }])
    await input().dispatchEvent('keydown', { key: 'Enter', code: 'Enter', ...options });
  await page.evaluate(() => {
    const dialog = document.createElement('div');
    dialog.setAttribute('role', 'dialog');
    dialog.id = 'keyboard-dialog';
    document.body.append(dialog);
  });
  await input().press('Enter');
  assert.equal(await runs(), 0, 'Composition, held keys and dialogs cannot execute commands');
  await page.locator('#keyboard-dialog').evaluate((element) => element.remove());
  await input().press('Enter');
  await expect.poll(runs).toBe(1);
  await input().press('Enter');
  await expect(rows()).toBeDisabled();
  assert.equal(await runs(), 1);
  await screenshot('running.png');
  // Search and other actions remain available while the OS waits for interaction.
  await input().press('Meta+BracketLeft');
  await expect(input()).toHaveValue('shortcuts');
  await input().fill('2+2');
  await input().press('Enter');
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).fixture.actions.at(-1)?.method))
    .toBe('shelf.copyCalculation');
  await app.evaluate(() => (globalThis as any).fixture.navigate('apps'));
  await input().fill('Подготовить встречу');
  await expect(rows()).toHaveCount(1);
  await screenshot('global-search.png');
  await input().press('Enter');
  assert.equal(await runs(), 1);
  await app.evaluate(() => (globalThis as any).shortcutTest.finish('completed'));
  await expect(page.locator('.shortcut-run-status')).toContainText('Выполнено');
  await expect(rows()).toBeEnabled();
  await rows().dispatchEvent('click', { detail: 2 });
  assert.equal(await runs(), 1);
  // Physical digit codes preserve numbered commands on non-English layouts.
  await input().dispatchEvent('keydown', { key: '!', code: 'Digit1', metaKey: true });
  await expect.poll(runs).toBe(2);
  await app.evaluate(() => (globalThis as any).shortcutTest.finish('cancelled'));
  await expect(page.locator('.shortcut-run-status')).toContainText('Отменено');
  await rows().click();
  await expect.poll(runs).toBe(3);
  await app.evaluate(() => (globalThis as any).shortcutTest.finish('failed'));
  await expect(page.locator('.shortcut-run-status')).toContainText('Нет разрешения');
  await screenshot('error.png');
  // A command removed after discovery is explained at activation, then removed
  // from results just like an uninstalled app.
  await input().fill('изображений');
  await expect(rows()).toHaveCount(1);
  await app.evaluate(() => (globalThis as any).shortcutTest.remove());
  await rows().click();
  await expect(page.locator('.shortcut-run-status')).toContainText('Команда удалена');
  await expect(rows()).toHaveCount(0);
  assert.equal(await runs(), 3);
  await screenshot('removed.png');
  await app.evaluate(() => {
    (globalThis as any).shortcutTest.rename();
    (globalThis as any).shortcutTest.add();
  });
  await app.evaluate(() => (globalThis as any).fixture.navigate('apps'));
  await input().fill('совещание');
  await expect(rows()).toContainText('Подготовить совещание');
  await input().fill('отчёт');
  await expect(rows()).toContainText('Подготовить отчёт');
  // Failed discovery retains names, marks results unavailable and offers retry.
  await app.evaluate(() => (globalThis as any).shortcutTest.failList(true));
  await app.evaluate(() => (globalThis as any).fixture.navigate('apps'));
  await input().fill('совещание');
  await expect(page.getByRole('alert')).toContainText('Последний список сохранён');
  await expect(rows()).toBeDisabled();
  await screenshot('catalog-error.png');
  await app.evaluate(() => (globalThis as any).shortcutTest.failList(false));
  const retry = page.getByRole('button', { name: 'Обновить команды', exact: true });
  await expect(retry).toHaveAttribute('aria-keyshortcuts', 'Meta+R');
  await input().dispatchEvent('keydown', { key: 'к', code: 'KeyR', metaKey: true });
  await expect(page.getByRole('alert')).toHaveCount(0);
  await expect(input()).toHaveValue('совещание');
  await expect(rows()).toBeEnabled();
  await app.evaluate(() => (globalThis as any).shortcutTest.failList(true));
  await app.evaluate(() => (globalThis as any).fixture.navigate('apps'));
  await expect(retry).toBeEnabled();
  await app.evaluate(() => (globalThis as any).shortcutTest.failList(false));
  await retry.click();
  await expect(page.getByRole('alert')).toHaveCount(0);
  await input().fill('shortcuts');
  await folder().click();
  await app.evaluate(() => (globalThis as any).shortcutTest.many());
  await input().press('Meta+r');
  await expect(rows()).toHaveCount(40);
  await rows().last().click();
  await expect.poll(runs).toBe(4);
  await expect(page.locator('.shortcut-run-status')).toBeInViewport();
  await app.evaluate(() => (globalThis as any).shortcutTest.finish('failed'));
  await expect(page.locator('.shortcut-run-status')).toContainText('Нет разрешения');
  await expect(page.locator('.shortcut-run-status')).toBeInViewport();
  await screenshot('scrolled-error.png');
  await app.evaluate(() => (globalThis as any).shortcutTest.empty());
  await input().press('Meta+r');
  await expect(rows()).toHaveCount(0);
  await expect(page.getByText('На этом Mac пока нет команд.', { exact: false })).toBeVisible();
  await input().fill('совещание');
  await expect(rows()).toHaveCount(0);
  await expect(
    page.getByText('Ничего не найдено. Попробуйте другое слово.', { exact: true }),
  ).toBeVisible();
  test.assertNoRendererErrors();
  await test.close(app, true);
  app = await test.launch({ args: [entry] });
  page = await app.firstWindow();
  await expect(folder()).toHaveCount(1);
  await expect(rows()).toHaveCount(0);
  await input().fill('встречу');
  await expect(rows()).toHaveCount(1);
  assert.equal(await runs(), 0);
  // No fixture action touches the user's clipboard or launches their apps.
  test.assertNoRendererErrors();
  console.log(
    'macOS Shortcuts UI: folder below apps, searchable folder and commands, keyboard/mouse navigation and run, query restoration, duplicate guard, responsive calculation, reopen, completion, cancellation, errors, rename, addition, removal, empty folder and retry passed.',
  );
}
void runDesktopTest('macos-shortcuts', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
