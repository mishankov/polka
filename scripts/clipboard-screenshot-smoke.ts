import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-screenshot-'));
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  try {
    const shell = await app.firstWindow();
    await shell.locator('.launcher').waitFor();
    // Materialize the backup before changing the clipboard: read() items can be lazy.
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
    await new Promise((resolve) => setTimeout(resolve, 700));
    const state = () => shell.evaluate(() => window.platform.call('clipboardHistory.state'));
    await shell.evaluate(() =>
      window.platform.call('clipboardHistory.preferences', {
        hoverEnabled: false,
        pasteOnSelect: false,
      }),
    );
    const fixtureBytes = await app.evaluate(async ({ clipboard, ClipboardItem, nativeImage }) => {
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
    assert(fixtureBytes > 8 * 1024 * 1024 * 0.74, 'Fixture exceeds the old silent image cutoff');
    await expect.poll(async () => (await state()).clips.length).toBe(1);
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
      .evaluate(async ({ clipboard }) => {
        if ((globalThis as any).__clipboardRead)
          clipboard.read = (globalThis as any).__clipboardRead;
        const items = (globalThis as any).__clipboardBackup;
        if (items) {
          if (items.length) await clipboard.write(items);
          else clipboard.clear();
        }
      })
      .catch(() => {});
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
