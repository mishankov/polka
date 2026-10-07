import { runDesktopTest, type DesktopTest } from './desktop-test';
import { clipId } from '../src/main/clipboard-history';
import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import type { ViteDevServer } from 'vite';

async function main(test: DesktopTest) {
  const profile = test.profile;
  const development = process.argv.includes('--dev');
  let rendererServer: ViteDevServer | undefined;
  let rendererUrl: string | undefined;
  test.deferCleanup(async () => {
    await rendererServer?.close();
  });
  if (development) {
    const [{ resolveConfig }, { createServer }] = await Promise.all([
      import('electron-vite'),
      import('vite'),
    ]);
    const resolved = await resolveConfig({}, 'serve', 'development');
    rendererServer = await createServer({
      ...resolved.config!.renderer,
      configFile: false,
      server: { host: '127.0.0.1', port: 0 },
    });
    await rendererServer.listen();
    const address = rendererServer.httpServer!.address();
    assert(address && typeof address !== 'string');
    rendererUrl = `http://127.0.0.1:${address.port}`;
    console.log(`Testing development renderer: ${rendererUrl}`);
  }
  const app = await test.launch({
    args: [resolve('.')],
    env: {
      ...process.env,
      EVERYTHING_PROFILE: profile,
      EVERYTHING_PASTE_DEBUG: process.env.EVERYTHING_PASTE_DEBUG ?? '1',
      ...(rendererUrl ? { ELECTRON_RENDERER_URL: rendererUrl } : {}),
    },
  });
  app.on('console', (message) => {
    if (message.text().startsWith('Clipboard paste')) console.log(message.text());
  });
  let target: Awaited<ReturnType<typeof electron.launch>> | undefined;
  try {
    const shell = await app.firstWindow();
    await shell.locator('.launcher').waitFor();
    await test.backupClipboard(app);
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
    await app.evaluate(({ clipboard }) => clipboard.writeText('Paste fixture: one selection'));
    await test.keepClipboardFixture(shell, clipId('text', 'Paste fixture: one selection'));
    const fixture = join(profile, 'target.cjs');
    const focusProbeSource = join(profile, 'menu-owner.swift');
    const focusProbe = join(profile, 'menu-owner');
    await writeFile(
      focusProbeSource,
      `import AppKit
let owner = CommandLine.arguments.contains("--front") ? NSWorkspace.shared.frontmostApplication : NSWorkspace.shared.menuBarOwningApplication
let details: [String: Any] = ["pid": owner?.processIdentifier ?? 0, "bundle": owner?.bundleIdentifier ?? "", "name": owner?.localizedName ?? ""]
let data = try JSONSerialization.data(withJSONObject: details)
print(String(data: data, encoding: .utf8)!)
`,
    );
    await promisify(execFile)('swiftc', [
      focusProbeSource,
      '-o',
      focusProbe,
      '-framework',
      'AppKit',
    ]);
    const menuOwner = async () => {
      const owner = JSON.parse((await promisify(execFile)(focusProbe)).stdout.trim());
      test.recordDiagnostic('menuOwner', owner);
      return Number(owner.pid);
    };
    await writeFile(
      fixture,
      `const {app,BrowserWindow,Menu}=require('electron');app.setPath('userData', ${JSON.stringify(join(profile, 'target-profile'))});
app.whenReady().then(()=>{app.setAccessibilitySupportEnabled(true);Menu.setApplicationMenu(Menu.buildFromTemplate([{role:'editMenu'}]));const w=new BrowserWindow({show:false,width:500,height:250,title:'Paste test target'});w.loadURL('data:text/html,<title>Paste test target</title><textarea id="first" autofocus></textarea><textarea id="second"></textarea>').then(()=>{w.show();w.focus();});});app.on('window-all-closed',()=>app.quit());`,
    );
    target = await test.launch({ args: [fixture] });
    const inputWindow = await target.firstWindow();
    const accessibility = await target.context().newCDPSession(inputWindow);
    await accessibility.send('Accessibility.enable');
    let shelf: Awaited<ReturnType<typeof app.firstWindow>> | undefined;
    for (const scenario of ['retained', 'blurred', 'recreated', 'transformed'] as const) {
      await inputWindow.setContent(
        `<title>Paste test target</title>${
          scenario === 'recreated'
            ? '<div id="first" contenteditable="true" role="textbox" aria-multiline="true" style="width:250px;height:80px;border:1px solid"></div>'
            : '<textarea id="first"></textarea>'
        }<textarea id="second"></textarea>`,
      );
      const input = inputWindow.locator('#first');
      await expect
        .poll(async () => {
          const owner = await menuOwner();
          // AppKit can retain a key window in an inactive app. The menu-bar
          // owner identifies actual activation; acquire it before the scenario.
          const window = await target!.evaluate(({ BrowserWindow, app }, activate) => {
            const window = BrowserWindow.getAllWindows()[0];
            if (activate) app.focus({ steal: true });
            if (!window.isVisible()) window.show();
            if (!window.isFocused()) window.focus();
            return { visible: window.isVisible(), focused: window.isFocused() };
          }, owner !== target!.process().pid);
          return { owner, ...window };
        })
        .toEqual({ owner: target.process().pid, visible: true, focused: true });
      let focusedSince: number | undefined;
      await expect
        .poll(
          async () => {
            const focused = await target!.evaluate(({ BrowserWindow }) =>
              BrowserWindow.getAllWindows()[0].isFocused(),
            );
            // AppKit activation and renderer focus are separate transitions.
            // Require native focus to settle before a panel can take it back.
            if (!focused) focusedSince = undefined;
            else focusedSince ??= Date.now();
            return focusedSince !== undefined && Date.now() - focusedSince >= 100;
          },
          { intervals: [20] },
        )
        .toBe(true);
      await test.shelfHidden(app, shell);
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
      if (scenario === 'retained' && !development) {
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
      } else
        await shell.evaluate(() => window.platform.call('launcher.show', { destination: 'apps' }));
      await expect.poll(() => app.windows().some((w) => w.url().includes('mode=shelf'))).toBe(true);
      shelf = app.windows().find((w) => w.url().includes('mode=shelf'))!;
      await test.shelfReady(app, shelf, 'Поиск по полке');
      const search = shelf.getByRole('combobox', { name: 'Поиск по полке' });
      await expect(search).toBeFocused();
      if (scenario === 'retained' && !development)
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
      if (scenario === 'retained' && !development) {
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
      const expectedText =
        scenario === 'transformed'
          ? 'PASTE FIXTURE: ONE SELECTION'
          : 'Paste fixture: one selection';
      if (scenario === 'transformed') {
        await selectionSearch.press('Meta+Enter');
        const preview = shelf.getByRole('region', { name: 'Просмотр записи' });
        // CDP mouse clicks on a nonactivating macOS panel can transfer native
        // focus to the external fixture. Mouse actions have their own suite;
        // keep this fixture on the keyboard path while testing real AX paste.
        await preview.getByRole('button', { name: 'ПРОПИСНЫЕ', exact: true }).press('Meta+1');
        await expect(preview.locator('pre')).toHaveText(expectedText);
        await preview
          .getByRole('button', { name: state.pasteReady ? 'Вставить' : 'Копировать', exact: true })
          .press('Enter');
      } else await selectionSearch.press('Enter');

      await expect
        .poll(() =>
          app.evaluate(({ BrowserWindow }) =>
            BrowserWindow.getAllWindows()
              .find((w) => w.webContents.getURL().includes('mode=shelf'))!
              .isVisible(),
          ),
        )
        .toBe(false);
      if (scenario === 'retained' && !development) {
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
        await expect.poll(content).toBe(`Before: ${expectedText} after`);
        await expect(input).toBeFocused();
        await expect(inputWindow.locator('#second')).toHaveValue('');
        console.log(
          `Native paste passed (${scenario}): restored original editor and selection, one paste, second field untouched.`,
        );
      } else {
        await expect.poll(content).toBe('Before: replace after');
        assert.equal(await app.evaluate(({ clipboard }) => clipboard.readText()), expectedText);
        console.log(
          `Copy fallback passed (${scenario}). Native paste remains unverified: Accessibility permission is not granted to the helper. No permission prompt was opened.`,
        );
      }
      const clips = await shell.evaluate(() =>
        window.platform.call('clipboardHistory.state').then((s) => s.clips),
      );
      assert.equal(clips.length, 1);
      assert.equal(clips[0].content, 'Paste fixture: one selection');
      if (scenario === 'blurred' && state.pasteAccess === 'granted') {
        let expectedContent = 'Before: Paste fixture: one selection after';
        const holdWrite = () =>
          app.evaluate(({ clipboard }) => {
            (globalThis as any).__realClipboardWrite ??= clipboard.write.bind(clipboard);
            (globalThis as any).__writeWaiting = false;
            (globalThis as any).__writeFinished = false;
            clipboard.write = async (items) => {
              (globalThis as any).__writeWaiting = true;
              await new Promise((resolve) => ((globalThis as any).__releaseWrite = resolve));
              await (globalThis as any).__realClipboardWrite(items);
              (globalThis as any).__writeFinished = true;
            };
          });
        const releaseWrite = () =>
          app.evaluate(({ clipboard }) => {
            clipboard.write = (globalThis as any).__realClipboardWrite;
            (globalThis as any).__releaseWrite();
          });
        // Reopen directly after paste, without reactivating/refilling the target app.
        // This retains the history screen and catches a lost target on the next opening.
        for (let reopen = 1; reopen <= 3; reopen++) {
          await inputWindow.evaluate(() => {
            const field = document.querySelector<HTMLTextAreaElement>('#first')!;
            field.setSelectionRange(field.value.length, field.value.length);
          });
          await shell.evaluate(() => window.platform.call('launcher.show'));
          const historySearch = shelf.getByRole('combobox', { name: 'Найти в истории' });
          await expect(historySearch).toBeFocused();
          const reopenedState: { pasteReady?: boolean } = await shelf.evaluate(() =>
            window.platform.call('clipboardHistory.state'),
          );
          assert.equal(
            reopenedState.pasteReady,
            true,
            `Opening ${reopen + 1} captures a new target`,
          );
          await historySearch.press('Enter');
          expectedContent += 'Paste fixture: one selection';
          await expect.poll(content).toBe(expectedContent);
          await expect(input).toBeFocused();
          console.log(
            `Native paste passed (reopen ${reopen + 1}): a fresh target was captured and pasted once.`,
          );
        }
        for (const dismissal of ['Escape', 'Shift+Enter']) {
          await shell.evaluate(() => window.platform.call('launcher.show'));
          const historySearch = shelf.getByRole('combobox', { name: 'Найти в истории' });
          await expect(historySearch).toBeFocused();
          await historySearch.press(dismissal);
          await expect
            .poll(() =>
              app.evaluate(({ BrowserWindow }) =>
                BrowserWindow.getAllWindows()
                  .find((w) => w.webContents.getURL().includes('mode=shelf'))!
                  .isVisible(),
              ),
            )
            .toBe(false);
          console.log('Native target after ordinary dismissal', {
            dismissal,
            frontPID: Number(
              JSON.parse((await promisify(execFile)(focusProbe, ['--front'])).stdout.trim()).pid,
            ),
            targetPID: target.process().pid,
          });
          await shell.evaluate(() => window.platform.call('launcher.show'));
          await expect(historySearch).toBeFocused();
          const ready: boolean = await shelf.evaluate(() =>
            window.platform.call('clipboardHistory.state').then((state) => !!state.pasteReady),
          );
          assert(ready, `Reopening after ${dismissal} captures a target`);
          await historySearch.press('Enter');
          expectedContent += 'Paste fixture: one selection';
          await expect.poll(content).toBe(expectedContent);
          await expect(input).toBeFocused();
          console.log(
            `Native paste passed (after ${dismissal}): ordinary close does not strand the next opening.`,
          );
        }
        // Generic hover reopening keeps the history destination. A slow clipboard
        // write must not let pointer departure cancel the selected paste mid-flight.
        await app.evaluate(({ screen }) => {
          (globalThis as any).__realCursor = screen.getCursorScreenPoint;
          const { bounds } = screen.getPrimaryDisplay();
          (globalThis as any).__qaCursor = { x: bounds.x, y: bounds.y + 700 };
          screen.getCursorScreenPoint = () => (globalThis as any).__qaCursor;
        });
        await shell.evaluate(() =>
          window.platform.call('clipboardHistory.preferences', { hoverEnabled: true }),
        );
        await new Promise((resolve) => setTimeout(resolve, 200));
        await app.evaluate(({ screen }) => {
          const { bounds } = screen.getPrimaryDisplay();
          (globalThis as any).__qaCursor = { x: bounds.x + bounds.width / 2, y: bounds.y + 1 };
        });
        await expect
          .poll(() =>
            app.evaluate(({ BrowserWindow }) =>
              BrowserWindow.getAllWindows()
                .find((w) => w.webContents.getURL().includes('mode=shelf'))!
                .isFocused(),
            ),
          )
          .toBe(true);
        const hoverSearch = shelf.getByRole('combobox', { name: 'Найти в истории' });
        await expect(hoverSearch).toBeFocused();
        await holdWrite();
        await hoverSearch.press('Enter');
        await expect.poll(() => app.evaluate(() => (globalThis as any).__writeWaiting)).toBe(true);
        await app.evaluate(({ screen }) => {
          const { bounds } = screen.getPrimaryDisplay();
          (globalThis as any).__qaCursor = { x: bounds.x, y: bounds.y + 700 };
        });
        await new Promise((resolve) => setTimeout(resolve, 400));
        const remainedOpen = await app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows()
            .find((w) => w.webContents.getURL().includes('mode=shelf'))!
            .isVisible(),
        );
        await app.evaluate(({ screen }) => {
          screen.getCursorScreenPoint = (globalThis as any).__realCursor;
        });
        await releaseWrite();
        assert(remainedOpen, 'Hover departure must not dismiss a pending paste');
        expectedContent += 'Paste fixture: one selection';
        await expect.poll(content).toBe(expectedContent);
        await expect(input).toBeFocused();
        await shell.evaluate(() =>
          window.platform.call('clipboardHistory.preferences', { hoverEnabled: false }),
        );
        console.log(
          'Native paste passed (hover departure during slow copy): selection completes before automatic dismissal.',
        );
        // A delayed native blur must obey the same guard for keyboard openings.
        await shell.evaluate(() => window.platform.call('launcher.show'));
        await expect(hoverSearch).toBeFocused();
        await holdWrite();
        await hoverSearch.press('Enter');
        await expect.poll(() => app.evaluate(() => (globalThis as any).__writeWaiting)).toBe(true);
        await app.evaluate(({ BrowserWindow }) => {
          const win = BrowserWindow.getAllWindows().find((w) =>
            w.webContents.getURL().includes('mode=shelf'),
          )!;
          const focused = win.isFocused;
          try {
            win.isFocused = () => false;
            win.emit('blur');
          } finally {
            win.isFocused = focused;
          }
        });
        await new Promise((resolve) => setTimeout(resolve, 400));
        assert(
          await app.evaluate(({ BrowserWindow }) =>
            BrowserWindow.getAllWindows()
              .find((w) => w.webContents.getURL().includes('mode=shelf'))!
              .isVisible(),
          ),
          'Native blur must not dismiss a pending paste',
        );
        await releaseWrite();
        expectedContent += 'Paste fixture: one selection';
        await expect.poll(content).toBe(expectedContent);
        await expect(input).toBeFocused();
        console.log(
          'Native paste passed (blur during slow copy): automatic blur preserves selection.',
        );

        // Explicit close must still cancel the old action. Reopening cannot let
        // its late completion close the new shelf or paste into the old target.
        await shell.evaluate(() => window.platform.call('launcher.show'));
        await expect(hoverSearch).toBeFocused();
        await holdWrite();
        await hoverSearch.press('Enter');
        await expect.poll(() => app.evaluate(() => (globalThis as any).__writeWaiting)).toBe(true);
        await shelf.evaluate(() => window.platform.call('clipboardHistory.hide'));
        await expect
          .poll(() =>
            app.evaluate(({ BrowserWindow }) =>
              BrowserWindow.getAllWindows()
                .find((w) => w.webContents.getURL().includes('mode=shelf'))!
                .isVisible(),
            ),
          )
          .toBe(false);
        await shell.evaluate(() => window.platform.call('launcher.show'));
        await expect(hoverSearch).toBeFocused();
        await releaseWrite();
        await expect.poll(() => app.evaluate(() => (globalThis as any).__writeFinished)).toBe(true);
        await new Promise((resolve) => setTimeout(resolve, 250));
        assert.equal(await content(), expectedContent, 'Cancelled selection must not paste late');
        await expect(hoverSearch).toBeFocused();
        await hoverSearch.press('Enter');
        expectedContent += 'Paste fixture: one selection';
        await expect.poll(content).toBe(expectedContent);
        await expect(input).toBeFocused();
        console.log(
          'Native paste passed (cancelled slow copy): new opening owns its own action and target.',
        );
      }
    }
  } catch (error) {
    const shelf = app.windows().find((page) => page.url().includes('mode=shelf'));
    if (shelf)
      console.error(
        'Failed paste state',
        await shelf
          .evaluate(async () => {
            const state = await window.platform.call('clipboardHistory.state');
            return {
              presentation: await window.platform.call('shelf.presentation'),
              pasteReady: state.pasteReady,
              pasteAccess: state.pasteAccess,
              shelfClass: document.querySelector('.clipboard-shelf')?.className,
              error: document.querySelector('.clipboard-error')?.textContent,
              focus: document.activeElement?.getAttribute('aria-label'),
            };
          })
          .catch(() => 'Renderer unavailable'),
      );
    throw error;
  } finally {
    await app
      .evaluate(({ clipboard, screen }) => {
        if ((globalThis as any).__realClipboardWrite)
          clipboard.write = (globalThis as any).__realClipboardWrite;
        if ((globalThis as any).__releaseWrite) (globalThis as any).__releaseWrite();
        if ((globalThis as any).__realCursor)
          screen.getCursorScreenPoint = (globalThis as any).__realCursor;
      })
      .catch(() => {});
  }
}
void runDesktopTest('clipboard-paste', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
