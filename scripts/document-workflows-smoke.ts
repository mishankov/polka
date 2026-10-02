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
            { id: 'convert', name: 'Преобразования', type: 'converter' },
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
    // Selection -> preview -> draft, without saving to disk.
    await page.locator('.cm-content').focus();
    await page.keyboard.press('Meta+a');
    await page.getByRole('button', { name: 'Преобразовать…', exact: true }).click();
    const modal = page.getByRole('dialog');
    await modal.getByRole('button', { name: 'Преобразовать', exact: true }).click();
    await modal.getByText('YWxwaGE=', { exact: true }).waitFor();
    await modal.getByRole('button', { name: 'Применить в черновик', exact: true }).click();
    await modal.getByRole('button', { name: 'Результат применён', exact: true }).waitFor();
    await page.screenshot({ path: 'artifacts/document-selection-preview.png' });
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('.cm-content').innerText(), 'YWxwaGE=');
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
    // Clipboard is explicitly user initiated, then a two-step reversible chain.
    await page.getByRole('tab', { name: 'Преобразования', exact: true }).click();
    await page.evaluate(() =>
      window.platform.call('documents.clipboardWrite', { text: 'cozy clipboard' }),
    );
    await page.getByRole('combobox', { name: 'Источник', exact: true }).click();
    await page.getByRole('option', { name: 'Буфер обмена', exact: true }).click();
    await page.getByRole('button', { name: 'Добавить шаг', exact: true }).click();
    await page.getByRole('combobox', { name: 'Шаг 2', exact: true }).click();
    await page.getByRole('option', { name: 'Base64 → текст', exact: true }).click();
    await page.getByRole('button', { name: 'Преобразовать', exact: true }).click();
    await page.getByRole('button', { name: 'Сохранить новым документом', exact: true }).waitFor();
    assert.equal(await page.locator('.cm-content').last().innerText(), 'cozy clipboard');
    await page.getByRole('button', { name: 'Сохранить новым документом', exact: true }).click();
    await page.getByRole('button', { name: 'Результат применён', exact: true }).waitFor();
    await page.screenshot({ path: 'artifacts/document-chain-preview.png' });
    // A selected file set uses the same typed chain and commits all drafts together.
    await page.getByRole('combobox', { name: 'Источник', exact: true }).click();
    await page.getByRole('option', { name: 'Набор открытых файлов', exact: true }).click();
    const choices = page.getByRole('combobox', { name: 'Документы', exact: true });
    await choices.focus();
    await page.keyboard.press('ArrowDown');
    await page.getByRole('option', { name: 'one.txt', exact: true }).click();
    await choices.focus();
    await page.keyboard.press('ArrowDown');
    await page.getByRole('option', { name: 'two.txt', exact: true }).click();
    await page.keyboard.press('Escape');
    await page.getByRole('button', { name: 'Удалить шаг 2', exact: true }).click();
    await page.getByRole('button', { name: 'Преобразовать', exact: true }).click();
    await page.getByRole('button', { name: 'Применить в черновик', exact: true }).waitFor();
    await page.getByRole('button', { name: 'Применить в черновик', exact: true }).click();
    await page.getByRole('button', { name: 'Результат применён', exact: true }).waitFor();
    const transformed = await page.evaluate(
      (id) => window.platform.call('docs.list', { appId: id }),
      instance.id,
    );
    assert.equal(transformed.find((d: any) => d.name === 'two.txt').content, 'YmV0YQ==');
    await page.screenshot({ path: 'artifacts/document-batch-preview.png' });

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
    // The same typed transformation registry handles image documents, previews and clipboard.
    await page.getByRole('button', { name: 'Преобразовать…', exact: true }).click();
    const imagePanel = page.getByRole('dialog');
    await imagePanel.getByRole('button', { name: 'Добавить шаг', exact: true }).click();
    await imagePanel.getByRole('combobox', { name: 'Шаг 2', exact: true }).click();
    await page.getByRole('option', { name: 'Изображение: изменить размер', exact: true }).click();
    await imagePanel
      .getByRole('textbox', { name: 'Параметры (JSON)', exact: true })
      .last()
      .fill('{"width":40,"height":50}');
    await imagePanel.getByRole('button', { name: 'Преобразовать', exact: true }).click();
    const imagePreview = imagePanel.getByRole('img', {
      name: 'Предпросмотр результата изображения',
      exact: true,
    });
    await imagePreview.waitFor();
    await page.waitForFunction(() => {
      const image = document.querySelector(
        'img[alt="Предпросмотр результата изображения"]',
      ) as HTMLImageElement;
      return image?.complete && image.naturalWidth === 40 && image.naturalHeight === 50;
    });
    await imagePanel.getByRole('button', { name: 'Копировать результат', exact: true }).click();
    await page.waitForFunction(async () => {
      try {
        const value = await window.platform.call('documents.clipboardRead', { kind: 'image' });
        return value.width === 40 && value.height === 50;
      } catch {
        return false;
      }
    });
    await imagePanel.getByRole('button', { name: 'Применить в черновик', exact: true }).click();
    await imagePanel.getByRole('button', { name: 'Результат применён', exact: true }).waitFor();
    await page.screenshot({ path: 'artifacts/document-image-chain-preview.png' });
    await page.keyboard.press('Escape');
    await page.waitForFunction(() => {
      const c = document.querySelector('canvas') as HTMLCanvasElement;
      return c?.width === 40 && c.height === 50;
    });

    // Image-chain results remain reachable from a text screen through shared document tabs.
    await page.getByRole('tab', { name: 'Текст', exact: true }).click();
    await page.getByRole('tab', { name: /Новый рисунок\.png/ }).click();
    await page.getByLabel('Холст растрового редактора').waitFor();
    await page.waitForFunction(() => {
      const c = document.querySelector('canvas') as HTMLCanvasElement;
      return c?.width === 40 && c.height === 50;
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
            'selection chain preview and apply',
            'native dropped File import',
            'clipboard chain',
            'selected file set preview and atomic draft apply',
            'image typed chain visual preview, native image clipboard, and draft apply',
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
