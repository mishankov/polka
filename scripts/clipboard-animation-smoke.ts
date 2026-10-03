import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-shelf-animation-'));
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  try {
    const shell = await app.firstWindow();
    await shell.locator('.home-page').waitFor();
    await new Promise((resolve) => setTimeout(resolve, 700));
    // Exercise lazy creation through hover, with the workspace hidden. This used
    // to transform the whole app's activation policy and remove its Dock icon.
    const dockBefore = await app.evaluate(({ app, BrowserWindow, screen }) => {
      for (const win of BrowserWindow.getAllWindows()) win.hide();
      (globalThis as any).__realCursor = screen.getCursorScreenPoint;
      const { bounds } = screen.getPrimaryDisplay();
      (globalThis as any).__qaCursor = { x: bounds.x, y: bounds.y + 500 };
      screen.getCursorScreenPoint = () => (globalThis as any).__qaCursor;
      return app.dock?.isVisible();
    });
    const opening = app.waitForEvent('window');
    await app.evaluate(({ screen }) => {
      const { bounds } = screen.getPrimaryDisplay();
      (globalThis as any).__qaCursor = {
        x: Math.round(bounds.x + bounds.width / 2),
        y: bounds.y + 1,
      };
    });
    const panel = await opening;
    const root = panel.locator('.clipboard-shelf');
    await expect(root).toHaveClass(/is-open/);
    const activation = await app.evaluate(({ app, BrowserWindow }) => ({
      dockVisible: app.dock?.isVisible(),
      windows: BrowserWindow.getAllWindows().map((win) => ({
        shelf: win.webContents.getURL().includes('mode=clipboard'),
        visible: win.isVisible(),
        focused: win.isFocused(),
        allSpaces: win.isVisibleOnAllWorkspaces(),
      })),
    }));
    assert.equal(
      activation.dockVisible,
      dockBefore,
      'First hover preserves the app activation policy',
    );
    assert(
      activation.windows.find((win) => win.shelf)?.focused,
      'First hover focuses the shelf for immediate keyboard navigation',
    );
    assert(
      activation.windows.filter((win) => !win.shelf).every((win) => !win.visible),
      'First hover does not reveal the workspace',
    );
    assert(activation.windows.find((win) => win.shelf)?.allSpaces);
    assert.equal(
      await panel.locator('input').evaluate((el) => el === document.activeElement),
      true,
    );
    await app.evaluate(() => {
      (globalThis as any).__qaCursor.y += 100;
      // Keep the pointer inside the shelf until explicitly dismissed.
    });
    const bounds = await app.evaluate(({ BrowserWindow, screen }) => {
      const win = BrowserWindow.getAllWindows().find((win) =>
        win.webContents.getURL().includes('mode=clipboard'),
      )!;
      return {
        id: win.id,
        bounds: win.getBounds(),
        display: screen.getDisplayMatching(win.getBounds()).bounds,
      };
    });
    assert.equal(
      bounds.bounds.y,
      bounds.display.y,
      'Shelf must cover the top edge, including the notch',
    );
    const layout = await root.evaluate((element) => {
      const css = getComputedStyle(element);
      const header = element.querySelector('.clipboard-header')!;
      return {
        background: css.backgroundColor,
        border: css.borderTopWidth,
        topLeft: css.borderTopLeftRadius,
        topRight: css.borderTopRightRadius,
        inset: css.getPropertyValue('--notch-inset'),
        headerTop: header.querySelector('h1')!.getBoundingClientRect().top,
        titleRight: header.querySelector('h1')!.getBoundingClientRect().right,
        actionsLeft: header.querySelector('.clipboard-header-actions')!.getBoundingClientRect()
          .left,
        actionsTop: header.querySelector('.clipboard-header-actions')!.getBoundingClientRect().top,
        notchLeft: (element.clientWidth - parseFloat(css.getPropertyValue('--notch-width'))) / 2,
        notchRight: (element.clientWidth + parseFloat(css.getPropertyValue('--notch-width'))) / 2,
        searchTop: element.querySelector('.clipboard-search')!.getBoundingClientRect().top,
        animation: css.animationName,
        duration: css.animationDuration,
      };
    });
    assert.equal(layout.background, 'rgb(0, 0, 0)');
    assert.equal(layout.border, '0px');
    assert.equal(layout.topLeft, '0px');
    assert.equal(layout.topRight, '0px');
    if (parseFloat(layout.inset) > 0) {
      assert(layout.headerTop < parseFloat(layout.inset), 'Title sits beside the notch');
      assert(layout.actionsTop < parseFloat(layout.inset), 'Controls sit beside the notch');
      assert(layout.titleRight < layout.notchLeft, 'Title stays clear of the camera');
      assert(layout.actionsLeft > layout.notchRight, 'Controls stay clear of the camera');
      assert(layout.searchTop >= parseFloat(layout.inset), 'Search stays below the camera');
    }
    assert.equal(layout.animation, 'clipboard-reveal');
    assert.equal(layout.duration, '0.2s');
    const visible = () =>
      app.evaluate(({ BrowserWindow }, id) => BrowserWindow.fromId(id)!.isVisible(), bounds.id);
    await expect
      .poll(() =>
        root.evaluate((element) =>
          element.getAnimations().some((animation) => animation.playState === 'running'),
        ),
      )
      .toBe(false);
    await mkdir('artifacts', { recursive: true });
    await panel.screenshot({ path: 'artifacts/clipboard-notch-black.png' });
    // Prolong only the exit animation so the intermediate closing state can be inspected.
    await panel.addStyleTag({
      content: '.clipboard-shelf.is-closed { animation-duration: 220ms; }',
    });
    await panel.evaluate(() => window.platform.call('clipboardHistory.hide'));
    await expect(root).toHaveClass(/is-closed/);
    assert(await visible(), 'Native window stays visible while the exit animation runs');
    await shell.evaluate(() => window.platform.call('clipboardHistory.show'));
    await expect(root).toHaveClass(/is-open/);
    await expect(panel.getByRole('combobox')).toBeFocused();
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert(await visible(), 'Reopening cancels the pending native hide');
    await panel.evaluate(() => window.platform.call('clipboardHistory.hide'));
    await expect.poll(visible).toBe(false);
    await shell.evaluate(() => window.platform.call('clipboardHistory.show'));
    await expect(root).toHaveClass(/is-open/);
    // Reduced motion keeps the same end states without the expansion/contraction.
    await panel.emulateMedia({ reducedMotion: 'reduce' });
    await panel.evaluate(() => window.platform.call('clipboardHistory.hide'));
    await expect.poll(visible).toBe(false);
    await shell.evaluate(() => window.platform.call('clipboardHistory.show'));
    await expect(root).toHaveClass(/is-open/);
    assert(
      Number.parseFloat(
        await root.evaluate((element) => getComputedStyle(element).animationDuration),
      ) <= 0.001,
    );
    assert(
      await root.evaluate((element) => {
        const bounds = element.getBoundingClientRect();
        return element.contains(document.elementFromPoint(bounds.width / 2, 100));
      }),
      'Reduced-motion shelf remains fully revealed',
    );
    console.log(
      'Notch shelf passed: first-hover activation/focus, keyboard focus, square top corners, screen-top geometry, black surface, safe controls, reveal/hide, quick reopening and reduced motion.',
    );
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
