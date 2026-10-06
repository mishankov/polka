import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { SettingsStore } from '../src/main/settings-store';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'polka-emoji-'));
  const settings = new SettingsStore(profile);
  await settings.handle('settings.set', { key: 'mediaIndicatorEnabled', value: false });
  settings.close();
  const artifacts = resolve('artifacts/emoji');
  await mkdir(artifacts, { recursive: true });
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  let target: Awaited<ReturnType<typeof electron.launch>> | undefined;
  let backedUp = false;
  const errors: string[] = [];
  try {
    const page = await app.firstWindow();
    page.on('pageerror', (error) => errors.push(error.message));
    await expect(page.getByRole('combobox', { name: 'Поиск по полке', exact: true })).toBeFocused();
    if (process.argv.includes('--empty-clipboard-item')) {
      // Exercise the CI pasteboard shape without clearing the user's clipboard.
      await app.evaluate(({ clipboard, ClipboardItem }) => {
        const read = clipboard.read.bind(clipboard);
        clipboard.read = async () => [
          { types: [], getType: ClipboardItem.prototype.getType },
          ...(await read()),
        ];
      });
    }
    await app.evaluate(async ({ clipboard, ClipboardItem }) => {
      // An empty native pasteboard can expose an item with no readable MIME types.
      (globalThis as any).__emojiClipboardBackup = await Promise.all(
        (await clipboard.read())
          .filter((item) => item.types.length > 0)
          .map(
            async (item) =>
              new ClipboardItem(
                Object.fromEntries(
                  await Promise.all(
                    item.types.map(async (type) => [type, await item.getType(type)]),
                  ),
                ),
              ),
          ),
      );
    });
    backedUp = true;
    await page.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', {
        hoverEnabled: false,
        pasteOnSelect: false,
      }),
    );
    const mainSearch = page.getByRole('combobox', { name: 'Поиск по полке', exact: true });
    const launcherReady = async () => {
      await expect(mainSearch).toBeFocused();
      // Focus commits before the launcher's navigation reset runs in a passive effect.
      await page.evaluate(
        () =>
          new Promise<void>((resolve) => {
            requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
          }),
      );
    };
    await launcherReady();
    await mainSearch.fill('emoji');
    await expect(page.getByRole('option', { name: /^Эмодзи / })).toHaveAttribute(
      'aria-selected',
      'true',
    );
    await mainSearch.press('Enter');
    const search = page.getByRole('combobox', { name: 'Найти эмодзи', exact: true });
    await expect(search).toBeFocused();
    const grid = page.getByRole('grid', { name: 'Эмодзи для вставки' });
    await expect(page.locator('.emoji-row').first().getByRole('gridcell')).toHaveCount(10);
    await search.press('ArrowDown');
    await expect(grid.getByRole('gridcell').first()).toBeFocused();
    await page.keyboard.press('ArrowRight');
    await expect(grid.getByRole('gridcell').nth(1)).toBeFocused();
    await page.keyboard.press('ArrowDown');
    await expect(grid.getByRole('gridcell').nth(11)).toBeFocused();
    await page.keyboard.press('Home');
    await expect(grid.getByRole('gridcell').first()).toBeFocused();
    assert.equal(
      await grid
        .getByRole('gridcell')
        .first()
        .evaluate((cell) => getComputedStyle(cell).outlineStyle),
      'solid',
    );
    await expect
      .poll(() =>
        page
          .locator('.clipboard-shelf')
          .evaluate((element) =>
            element.getAnimations().some((animation) => animation.playState === 'running'),
          ),
      )
      .toBe(false);
    await page.screenshot({ path: join(artifacts, 'emoji-picker.png') });

    await page.getByRole('tab', { name: 'Животные и природа' }).click();
    await expect(page.getByRole('tab', { name: 'Животные и природа' })).toHaveAttribute(
      'aria-selected',
      'true',
    );
    await expect(grid.getByRole('gridcell').first()).toHaveAttribute('aria-label', /обезьян/);
    await page.screenshot({ path: join(artifacts, 'emoji-category.png') });
    await page.keyboard.press('ArrowRight');
    await expect(page.getByRole('tab', { name: 'Еда и напитки' })).toBeFocused();
    await page.keyboard.press('Home');
    await expect(page.getByRole('tab', { name: 'Все эмодзи' })).toBeFocused();

    await search.fill('любовь');
    await expect(page.getByRole('tab', { name: 'Все эмодзи' })).toHaveAttribute(
      'aria-selected',
      'true',
    );
    await expect(page.locator('#emoji-2764-fe0f')).toBeVisible();
    await search.press('ArrowDown');
    await page.mouse.move(0, 0);
    await page.screenshot({ path: join(artifacts, 'emoji-search.png') });
    await search.fill('zz-no-results-zz');
    await expect(page.getByText('Ничего не найдено', { exact: true })).toBeVisible();
    await expect(grid.getByRole('gridcell')).toHaveCount(0);
    await expect(search).not.toHaveAttribute('aria-activedescendant');
    await search.press('Enter');
    await expect(page.locator('.clipboard-shelf')).toHaveClass(/is-open/);
    await page.screenshot({ path: join(artifacts, 'emoji-empty.png') });
    await search.fill('лайк');
    await page.getByRole('combobox', { name: 'Оттенок кожи' }).selectOption('🏽');
    await expect(page.locator('#emoji-1f44d-1f3fd')).toBeVisible();
    await expect(page.locator('#emoji-1f44d-1f3fb')).toHaveCount(0);
    await page.getByRole('combobox', { name: 'Оттенок кожи' }).selectOption('all');
    await expect(page.locator('#emoji-1f44d-1f3fb')).toBeVisible();
    await page.getByRole('combobox', { name: 'Оттенок кожи' }).selectOption('default');

    const visible = () =>
      app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .find((window) => window.webContents.getURL().includes('mode=shelf'))!
          .isVisible(),
      );
    const readClipboard = () => app.evaluate(({ clipboard }) => clipboard.readText());
    const openPicker = async () => {
      await page.evaluate(() => window.platform.call('launcher.show', { destination: 'apps' }));
      await launcherReady();
      await mainSearch.fill('эмодзи');
      await expect(page.getByRole('option', { name: /^Эмодзи / })).toHaveAttribute(
        'aria-selected',
        'true',
      );
      await mainSearch.press('Enter');
      await expect(search).toBeFocused();
    };
    const reopenWithoutPickerFlash = async () => {
      // Delay destination delivery to expose any reveal of the previous picker.
      await app.evaluate(({ BrowserWindow }) => {
        const contents = BrowserWindow.getAllWindows().find((window) =>
          window.webContents.getURL().includes('mode=shelf'),
        )!.webContents;
        const send = contents.send.bind(contents);
        const wrapper = {
          send(channel: string, ...args: any[]) {
            if (channel === 'platform:event' && args[0]?.type === 'shelf.shown') {
              (globalThis as any).__pendingShelfShow = {
                revision: args[0].presentation.revision,
                deliver() {
                  contents.send = send;
                  send(channel, ...args);
                },
              };
              return;
            }
            send(channel, ...args);
          },
        };
        contents.send = wrapper.send;
      });
      const reopening = page.evaluate(() =>
        window.platform.call('launcher.show', { destination: 'apps' }),
      );
      void reopening.catch(() => {});
      await expect
        .poll(() => app.evaluate(() => !!(globalThis as any).__pendingShelfShow))
        .toBe(true);
      assert.equal(
        await visible(),
        false,
        'Keep the old emoji view hidden until navigation commits',
      );
      const revision = await app.evaluate(() => (globalThis as any).__pendingShelfShow.revision);
      await page.evaluate(
        (revision) => window.platform.call('shelf.didShow', { revision: revision - 1 }),
        revision,
      );
      assert.equal(await visible(), false, 'A stale renderer reply must not reveal the shelf');
      await app.evaluate(() => {
        (globalThis as any).__pendingShelfShow.deliver();
        delete (globalThis as any).__pendingShelfShow;
      });
      await reopening;
      await launcherReady();
      await expect(page.locator('.emoji-picker')).toHaveCount(0);
      assert.equal(await visible(), true);
    };
    await page.evaluate(async () => {
      try {
        await window.platform.call('shelf.copyEmoji', { id: 'invalid' });
        throw Error('Unknown emoji was accepted');
      } catch (error) {
        if (!String(error).includes('Эмодзи не найден')) throw error;
      }
    });
    for (const value of ['❤️', '👩🏽‍💻', '👨‍👩‍👧‍👦', '🇷🇺', '1️⃣', '🏳️‍🌈']) {
      await search.fill(value);
      await search.press('Shift+Enter');
      await expect.poll(visible).toBe(false);
      assert.equal(await readClipboard(), value, 'Copy preserves the complete Unicode sequence');
      assert(
        await app.evaluate(async ({ clipboard }) =>
          (await clipboard.read()).some((item) =>
            item.types.some((type) => type.includes('org.nspasteboard.AutoGeneratedType')),
          ),
        ),
      );
      if (value === '❤️') await reopenWithoutPickerFlash();
      await openPicker();
    }
    await search.fill('🔥');
    await page.getByRole('button', { name: 'Копировать', exact: true }).click();
    await expect.poll(visible).toBe(false);
    assert.equal(await readClipboard(), '🔥');
    await openPicker();
    await search.fill('🎉');
    await search.press('Enter');
    await expect.poll(visible).toBe(false);
    assert.equal(await readClipboard(), '🎉');
    await openPicker();
    await search.press('Escape');
    await expect.poll(visible).toBe(false);
    await openPicker();
    await search.press('Backspace');
    await launcherReady();
    await mainSearch.fill('2 + 2');
    await expect(page.locator('.launcher-calculation strong')).toHaveText('4');
    await mainSearch.press('Enter');
    assert.equal(await readClipboard(), '4');
    await expect.poll(visible).toBe(true);
    assert.equal(
      (await page.evaluate(() => window.platform.call('clipboardHistory.state'))).clips.length,
      0,
      'Polka-generated copies are not added to history',
    );

    const fixture = join(profile, 'target.cjs');
    await writeFile(
      fixture,
      `const {app,BrowserWindow,Menu}=require('electron');app.whenReady().then(()=>{app.setAccessibilitySupportEnabled(true);Menu.setApplicationMenu(Menu.buildFromTemplate([{role:'editMenu'}]));const w=new BrowserWindow({width:500,height:250,title:'Emoji paste target'});w.loadURL('data:text/html,<textarea id="first" autofocus></textarea><textarea id="second"></textarea>');});app.on('window-all-closed',()=>app.quit());`,
    );
    target = await electron.launch({ args: [fixture] });
    const targetPage = await target.firstWindow();
    const accessibility = await target.context().newCDPSession(targetPage);
    await accessibility.send('Accessibility.enable');
    await page.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', { pasteOnSelect: true }),
    );
    for (const copyOnly of [true, false]) {
      await target.evaluate(({ BrowserWindow, app }) => {
        app.focus({ steal: true });
        BrowserWindow.getAllWindows()[0].focus();
      });
      const field = targetPage.locator('#first');
      await field.fill('Before: replace after');
      // Use editor keystrokes so the native AX selection has committed before capture.
      await field.press('Meta+ArrowLeft');
      for (let index = 0; index < 8; index++) await field.press('ArrowRight');
      for (let index = 0; index < 7; index++) await field.press('Shift+ArrowRight');
      assert.deepEqual(
        await field.evaluate((field: HTMLTextAreaElement) => [
          field.selectionStart,
          field.selectionEnd,
        ]),
        [8, 15],
      );
      await expect(field).toBeFocused();
      await expect
        .poll(async () => {
          const { nodes } = await accessibility.send('Accessibility.getFullAXTree');
          return nodes.some(
            (node) =>
              node.role?.value === 'textbox' &&
              node.properties?.some(
                (property) => property.name === 'focused' && property.value.value === true,
              ),
          );
        })
        .toBe(true);
      await openPicker();
      const state = await page.evaluate(() => window.platform.call('clipboardHistory.state'));
      await search.fill('👩🏽‍💻');
      await search.press(copyOnly ? 'Shift+Enter' : 'Enter');
      await expect.poll(visible).toBe(false);
      assert.equal(await readClipboard(), '👩🏽‍💻');
      if (!copyOnly && state.pasteAccess === 'granted') {
        assert(state.pasteReady, 'Opening the picker retains the original editor target');
        await expect(field).toHaveValue('Before: 👩🏽‍💻 after');
        await expect(field).toBeFocused();
        console.log(
          'Emoji native paste passed: original field and selection restored; complete sequence inserted once.',
        );
      } else {
        await expect(field).toHaveValue('Before: replace after');
        if (!copyOnly)
          console.log(
            'Emoji copy fallback passed. Native insertion is unverified because Accessibility permission is unavailable.',
          );
      }
      await expect(targetPage.locator('#second')).toHaveValue('');
      if (!copyOnly) await reopenWithoutPickerFlash();
    }
    assert.deepEqual(errors, []);
    console.log(
      `Emoji smoke passed: bilingual search, categories, tones, keyboard navigation, full sequences, copy-only, calculator regression. Screenshots: ${artifacts}`,
    );
  } finally {
    if (target) await target.close();
    if (backedUp)
      await app
        .evaluate(async ({ clipboard }) => {
          const items = (globalThis as any).__emojiClipboardBackup;
          if (items.length) await clipboard.write(items);
          else clipboard.clear();
        })
        .catch(() => {});
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
