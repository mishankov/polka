import {
  _electron as electron,
  expect,
  type ElectronApplication,
  type Page,
} from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { clipId } from '../src/main/clipboard-history';
import { DEFAULT_CLIPBOARD_PREFERENCES, type ClipboardState } from '../src/shared/clipboard';

async function main() {
  const root = await mkdtemp(join(tmpdir(), 'everything-sync-smoke-'));
  const apps: ElectronApplication[] = [];
  const errors: string[] = [];
  const launch = async (name: string) => {
    const env: Record<string, string> = { ...process.env, EVERYTHING_PROFILE: join(root, name) };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({ args: [resolve('.')], env });
    apps.push(app);
    app
      .context()
      .on('page', (page) => page.on('pageerror', (reason) => errors.push(reason.message)));
    const page = await app.firstWindow();
    await page.locator('.launcher').waitFor();
    await expect
      .poll(() =>
        page.evaluate(() =>
          window.platform
            .call<ClipboardState>('clipboardHistory.state')
            .then((state) => state.pasteAccess),
        ),
      )
      .not.toBe('unavailable');
    return { app, page };
  };
  const state = (page: Page) =>
    page.evaluate(() => window.platform.call<ClipboardState>('clipboardHistory.state'));
  try {
    const seed = await launch('seed');
    const contentA = 'History originally on Mac A';
    const contentB = 'History originally on Mac B';
    const png =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=';
    for (const [name, contents] of [
      ['a', [contentA]],
      ['b', [contentB]],
    ] as const) {
      const saved = {
        version: 1,
        preferences: {
          ...DEFAULT_CLIPBOARD_PREFERENCES,
          accelerator: '',
          hoverEnabled: false,
          pasteOnSelect: false,
        },
        clips: [
          ...contents.map((content) => ({
            id: clipId('text', content),
            kind: 'text',
            content,
            preview: content,
            createdAt: Date.now(),
            pinned: false,
          })),
          ...(name === 'a'
            ? [
                {
                  id: clipId('image', png),
                  kind: 'image',
                  content: png,
                  preview: `data:image/png;base64,${png}`,
                  createdAt: Date.now(),
                  pinned: false,
                },
              ]
            : []),
        ],
      };
      const encrypted = await seed.app.evaluate(
        ({ safeStorage }, saved) =>
          safeStorage.encryptString(JSON.stringify(saved)).toString('base64'),
        saved,
      );
      await mkdir(join(root, name, 'clipboard-history'), { recursive: true });
      await writeFile(
        join(root, name, 'clipboard-history/history.enc'),
        Buffer.from(encrypted, 'base64'),
      );
    }
    await seed.app.close();
    const a = await launch('a'),
      b = await launch('b');
    // Compare the active clipboard without writing test content to it.
    const counterBefore = await a.app.evaluate(({ clipboard }) => clipboard.readText());
    await a.page.evaluate(() =>
      window.platform.call('clipboardHistory.syncEnabled', { enabled: true }),
    );
    await b.page.evaluate(() =>
      window.platform.call('clipboardHistory.syncEnabled', { enabled: true }),
    );
    await expect
      .poll(async () => (await state(b.page)).sync?.nearby.length, { timeout: 20000 })
      .toBeGreaterThan(0);
    await a.page.evaluate(() => window.platform.call('clipboardHistory.syncInvite'));
    const code = (await state(a.page)).sync!.invitation!.code;
    // Exercise the real pairing form through the app, with actual backend calls.
    const settingsOpening = b.app.waitForEvent('window');
    await b.page.evaluate(() => window.platform.call('shelf.settings'));
    const settings = await settingsOpening;
    await settings.locator('.shelf-settings').waitFor();
    await settings.getByRole('tab', { name: 'Буфер обмена' }).click();
    await settings.getByLabel('Код с другого Mac', { exact: true }).fill(code);
    await settings.getByRole('button', { name: 'Связать Mac и объединить историю' }).click();
    await expect.poll(async () => (await state(b.page)).clips.length).toBe(3);
    await expect.poll(async () => (await state(a.page)).clips.length).toBe(3);
    await expect(settings.getByText('История синхронизирована', { exact: false })).toBeVisible();
    const idA = clipId('text', contentA);
    await b.page.evaluate(
      (id) => window.platform.call('clipboardHistory.pin', { id, pinned: true }),
      idA,
    );
    await expect
      .poll(async () => (await state(a.page)).clips.find((clip) => clip.id === idA)?.pinned)
      .toBe(true);
    await b.page.evaluate(() =>
      window.platform.call('clipboardHistory.syncEnabled', { enabled: false }),
    );
    await a.page.evaluate((id) => window.platform.call('clipboardHistory.remove', { id }), idA);
    assert((await state(b.page)).clips.some((clip) => clip.id === idA));
    await b.app.close();
    const bRestarted = await launch('b');
    await bRestarted.page.evaluate(() =>
      window.platform.call('clipboardHistory.syncEnabled', { enabled: true }),
    );
    await expect
      .poll(async () => (await state(bRestarted.page)).clips.some((clip) => clip.id === idA), {
        timeout: 20000,
      })
      .toBe(false);
    await a.page.evaluate(() => window.platform.call('clipboardHistory.clear'));
    await expect.poll(async () => (await state(bRestarted.page)).clips.length).toBe(0);
    assert.equal(await a.app.evaluate(({ clipboard }) => clipboard.readText()), counterBefore);
    assert.deepEqual(errors, []);
    console.log(
      'Clipboard sync smoke passed: Bonjour discovery, real pairing form, encrypted text/image history merge, pins, offline deletion, restart, shared clear and unchanged clipboard.',
    );
  } finally {
    for (const app of apps.reverse()) await app.close().catch(() => {});
    await rm(root, { recursive: true, force: true });
  }
}
void main();
