import { runDesktopTest, type DesktopTest } from './desktop-test';
import { expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';

async function main(test: DesktopTest) {
  const profile = test.profile;
  const app = await test.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  {
    const shell = await app.firstWindow();
    await shell.locator('.launcher').waitFor();
    await test.clipboardReady(shell);
    // Reopen through hover without changing the Dock activation policy.
    await shell.evaluate(() => window.platform.call('launcher.hide'));
    const dockBefore = await app.evaluate(({ app, BrowserWindow, screen }) => {
      for (const win of BrowserWindow.getAllWindows()) win.hide();
      (globalThis as any).__realCursor = screen.getCursorScreenPoint;
      const { bounds } = screen.getPrimaryDisplay();
      (globalThis as any).__qaCursor = { x: bounds.x, y: bounds.y + 500 };
      screen.getCursorScreenPoint = () => (globalThis as any).__qaCursor;
      return app.dock?.isVisible();
    });
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal(dockBefore, false, 'The running app stays out of the Dock');
    const opening = Promise.resolve(shell);
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
        shelf: win.webContents.getURL().includes('mode=shelf'),
        indicator: win.webContents.getURL().includes('media-indicator.html'),
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
      activation.windows.filter((win) => !win.shelf && !win.indicator).every((win) => !win.visible),
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
        win.webContents.getURL().includes('mode=shelf'),
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
      const input = element.querySelector('input')!;
      const inputCSS = getComputedStyle(input);
      const focusOutset = Math.max(
        0,
        parseFloat(inputCSS.outlineWidth) + parseFloat(inputCSS.outlineOffset),
      );
      return {
        background: css.backgroundColor,
        border: css.borderTopWidth,
        topLeft: css.borderTopLeftRadius,
        topRight: css.borderTopRightRadius,
        inset: css.getPropertyValue('--notch-inset'),
        focusTop: input.getBoundingClientRect().top - focusOutset,
        animation: css.animationName,
        duration: css.animationDuration,
      };
    });
    assert.equal(layout.background, 'rgb(0, 0, 0)');
    assert.equal(layout.border, '0px');
    assert.equal(layout.topLeft, '0px');
    assert.equal(layout.topRight, '0px');
    if (parseFloat(layout.inset) > 0) {
      assert(
        layout.focusTop >= parseFloat(layout.inset) + 8,
        'The full focus ring has breathing room below the camera',
      );
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
    // The shelf is visually part of the notch, regardless of the system theme.
    for (const appearance of ['light', 'dark'] as const) {
      await app.evaluate(({ nativeTheme }, appearance) => {
        nativeTheme.themeSource = appearance;
      }, appearance);
      await expect(panel.locator('html')).toHaveAttribute('data-appearance', appearance);
      for (const method of ['launcher.show', 'clipboardHistory.show']) {
        await panel.evaluate((method) => window.platform.call(method), method);
        await expect(panel.getByRole('combobox')).toBeFocused();
        const surfaces = await panel
          .locator('.clipboard-shelf, .clipboard-search, .clipboard-header')
          .evaluateAll((elements) =>
            elements.map((element) => getComputedStyle(element).backgroundColor),
          );
        assert(surfaces.length >= 2);
        assert(
          surfaces.every((color) => color === 'rgb(0, 0, 0)'),
          `${method} stays black in ${appearance} mode`,
        );
        assert.equal(
          await root.evaluate((element) => getComputedStyle(element).colorScheme),
          'dark',
        );
      }
    }
    console.log(
      'Notch shelf passed: first-hover activation/focus, keyboard focus, square top corners, screen-top geometry, permanent black launcher and clipboard in both system themes, safe controls, reveal/hide, quick reopening and reduced motion.',
    );
  }
}
runDesktopTest('clipboard-animation', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
