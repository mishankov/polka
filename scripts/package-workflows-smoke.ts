import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile, readdir } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { unzipSync, strFromU8 } from 'fflate';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-package-ui-'));
  await mkdir('artifacts', { recursive: true });
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  const page = await app.firstWindow();
  page.setDefaultTimeout(15000);
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.stack || error.message));
  const setSavePath = (path: string) =>
    app.evaluate(({ dialog }, filePath) => {
      dialog.showSaveDialog = async () => ({ canceled: false, filePath });
    }, path);
  const setOpenPath = (path: string) =>
    app.evaluate(({ dialog }, path) => {
      dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [path] });
    }, path);
  const openExport = async () => {
    await page.getByRole('button', { name: 'Приложение', exact: true }).click();
    await page.getByRole('menuitem', { name: 'Экспортировать…', exact: true }).click();
    await page.getByRole('dialog', { name: 'Экспорт · Обмен', exact: true }).waitFor();
  };
  try {
    await page.waitForSelector('.home-page');
    const source = await page.evaluate(async () => {
      const app = await window.platform.call<any>('apps.create', {
        definition: {
          schemaVersion: 1,
          name: 'Обмен',
          entities: [
            {
              id: 'items',
              name: 'Записи',
              fields: [{ id: 'name', name: 'Название', type: 'text' }],
            },
          ],
          screens: [{ id: 'items', name: 'Записи', type: 'table', entityId: 'items' }],
          actions: [],
          automations: [],
          extensions: [],
          permissions: ['clipboard.read'],
          connections: [{ id: 'source', name: 'Учётная запись примера', kind: 'account' }],
        },
      });
      await window.platform.call('apps.updateMeta', { appId: app.id, status: 'running' });
      await window.platform.call('records.upsert', {
        appId: app.id,
        entityId: 'items',
        values: { name: 'PRIVATE-PERSONAL-RECORD' },
      });
      return app;
    });
    await page.locator('.app-nav').filter({ hasText: 'Обмен' }).first().click();
    await page.getByText('PRIVATE-PERSONAL-RECORD', { exact: true }).waitFor();
    const baselinePath = join(profile, 'baseline.everyapp');
    await setSavePath(baselinePath);
    await openExport();
    assert.equal(
      await page
        .getByRole('checkbox', { name: 'Добавить отдельные демонстрационные данные' })
        .isChecked(),
      false,
    );
    await page.getByRole('button', { name: 'Сохранить файл приложения…' }).click();
    await page
      .getByRole('dialog', { name: 'Экспорт · Обмен', exact: true })
      .waitFor({ state: 'hidden' });
    const baseline = unzipSync(await readFile(baselinePath));
    assert.deepEqual(JSON.parse(strFromU8(baseline['data.json'])), []);
    assert.deepEqual(JSON.parse(strFromU8(baseline['demo-data.json'])), []);
    const demoPath = join(profile, 'demo.everyapp');
    await setSavePath(demoPath);
    await openExport();
    await page
      .getByRole('checkbox', { name: 'Добавить отдельные демонстрационные данные' })
      .check();
    await page.getByRole('button', { name: 'Демонстрационные записи', exact: true }).click();
    await page
      .locator('.cm-content')
      .fill(
        JSON.stringify([
          { id: 'example', entityId: 'items', values: { name: 'Синтетический пример' } },
        ]),
      );
    await page.getByRole('button', { name: 'Проверить и сохранить примеры' }).click();
    await page.getByText(/Состав файла: 0 личных записей · 1 демонстрационных/).waitFor();
    await page.screenshot({ path: 'artifacts/package-demo-export.png' });
    await page.getByRole('button', { name: 'Сохранить файл приложения…' }).click();
    await page
      .getByRole('dialog', { name: 'Экспорт · Обмен', exact: true })
      .waitFor({ state: 'hidden' });
    const demo = unzipSync(await readFile(demoPath));
    assert.deepEqual(JSON.parse(strFromU8(demo['data.json'])), []);
    assert.equal(JSON.parse(strFromU8(demo['demo-data.json'])).length, 1);
    assert(
      !Object.values(demo).some((bytes) => strFromU8(bytes).includes('PRIVATE-PERSONAL-RECORD')),
    );
    await setOpenPath(demoPath);
    await page.getByRole('button', { name: 'Приложения', exact: true }).click();
    await page.getByRole('button', { name: 'Открыть файл…', exact: true }).click();
    await page.getByRole('button', { name: 'Установить копию', exact: true }).waitFor();
    await page.getByText('1 демонстрационных', { exact: true }).waitFor();
    await page.screenshot({ path: 'artifacts/package-import-preview.png' });
    await page.getByRole('button', { name: 'Установить копию', exact: true }).click();
    await page.getByRole('dialog', { name: 'Приложение установлено', exact: true }).waitFor();
    await page.getByText('Учётная запись примера', { exact: true }).waitFor();
    await page.screenshot({ path: 'artifacts/package-import-report.png' });
    await page.getByRole('button', { name: 'Настроить доступ и связи', exact: true }).click();
    const access = page.getByRole('dialog', { name: 'Приложение · Обмен', exact: true });
    await access.waitFor();
    assert.equal(
      await access.getByRole('tab', { name: 'Доступ', exact: true }).getAttribute('aria-selected'),
      'true',
    );
    await access.getByRole('switch', { name: 'clipboard.read', exact: true }).waitFor();
    await page.screenshot({ path: 'artifacts/package-import-access.png' });
    await page.keyboard.press('Escape');
    await access.waitFor({ state: 'hidden' });
    await page.getByRole('button', { name: 'Открыть приложение', exact: true }).click();
    await page
      .getByRole('dialog', { name: 'Приложение установлено', exact: true })
      .waitFor({ state: 'hidden' });
    const imported = await page.evaluate(async (id) => {
      const apps = await window.platform.call<any[]>('apps.list');
      const app = apps.find((app) => app.id !== id)!;
      const rows = await window.platform.call<any>('records.list', {
        appId: app.id,
        entityId: 'items',
      });
      return { app, rows };
    }, source.id);
    assert.equal(imported.rows.records.length, 1);
    assert.equal(imported.rows.records[0].values.name, 'Синтетический пример');
    assert.equal(imported.app.status, 'stopped');

    // Exercise the visible cancellation control with actual incompressible attachment bytes.
    await page.keyboard.press('Escape');
    const attachmentPath = join(profile, 'random-fixture.bin');
    await writeFile(attachmentPath, randomBytes(16 * 1024 * 1024));
    await setOpenPath(attachmentPath);
    await page.evaluate(
      (id) => window.platform.call('attachments.choose', { appId: id }),
      imported.app.id,
    );
    const cancelPath = join(profile, 'cancelled.everyapp');
    await writeFile(cancelPath, 'original destination');
    await setSavePath(cancelPath);
    await openExport();
    await page.getByRole('combobox', { name: 'Что включить в файл', exact: true }).click();
    await page
      .getByRole('option', { name: 'Приложение с выбранными данными', exact: true })
      .click();
    await page
      .locator('.mantine-MultiSelect-root')
      .filter({ has: page.getByText('Дополнительные вложения', { exact: true }) })
      .locator('.mantine-MultiSelect-input')
      .click();
    await page.getByRole('option', { name: 'random-fixture.bin', exact: true }).click();
    await page.keyboard.press('Escape');
    await page.getByRole('button', { name: 'Сохранить файл приложения…' }).click();
    await page.getByRole('button', { name: 'Отменить обработку', exact: true }).click();
    await page.getByText(/^Отменено(?: · \d+%)?$/).waitFor();
    await expect(page.getByRole('button', { name: 'Сохранить файл приложения…' })).toBeEnabled();
    await expect(page.getByText('Не удалось выполнить действие', { exact: true })).toHaveCount(0);
    await page.screenshot({ path: 'artifacts/package-export-cancelled.png' });
    assert.equal(await readFile(cancelPath, 'utf8'), 'original destination');
    assert(!(await readdir(profile)).some((name) => name.endsWith('.tmp')));
    assert.deepEqual(errors, []);
    await writeFile(
      'artifacts/package-workflows-report.json',
      JSON.stringify(
        {
          ok: true,
          demoOptIn: true,
          personalDataExcluded: true,
          importReport: true,
          accessPanel: true,
          exportCancelled: true,
          rendererErrors: errors,
        },
        null,
        2,
      ),
    );
    console.log(
      'Package workflows passed: demo opt-in, template privacy, native dialog export/import, reconnection report/access panel, and real export cancellation.',
    );
  } catch (error) {
    await page.screenshot({ path: 'artifacts/package-failure.png' }).catch(() => {});
    throw error;
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
