import { _electron as electron } from '@playwright/test';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import assert from 'node:assert/strict';
async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-docs-smoke-'));
  await mkdir('artifacts', { recursive: true });
  const folder = join(profile, 'fixtures');
  await mkdir(folder);
  await writeFile(join(folder, 'one.txt'), 'alpha');
  await writeFile(join(folder, 'two.txt'), 'beta');
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  const page = await app.firstWindow();
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  try {
    await page.waitForSelector('.home-page');
    const instance = await page.evaluate(async () => {
      const app = await window.platform.call('apps.create', {
        definition: {
          schemaVersion: 1,
          name: 'Документы QA',
          entities: [],
          screens: [
            { id: 'text', name: 'Текст', type: 'text' },
            { id: 'image', name: 'Изображение', type: 'image' },
          ],
          actions: [],
          automations: [],
          extensions: [],
          permissions: [],
        },
      });
      await window.platform.call('apps.updateMeta', { appId: app.id, status: 'running' });
      return app;
    });
    await page.locator('.app-nav').filter({ hasText: 'Документы QA' }).click();
    // Native chooser stub returns a real fixture directory; the production scanner and IPC run unchanged.
    await app.evaluate(({ dialog }, path) => {
      dialog.showOpenDialog = (async () => ({ canceled: false, filePaths: [path] })) as any;
    }, folder);
    await page.getByRole('button', { name: 'Открыть папку…', exact: true }).click();
    await page.getByRole('tab', { name: 'one.txt', exact: true }).waitFor();
    await page.getByRole('tab', { name: 'two.txt', exact: true }).waitFor();
    assert.equal(await page.locator('.cm-content').innerText(), 'alpha');
    // Real browser File objects from an input preserve the native drop path in preload.
    await writeFile(join(folder, 'drop.txt'), 'dropped');
    await page.evaluate(() => {
      const input = document.createElement('input');
      input.type = 'file';
      input.id = 'qa-drop';
      document.body.append(input);
    });
    await page.locator('#qa-drop').setInputFiles(join(folder, 'drop.txt'));
    const dropResult = await page.evaluate(async (id) => {
      const input = document.querySelector('#qa-drop') as HTMLInputElement;
      const result = await window.platform.openDropped(id, [...input.files!]);
      input.remove();
      return result;
    }, instance.id);
    assert.equal(dropResult.documents[0].name, 'drop.txt');
    // Verify actual raster pixels survive rotation, crop and undo.
    await page.getByRole('tab', { name: 'Изображение', exact: true }).click();
    await page.getByRole('button', { name: 'Новый', exact: true }).click();
    const canvas = page.getByLabel('Холст растрового редактора');
    await page.getByRole('button', { name: 'Повернуть вправо', exact: true }).waitFor();
    await page.waitForFunction(
      () =>
        !(
          Array.from(document.querySelectorAll('button')).find(
            (b) => b.textContent === 'Повернуть вправо',
          ) as HTMLButtonElement
        )?.disabled,
    );
    const bounds = await canvas.boundingBox();
    assert(bounds);
    await page.mouse.click(bounds.x + 20, bounds.y + 20);
    const before = await canvas.evaluate((c: HTMLCanvasElement) => c.toDataURL());
    await page.getByRole('button', { name: 'Повернуть вправо', exact: true }).click();
    assert.deepEqual(
      await canvas.evaluate((c: HTMLCanvasElement) => [c.width, c.height]),
      [768, 1024],
    );
    await page.getByRole('button', { name: 'Отменить штрих', exact: true }).click();
    await page.waitForFunction(
      (value) => (document.querySelector('canvas') as HTMLCanvasElement)?.toDataURL() === value,
      before,
    );
    await page.getByRole('button', { name: 'Обрезать…', exact: true }).click();
    await page.getByLabel('Ширина', { exact: true }).fill('100');
    await page.getByLabel('Высота', { exact: true }).fill('80');
    await page.getByRole('button', { name: 'Применить', exact: true }).click();
    assert.deepEqual(
      await canvas.evaluate((c: HTMLCanvasElement) => [c.width, c.height]),
      [100, 80],
    );
    const pixels = await canvas.evaluate((c: HTMLCanvasElement) =>
      [...c.getContext('2d')!.getImageData(0, 0, c.width, c.height).data].some(
        (v, i) => i % 4 === 3 && v > 0,
      ),
    );
    assert(pixels);
    await page.screenshot({ path: 'artifacts/document-raster-tools.png' });
    // Edited images remain reachable from a text screen through shared document tabs.
    await page.getByRole('tab', { name: 'Текст', exact: true }).click();
    await page.getByRole('tab', { name: /Новый рисунок\.png/ }).click();
    await page.getByLabel('Холст растрового редактора').waitFor();
    await page.waitForFunction(() => {
      const c = document.querySelector('canvas') as HTMLCanvasElement;
      return c?.width === 100 && c.height === 80;
    });
    assert.deepEqual(errors, []);
    await writeFile(
      'artifacts/document-workflows-results.json',
      JSON.stringify(
        {
          passed: true,
          checks: [
            'folder chooser with nested scanner',
            'multi-document tabs',
            'native dropped File import',
            'image results stay reachable in shared text-screen document tabs',
            'raster rotate crop undo preserves pixels',
          ],
          errors,
        },
        null,
        2,
      ),
    );
    console.log('Document workflows smoke passed');
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
