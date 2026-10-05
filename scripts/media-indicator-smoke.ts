import { _electron as electron, expect } from '@playwright/test';
import { build } from 'esbuild';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import assert from 'node:assert/strict';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-media-'));
  const entry = join(profile, 'fixture.cjs');
  await build({
    entryPoints: [resolve('scripts/media-indicator-fixture.ts')],
    outfile: entry,
    bundle: true,
    platform: 'node',
    format: 'cjs',
    external: ['electron'],
  });
  const launch = () =>
    electron.launch({
      args: [entry],
      env: { ...process.env, EVERYTHING_PROFILE: profile, EVERYTHING_TEST_ROOT: resolve('.') },
    });
  let app = await launch();
  const errors: string[] = [];
  try {
    const target = await app.firstWindow();
    await expect(target.getByRole('textbox', { name: 'Typing target' })).toBeFocused();
    await expect.poll(() => app.evaluate(() => !!(globalThis as any).mediaTest)).toBe(true);
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('active', 'inactive'));
    await expect
      .poll(() => app.windows().some((page) => page.url().includes('media-indicator.html')))
      .toBe(true);
    const overlay = app.windows().find((page) => page.url().includes('media-indicator.html'))!;
    overlay.on('pageerror', (error) => errors.push(error.message));
    const indicator = overlay.locator('.media-indicator');
    await expect(indicator).toHaveAttribute('data-mode', 'camera');
    assert.equal(
      await overlay.locator('.media-rim').evaluate((el) => getComputedStyle(el).backgroundColor),
      'rgb(255, 81, 78)',
    );
    assert.equal(await overlay.evaluate(() => typeof window.platform), 'undefined');
    await expect(target.getByRole('textbox')).toBeFocused();
    await target.getByRole('textbox').fill('Focus stays here');
    const flags = await app.evaluate(({ BrowserWindow }) => {
      const win = BrowserWindow.getAllWindows().find((win) =>
        win.webContents.getURL().includes('media-indicator.html'),
      )!;
      return {
        focused: win.isFocused(),
        focusable: win.isFocusable(),
        protected: win.isContentProtected(),
        onTop: win.isAlwaysOnTop(),
        allSpaces: win.isVisibleOnAllWorkspaces(),
      };
    });
    assert.deepEqual(flags, {
      focused: false,
      focusable: false,
      protected: true,
      onTop: true,
      allSpaces: true,
    });
    const visible = () =>
      app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .filter((win) => win.webContents.getURL().includes('media-indicator.html'))
          .some((win) => win.isVisible()),
      );
    await app.evaluate(() => (globalThis as any).mediaTest.target.hide());
    assert.equal(await visible(), true);
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('active', 'active'));
    await expect(indicator).toHaveAttribute('data-mode', 'both');
    await expect(indicator).toHaveAttribute('data-notched', 'true');
    await overlay.screenshot({ path: '/tmp/everything-media-both.png', omitBackground: true });
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('inactive', 'active'));
    await expect(indicator).toHaveAttribute('data-mode', 'microphone');
    await expect(overlay.locator('.media-camera')).toHaveCount(0);
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('active', 'active'));
    await app.evaluate(() => (globalThis as any).mediaTest.indicator.setTracking('camera', false));
    await expect(indicator).toHaveAttribute('data-mode', 'microphone');
    await expect(overlay.locator('.media-camera')).toHaveCount(0);
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('active', 'inactive'));
    await expect.poll(visible).toBe(false);
    await app.evaluate(() => (globalThis as any).mediaTest.indicator.setTracking('camera', true));
    await app.evaluate(() =>
      (globalThis as any).mediaTest.indicator.setTracking('microphone', false),
    );
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('active', 'unknown'));
    await expect(indicator).toHaveAttribute('data-mode', 'camera');
    await expect(overlay.locator('.media-microphone')).toHaveCount(0);
    await expect(indicator).not.toHaveAttribute('data-unknown');
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('inactive', 'active'));
    await expect.poll(visible).toBe(false);
    await app.evaluate(() =>
      (globalThis as any).mediaTest.indicator.setTracking('microphone', true),
    );
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('inactive', 'inactive'));
    await expect.poll(visible).toBe(false);
    await app.evaluate(() =>
      (globalThis as any).mediaTest.setActivity('inactive', 'inactive', true),
    );
    await expect(indicator).toHaveAttribute('data-mode', 'unknown');
    await expect.poll(visible).toBe(true);
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('active', 'unknown'));
    await expect(indicator).toHaveAttribute('data-mode', 'camera');
    await expect(overlay.locator('.media-microphone')).toHaveAttribute('data-state', 'unknown');
    await app.evaluate(() => (globalThis as any).mediaTest.setNotched(false));
    await expect(indicator).not.toHaveAttribute('data-notched');
    await overlay.screenshot({ path: '/tmp/everything-media-no-notch.png', omitBackground: true });
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('active', 'active'));
    await expect(indicator).toHaveAttribute('data-mode', 'both');
    await overlay.screenshot({
      path: '/tmp/everything-media-no-notch-both.png',
      omitBackground: true,
    });
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('active', 'inactive'));
    await expect(overlay.locator('.media-microphone')).toHaveCount(0);
    await overlay.screenshot({
      path: '/tmp/everything-media-no-notch-camera.png',
      omitBackground: true,
    });
    await app.evaluate(() => {
      const t = (globalThis as any).mediaTest;
      t.indicator.suspend('sleep');
      t.indicator.suspend('lock');
    });
    assert.equal(await visible(), false);
    await app.evaluate(() => (globalThis as any).mediaTest.indicator.resume('sleep'));
    assert.equal(await visible(), false);
    await app.evaluate(() => (globalThis as any).mediaTest.indicator.resume('lock'));
    await expect.poll(visible).toBe(true);
    await app.evaluate(async () => {
      const t = (globalThis as any).mediaTest;
      t.target.show();
      await new Promise<void>((resolve) => {
        t.target.once('enter-full-screen', resolve);
        t.target.setFullScreen(true);
      });
    });
    await expect
      .poll(() => app.evaluate(() => (globalThis as any).mediaTest.target.isFullScreen()))
      .toBe(true);
    assert.equal(await visible(), true);
    // Only attempt OS capture if permission is already available; don't prompt during tests.
    const captureRegion = () =>
      app.evaluate(async ({ systemPreferences, desktopCapturer, screen, BrowserWindow }) => {
        if (systemPreferences.getMediaAccessStatus('screen') !== 'granted') return null;
        const display = screen.getPrimaryDisplay();
        const sources = await desktopCapturer.getSources({
          types: ['screen'],
          thumbnailSize: { width: display.size.width, height: display.size.height },
        });
        const thumbnail = sources.find(
          (source) => source.display_id === String(display.id),
        )?.thumbnail;
        if (!thumbnail || thumbnail.isEmpty()) return null;
        const win = BrowserWindow.getAllWindows().find((win) =>
          win.webContents.getURL().includes('media-indicator.html'),
        )!;
        const bounds = win.getBounds();
        const scale = thumbnail.getSize().width / display.size.width;
        const cropped = thumbnail.crop({
          x: Math.round((bounds.x - display.bounds.x) * scale),
          y: Math.round((bounds.y - display.bounds.y) * scale),
          width: Math.round(bounds.width * scale),
          height: Math.round(bounds.height * scale),
        });
        const bitmap = cropped.toBitmap();
        let redPixels = 0;
        for (let i = 0; i < bitmap.length; i += 4)
          if (bitmap[i + 2] > 180 && bitmap[i + 1] < 130 && bitmap[i] < 140) redPixels++;
        return { image: cropped.toDataURL(), redPixels, bounds };
      });
    await target.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
    );
    const protectedCapture = await captureRegion();
    await app.evaluate(({ BrowserWindow }) => {
      for (const win of BrowserWindow.getAllWindows())
        if (win.webContents.getURL().includes('media-indicator.html'))
          win.setContentProtection(false);
    });
    await target.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
    );
    const unprotectedCapture = await captureRegion();
    await app.evaluate(({ BrowserWindow }) => {
      for (const win of BrowserWindow.getAllWindows())
        if (win.webContents.getURL().includes('media-indicator.html'))
          win.setContentProtection(true);
    });
    for (const [name, capture] of [
      ['protected', protectedCapture],
      ['unprotected', unprotectedCapture],
    ] as const) {
      if (capture)
        await writeFile(
          `/tmp/everything-media-capture-${name}.png`,
          Buffer.from(capture.image.split(',')[1], 'base64'),
        );
    }
    console.log('OS capture comparison (red pixels):', {
      protected: protectedCapture?.redPixels,
      unprotected: unprotectedCapture?.redPixels,
      bounds: protectedCapture?.bounds,
    });
    await app.evaluate(
      () =>
        new Promise<void>((resolve) => {
          const target = (globalThis as any).mediaTest.target;
          target.once('leave-full-screen', resolve);
          target.setFullScreen(false);
        }),
    );
    await expect
      .poll(() => app.evaluate(() => (globalThis as any).mediaTest.target.isFullScreen()))
      .toBe(false);
    await app.evaluate(() => (globalThis as any).mediaTest.indicator.setEnabled(false));
    assert.equal(await visible(), false);
    await app.close();
    app = await launch();
    await expect
      .poll(() => app.evaluate(() => (globalThis as any).mediaTest?.indicator.state().enabled))
      .toBe(false);
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('active', 'active'));
    assert.equal(await visible(), false);
    await app.evaluate(() => (globalThis as any).mediaTest.indicator.setEnabled(true));
    await expect.poll(visible).toBe(true);
    // Concurrent updates must preserve the other device's most recently saved choice.
    await app.evaluate(async () => {
      const indicator = (globalThis as any).mediaTest.indicator;
      await Promise.all([
        indicator.setTracking('camera', false),
        indicator.setTracking('microphone', false),
      ]);
      await indicator.setTracking('microphone', true);
    });
    await app.close();
    app = await launch();
    await expect
      .poll(() =>
        app.evaluate(() => (globalThis as any).mediaTest?.indicator.state().cameraEnabled),
      )
      .toBe(false);
    assert.equal(
      await app.evaluate(() => (globalThis as any).mediaTest.indicator.state().microphoneEnabled),
      true,
    );
    await app.evaluate(() => (globalThis as any).mediaTest.setActivity('active', 'active'));
    await expect.poll(visible).toBe(true);
    const reopenedOverlay = app
      .windows()
      .find((page) => page.url().includes('media-indicator.html'))!;
    await expect(reopenedOverlay.locator('.media-indicator')).toHaveAttribute(
      'data-mode',
      'microphone',
    );
    await expect(reopenedOverlay.locator('.media-camera')).toHaveCount(0);
    assert.deepEqual(errors, []);
    console.log(
      `Media smoke passed: transitions, unknown/recovery, focus, protection flags, shelf independence, no-notch fallback, sleep/lock, fullscreen window visibility and persisted preference. OS capture: ${protectedCapture ? 'cropped comparison saved for inspection' : 'not tested; screen permission unavailable'}.`,
    );
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
