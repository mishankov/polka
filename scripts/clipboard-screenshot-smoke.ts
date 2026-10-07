import { runDesktopTest, type DesktopTest } from './desktop-test';
import { clipboardContentType } from '../src/main/clipboard-history';
import { expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { join, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

async function main(test: DesktopTest) {
  const profile = test.profile;
  const app = await test.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  try {
    const shell = await app.firstWindow();
    await shell.locator('.launcher').waitFor();
    // Materialize the backup before changing the clipboard: read() items can be lazy.
    await test.backupClipboard(app);
    await test.clipboardReady(shell);
    const state = () => shell.evaluate(() => window.platform.call('clipboardHistory.state'));
    await shell.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', {
        hoverEnabled: false,
        pasteOnSelect: false,
      }),
    );
    const fixture = await app.evaluate(async ({ clipboard, ClipboardItem, nativeImage }) => {
      const bytes = Buffer.alloc(1800 * 1200 * 4);
      let random = 123456789;
      for (let i = 0; i < bytes.length; i++) {
        random ^= random << 13;
        random ^= random >>> 17;
        random ^= random << 5;
        bytes[i] = i % 4 === 3 ? 255 : random & 255;
      }
      const png = nativeImage.createFromBitmap(bytes, { width: 1800, height: 1200 }).toPNG();
      await clipboard.write([
        new ClipboardItem({ 'image/png': new Blob([new Uint8Array(png)], { type: 'image/png' }) }),
      ]);
      return png.length;
    });
    assert(fixture > 8 * 1024 * 1024 * 0.74, 'Fixture exceeds the old silent image cutoff');
    const types = await app.evaluate(async ({ clipboard }) =>
      (await clipboard.read()).map((item) => item.types),
    );
    const type = types.map(clipboardContentType).find((type) => type && type !== 'text/plain');
    assert(type && type !== 'text/plain', 'OS clipboard exposes the image fixture');
    const fixtureId = await app.evaluate(async ({ clipboard, nativeImage }, type) => {
      // macOS can expose TIFF or native PNG aliases after writing image/png.
      // Match the OS representation, including its canonical PNG encoding.
      const item = (await clipboard.read()).find((item) => item.types.includes(type));
      if (!item) throw Error('Image fixture disappeared from the OS clipboard');
      const blob = await item.getType(type);
      const bytes = Buffer.from(await (blob as Blob).arrayBuffer());
      const png = type === 'image/png' ? bytes : nativeImage.createFromBuffer(bytes).toPNG();
      const { createHash } = process.getBuiltinModule('crypto') as typeof import('node:crypto');
      return createHash('sha256')
        .update('image')
        .update('\0')
        .update(png.toString('base64'))
        .digest('hex');
    }, type);
    await test.keepClipboardFixture(shell, fixtureId);
    const large = (await state()).clips[0];
    assert.equal(large.kind, 'image');
    const preview = await shell.evaluate(
      (id) => window.platform.call<string>('clipboardHistory.preview', { id }),
      large.id,
    );
    const previewSize = await app.evaluate(
      ({ nativeImage }, data) => nativeImage.createFromDataURL(data).getSize(),
      preview,
    );
    assert.equal(
      previewSize.width,
      1000,
      'On-demand preview must use the original image, not the small list thumbnail',
    );
    assert(previewSize.height <= 700);
    await shell.evaluate((id) => window.platform.call('clipboardHistory.copy', { id }), large.id);
    const dimensions = await app.evaluate(async ({ clipboard, nativeImage }) => {
      const item = (await clipboard.read())[0];
      const data = await item.getType('image/png');
      return nativeImage.createFromBuffer(Buffer.from(await data.arrayBuffer())).getSize();
    });
    assert.deepEqual(dimensions, { width: 1800, height: 1200 });
    // Some screenshot previews carry both pixel data and a temporary file URL.
    await app.evaluate(async ({ clipboard, ClipboardItem, nativeImage }) => {
      const png = nativeImage
        .createFromBitmap(Buffer.alloc(32 * 32 * 4, 255), { width: 32, height: 32 })
        .toPNG();
      await clipboard.write([
        new ClipboardItem({
          'image/png': new Blob([new Uint8Array(png)], { type: 'image/png' }),
          'electron application/osclipboard;format="public.file-url"': new Blob([
            'file:///tmp/screenshot-qa.png',
          ]),
        }),
      ]);
    });
    await expect.poll(async () => (await state()).clips.length).toBe(2);
    // Oversize payloads must report a reason. Substitute only the clipboard reader so
    // the native change signal still exercises the real capture pipeline.
    await app.evaluate(async ({ clipboard, ClipboardItem }) => {
      const read = clipboard.read.bind(clipboard);
      (globalThis as any).__clipboardRead = read;
      clipboard.read = async () => [
        new ClipboardItem({
          'image/png': new Blob([new Uint8Array(33 * 1024 * 1024)], { type: 'image/png' }),
        }),
      ];
      await clipboard.writeText('Oversize image trigger');
    });
    await expect.poll(async () => (await state()).error || '').toContain('32 МБ');
    assert.equal((await state()).clips.length, 2);
    await app.evaluate(async ({ clipboard }) => {
      clipboard.read = (globalThis as any).__clipboardRead;
      await clipboard.writeText('Capture recovered after oversized image');
    });
    await expect.poll(async () => (await state()).clips.length).toBe(3);
    assert.equal((await state()).error, undefined);

    if (process.argv.includes('--native')) {
      const bounds = await app.evaluate(({ BrowserWindow }) => {
        const win = BrowserWindow.getAllWindows().find(
          (win) => !win.webContents.getURL().includes('mode='),
        )!;
        win.show();
        win.focus();
        return win.getBounds();
      });
      for (const format of ['png', 'tiff']) {
        await shell.evaluate(() => window.platform.call('clipboardHistory.clear'));
        await promisify(execFile)('/usr/sbin/screencapture', [
          '-x',
          '-c',
          '-t',
          format,
          '-R',
          `${bounds.x + 80},${bounds.y + 80},320,180`,
        ]);
        await expect
          .poll(
            async () => (await state()).clips.filter((clip: any) => clip.kind === 'image').length,
          )
          .toBe(1);
        assert.equal((await state()).error, undefined);
      }
    }
    console.log(
      'Screenshot regression passed: large image, full-resolution copy, companion file URL, visible size limit, recovery' +
        (process.argv.includes('--native') ? ', and native macOS PNG/TIFF screenshots.' : '.'),
    );
  } finally {
    await app
      .evaluate(({ clipboard }) => {
        if ((globalThis as any).__clipboardRead)
          clipboard.read = (globalThis as any).__clipboardRead;
      })
      .catch(() => {});
  }
}
runDesktopTest('clipboard-screenshot', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
