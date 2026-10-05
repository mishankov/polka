import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-paste-'));
  const app = await electron.launch({
    args: [resolve('.')],
    env: { ...process.env, EVERYTHING_PROFILE: profile, EVERYTHING_PASTE_DEBUG: '1' },
  });
  app.on('console', (message) => {
    if (message.text().startsWith('Clipboard paste')) console.log(message.text());
  });
  let target: Awaited<ReturnType<typeof electron.launch>> | undefined;
  let backedUp = false;
  try {
    const shell = await app.firstWindow();
    await shell.locator('.launcher').waitFor();
    await app.evaluate(async ({ clipboard, ClipboardItem }) => {
      (globalThis as any).__clipboardBackup = await Promise.all(
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
    await shell.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', {
        hoverEnabled: false,
        pasteOnSelect: true,
      }),
    );
    await expect
      .poll(() =>
        shell.evaluate(() =>
          window.platform.call('clipboardHistory.state').then((state) => state.registered),
        ),
      )
      .toBe(true);
    // Probe's ready message precedes the first clipboard change.
    await app.evaluate(({ clipboard }) => clipboard.writeText('Paste fixture: one selection'));
    await expect
      .poll(() =>
        shell.evaluate(() =>
          window.platform.call('clipboardHistory.state').then((state) => state.clips.length),
        ),
      )
      .toBe(1);
    const fixture = join(profile, 'target.cjs');
    const focusProbeSource = join(profile, 'menu-owner.swift');
    const focusProbe = join(profile, 'menu-owner');
    await writeFile(
      focusProbeSource,
      'import AppKit\nprint(NSWorkspace.shared.menuBarOwningApplication?.processIdentifier ?? 0)\n',
    );
    await promisify(execFile)('swiftc', [
      focusProbeSource,
      '-o',
      focusProbe,
      '-framework',
      'AppKit',
    ]);
    const menuOwner = async () => Number((await promisify(execFile)(focusProbe)).stdout.trim());
    await writeFile(
      fixture,
      `const {app,BrowserWindow,Menu}=require('electron');
app.whenReady().then(()=>{app.setAccessibilitySupportEnabled(true);Menu.setApplicationMenu(Menu.buildFromTemplate([{role:'editMenu'}]));const w=new BrowserWindow({width:500,height:250,title:'Paste test target'});w.loadURL('data:text/html,<title>Paste test target</title><textarea id="first" autofocus></textarea><textarea id="second"></textarea>');});app.on('window-all-closed',()=>app.quit());`,
    );
    target = await electron.launch({ args: [fixture] });
    const inputWindow = await target.firstWindow();
    const accessibility = await target.context().newCDPSession(inputWindow);
    await accessibility.send('Accessibility.enable');
    let shelf: Awaited<ReturnType<typeof app.firstWindow>> | undefined;
    for (const scenario of ['retained', 'blurred', 'recreated'] as const) {
      await inputWindow.setContent(
        `<title>Paste test target</title>${
          scenario === 'recreated'
            ? '<div id="first" contenteditable="true" role="textbox" aria-multiline="true" style="width:250px;height:80px;border:1px solid"></div>'
            : '<textarea id="first"></textarea>'
        }<textarea id="second"></textarea>`,
      );
      const input = inputWindow.locator('#first');
      await target.evaluate(({ BrowserWindow, app }) => {
        app.focus({ steal: true });
        BrowserWindow.getAllWindows()[0].focus();
      });
      await input.fill('Before: replace after');
      await inputWindow.evaluate(() => {
        const field = document.querySelector<HTMLElement>('#first')!;
        field.focus();
        if (field instanceof HTMLTextAreaElement) field.setSelectionRange(8, 15);
        else {
          const range = document.createRange();
          range.setStart(field.firstChild!, 8);
          range.setEnd(field.firstChild!, 15);
          getSelection()!.removeAllRanges();
          getSelection()!.addRange(range);
        }
      });
      await expect(input).toBeFocused();
      await expect.poll(menuOwner).toBe(target.process().pid);
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
      if (scenario === 'retained') {
        // First opening via hover must take keys without taking the menu bar.
        await app.evaluate(({ screen }) => {
          (globalThis as any).__realCursor = screen.getCursorScreenPoint;
          const { bounds } = screen.getPrimaryDisplay();
          (globalThis as any).__qaCursor = { x: bounds.x + bounds.width / 2, y: bounds.y + 500 };
          screen.getCursorScreenPoint = () => (globalThis as any).__qaCursor;
        });
        await shell.evaluate(() =>
          window.platform.call('clipboardHistory.preferences', { hoverEnabled: true }),
        );
        // The startup shelf was dismissed when the target app took focus. Leave
        // the hot zone before entering it again, as a real pointer would.
        await new Promise((resolve) => setTimeout(resolve, 200));
        await app.evaluate(({ screen }) => {
          (globalThis as any).__qaCursor.y = screen.getPrimaryDisplay().bounds.y + 1;
        });
      } else await shell.evaluate(() => window.platform.call('launcher.show'));
      await expect.poll(() => app.windows().some((w) => w.url().includes('mode=shelf'))).toBe(true);
      shelf = app.windows().find((w) => w.url().includes('mode=shelf'))!;
      await expect
        .poll(() =>
          app.evaluate(({ BrowserWindow }) =>
            BrowserWindow.getAllWindows()
              .find((w) => w.webContents.getURL().includes('mode=shelf'))
              ?.isFocused(),
          ),
        )
        .toBe(true);
      const search = shelf.getByRole('combobox', { name: 'Поиск по полке' });
      await expect(search).toBeFocused();
      if (scenario === 'retained')
        await app.evaluate(() => {
          (globalThis as any).__qaCursor.y += 100;
        });
      assert.equal(
        await menuOwner(),
        target.process().pid,
        'Previous app retains the menu bar while the shelf has keyboard focus',
      );
      if (scenario !== 'retained') {
        // Reproduce editors dropping/rebuilding their responder while the shelf owns focus.
        await inputWindow.evaluate((scenario) => {
          const field = document.querySelector<HTMLElement>('#first')!;
          if (scenario === 'recreated') field.replaceWith(field.cloneNode(true));
          else field.blur();
        }, scenario);
        await expect(input).not.toBeFocused();
      }
      // Search results and navigation must retain the original target and selection.
      let selectionSearch = search;
      if (scenario === 'retained') {
        await search.fill('Paste fixture');
        await expect(shelf.locator('.launcher-result[data-kind="clip"]')).toHaveCount(1);
      } else {
        await search.fill('clipboard');
        await search.press('Enter');
        selectionSearch = shelf.getByRole('combobox', { name: 'Найти в истории' });
        await expect(selectionSearch).toBeFocused();
      }
      assert.equal(
        await menuOwner(),
        target.process().pid,
        'Navigating inside the shelf preserves the active app',
      );
      const state = await shelf.evaluate(() => window.platform.call('clipboardHistory.state'));
      if (state.pasteAccess === 'required' && scenario !== 'retained')
        await expect(shelf.getByText('Разрешить…', { exact: true })).toBeVisible();
      await expect
        .poll(() =>
          shelf!
            .locator('.clipboard-shelf')
            .evaluate((element) =>
              element.getAnimations().some((animation) => animation.playState === 'running'),
            ),
        )
        .toBe(false);
      await selectionSearch.press('Enter');

      await expect
        .poll(() =>
          app.evaluate(({ BrowserWindow }) =>
            BrowserWindow.getAllWindows()
              .find((w) => w.webContents.getURL().includes('mode=shelf'))!
              .isVisible(),
          ),
        )
        .toBe(false);
      if (scenario === 'retained') {
        await shell.evaluate(() =>
          window.platform.call('clipboardHistory.preferences', { hoverEnabled: false }),
        );
        await app.evaluate(({ screen }) => {
          screen.getCursorScreenPoint = (globalThis as any).__realCursor;
        });
      }
      const content = () =>
        input.evaluate((field) =>
          field instanceof HTMLTextAreaElement ? field.value : field.textContent,
        );
      if (state.pasteAccess === 'granted') {
        assert(state.pasteReady, 'Native helper captures the previously focused field');
        await expect.poll(content).toBe('Before: Paste fixture: one selection after');
        await expect(input).toBeFocused();
        await expect(inputWindow.locator('#second')).toHaveValue('');
        console.log(
          `Native paste passed (${scenario}): restored original editor and selection, one paste, second field untouched.`,
        );
      } else {
        await expect.poll(content).toBe('Before: replace after');
        assert.equal(
          await app.evaluate(({ clipboard }) => clipboard.readText()),
          'Paste fixture: one selection',
        );
        console.log(
          `Copy fallback passed (${scenario}). Native paste remains unverified: Accessibility permission is not granted to the helper. No permission prompt was opened.`,
        );
      }
    }
  } finally {
    if (target) await target.close();
    if (backedUp)
      await app
        .evaluate(async ({ clipboard }) => {
          const items = (globalThis as any).__clipboardBackup;
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
