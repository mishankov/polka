import { expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { mkdir, writeFile, rename, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { runDesktopTest } from './desktop-test';

void runDesktopTest('file-shelf', async (test) => {
  const paths = [
    join(test.profile, 'План поездки.txt'),
    join(test.profile, 'Договор.pdf'),
    join(test.profile, 'Фотографии'),
  ];
  await writeFile(paths[0], 'Synthetic travel plan');
  await writeFile(paths[1], '%PDF-1.4\nSynthetic file shelf fixture');
  await mkdir(paths[2]);
  const app = await test.launch({ args: [resolve('.'), '--disable-gpu'] });
  const page = await app.firstWindow();
  await page.waitForLoadState();
  await page.evaluate(() => window.platform.call('shelf.showFiles'));
  await expect(page.getByRole('heading', { name: 'Файлы на полке' })).toBeVisible();
  await expect(page.getByText('Оставьте файлы здесь')).toBeVisible();
  // Native file-backed File objects cross the real preload boundary on a renderer drop.
  await page.evaluate(() => {
    const input = document.createElement('input');
    input.type = 'file';
    input.multiple = true;
    input.id = 'file-drop-fixture';
    input.style.display = 'none';
    document.body.append(input);
  });
  await page.locator('#file-drop-fixture').setInputFiles(paths.slice(0, 2));
  await page.evaluate(() => {
    const input = document.querySelector<HTMLInputElement>('#file-drop-fixture')!;
    const transfer = new DataTransfer();
    for (const file of input.files!) transfer.items.add(file);
    document
      .querySelector('main')!
      .dispatchEvent(new DragEvent('drop', { bubbles: true, dataTransfer: transfer }));
  });
  await page.evaluate(
    (path) => window.platform.call('shelf.files.add', { paths: [path] }),
    paths[2],
  );
  await expect(page.locator('.file-shelf-row')).toHaveCount(3);
  await page.getByRole('button', { name: 'План поездки.txt', exact: true }).click();
  await page
    .getByRole('button', { name: 'Договор.pdf', exact: true })
    .click({ modifiers: ['Meta'] });
  await expect(page.getByText('Выбрано: 2')).toBeVisible();
  const artifacts = resolve('artifacts/issue-12');
  await mkdir(artifacts, { recursive: true });
  const capture = async (name: string) => {
    if (process.env.POLKA_NATIVE_SCREENSHOTS === '1') {
      const bounds = await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .find((win) => win.webContents.getURL().includes('mode=shelf'))!
          .getBounds(),
      );
      execFileSync('screencapture', [
        '-x',
        '-R' + [bounds.x, bounds.y, bounds.width, bounds.height].join(','),
        join(artifacts, name),
      ]);
      return;
    }
    const png = await app.evaluate(async ({ BrowserWindow }) => {
      const win = BrowserWindow.getAllWindows().find((win) =>
        win.webContents.getURL().includes('mode=shelf'),
      )!;
      return (await win.webContents.capturePage()).toPNG().toString('base64');
    });
    await writeFile(join(artifacts, name), Buffer.from(png, 'base64'));
  };
  await capture('file-shelf-selected.png');
  // Verify the real renderer drag gesture requests the complete selected ID set.
  await app.evaluate(({ BrowserWindow }) => {
    const win = BrowserWindow.getAllWindows().find((win) =>
      win.webContents.getURL().includes('mode=shelf'),
    )!;
    win.webContents.startDrag = (item) => {
      (globalThis as any).__fileDrag = item.files;
    };
  });
  await page.evaluate(() => {
    document
      .querySelector('.file-shelf-item')!
      .dispatchEvent(new DragEvent('dragstart', { bubbles: true }));
  });
  await expect
    .poll(() => app.evaluate(() => (globalThis as any).__fileDrag))
    .toEqual(paths.slice(0, 2));
  await page.evaluate(() => window.platform.call('launcher.hide'));
  await test.shelfHidden(app, page);
  // Reopen after switching apps: references survive closing, search and clipboard navigation.
  await page.evaluate(() => window.platform.call('launcher.show', { destination: 'apps' }));
  await expect(page.getByRole('combobox')).toBeFocused();
  await page.evaluate(() => window.platform.call('clipboardHistory.show'));
  await expect(page.getByRole('combobox', { name: 'Найти в истории' })).toBeVisible();
  await page.evaluate(() => window.platform.call('shelf.showFiles'));
  await expect(page.locator('.file-shelf-row')).toHaveCount(3);
  await rename(paths[0], join(test.profile, 'Переименованный план.txt'));
  await expect(page.getByText('Перемещён, удалён или недоступен', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'План поездки.txt', exact: true })).toHaveAttribute(
    'draggable',
    'false',
  );
  await capture('file-shelf-unavailable.png');
  await page.getByRole('button', { name: 'Убрать План поездки.txt с полки' }).click();
  await expect(page.locator('.file-shelf-row')).toHaveCount(2);
  await page.getByRole('button', { name: 'Очистить полку' }).click();
  await expect(page.locator('.file-shelf-row')).toHaveCount(0);
  expect(await readFile(paths[1], 'utf8')).toContain('Synthetic');
  expect(await readFile(join(test.profile, 'Переименованный план.txt'), 'utf8')).toBe(
    'Synthetic travel plan',
  );
  await test.close(app, true);
})
  .then(() => console.log('File shelf workflow passed.'))
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
