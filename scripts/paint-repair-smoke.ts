import { _electron as electron } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

async function main() {
  const definition = JSON.parse(
    await readFile('artifacts/paint-repair/definition.repaired.json', 'utf8'),
  );
  const profile = await mkdtemp(join(tmpdir(), 'everything-paint-repair-'));
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  const errors: string[] = [];
  try {
    const shell = await app.firstWindow();
    shell.on('pageerror', (error) => errors.push(error.message));
    await shell.waitForSelector('.home-page');
    const instance = await shell.evaluate(async (definition) => {
      const instance = await window.platform.call('apps.create', { definition });
      await window.platform.call('apps.updateMeta', { appId: instance.id, status: 'running' });
      return instance;
    }, definition);
    const open = async () => {
      const opened = app.context().waitForEvent('page');
      await shell.locator('.app-nav').filter({ hasText: 'Простой Paint' }).first().click();
      const view = await opened;
      view.on('pageerror', (error) => errors.push(error.message));
      await view.locator('canvas').waitFor();
      return view;
    };
    let view = await open();
    await view.getByRole('textbox', { name: 'Название рисунка' }).fill('Проверка рисунка');
    const canvas = view.locator('canvas');
    const box = await canvas.boundingBox();
    assert(box);
    await view.mouse.move(box.x + 50, box.y + 60);
    await view.mouse.down();
    await view.mouse.move(box.x + 170, box.y + 140, { steps: 12 });
    await view.mouse.up();
    const pixels = () =>
      view.locator('canvas').evaluate((canvas: HTMLCanvasElement) => canvas.toDataURL());
    const drawn = await pixels();
    await view.getByRole('button', { name: 'Сохранить', exact: true }).click();
    await shell.waitForFunction(async (appId) => {
      const result = await window.platform.call('records.list', { appId, entityId: 'drawings' });
      return result.total === 1;
    }, instance.id);
    const first = await shell.evaluate(
      (appId) => window.platform.call('records.list', { appId, entityId: 'drawings' }),
      instance.id,
    );
    assert.equal(first.records[0].values.name, 'Проверка рисунка');
    assert.equal(first.records[0].values.data.length, 1);
    assert(first.records[0].values.data[0].points.length > 1);
    const closed = view.waitForEvent('close');
    await shell.reload();
    await closed;
    await shell.waitForSelector('.home-page');
    view = await open();
    assert.notEqual(await pixels(), drawn, 'new screen starts with blank canvas');
    await view.getByRole('combobox', { name: 'Открыть', exact: true }).click();
    await view.getByRole('option', { name: 'Проверка рисунка', exact: true }).click();
    await view.waitForFunction(
      (expected) =>
        (document.querySelector('canvas') as HTMLCanvasElement).toDataURL() === expected,
      drawn,
    );
    assert.equal(
      await view.getByRole('textbox', { name: 'Название рисунка' }).inputValue(),
      'Проверка рисунка',
    );
    await view.getByRole('textbox', { name: 'Название рисунка' }).fill('Обновлённый рисунок');
    await view.getByRole('button', { name: 'Сохранить', exact: true }).click();
    await shell.waitForFunction(async (appId) => {
      const result = await window.platform.call('records.list', { appId, entityId: 'drawings' });
      return result.total === 1 && result.records[0].values.name === 'Обновлённый рисунок';
    }, instance.id);
    const after = await shell.evaluate(
      (appId) => window.platform.call('records.list', { appId, entityId: 'drawings' }),
      instance.id,
    );
    assert.equal(after.records[0].id, first.records[0].id);
    assert.deepEqual(after.records[0].values.data, first.records[0].values.data);
    assert.deepEqual(errors, []);
    await view.screenshot({ path: 'artifacts/paint-repair/repaired-canvas.png' });
    await writeFile(
      'artifacts/paint-repair/smoke.json',
      JSON.stringify(
        {
          passed: true,
          checks: [
            'isolated extension renders',
            'pointer drawing',
            'save strokes',
            'reload persistence',
            'saved drawing title',
            'reopen exact canvas pixels',
            'update same record preserving strokes',
          ],
          errors,
        },
        null,
        2,
      ),
    );
    console.log('Paint repair smoke passed');
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
