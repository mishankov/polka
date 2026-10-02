import { _electron as electron } from '@playwright/test';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import assert from 'node:assert/strict';
async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-smoke-'));
  await mkdir('artifacts', { recursive: true });
  const launch = () =>
    electron.launch({
      ...(process.env.EVERYTHING_EXECUTABLE
        ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
        : { args: [resolve('.')] }),
      env: { ...process.env, EVERYTHING_PROFILE: profile },
    });
  let app = await launch();
  let page = await app.firstWindow();
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.stack || e.message));
  const logs: string[] = [];
  app.process().stderr?.on('data', (b) => logs.push(b.toString()));
  try {
    await page.waitForSelector('.home-page');
    await page.screenshot({ path: 'artifacts/home.png' });
    const definition = {
      schemaVersion: 1,
      name: 'Проверка',
      entities: [
        {
          id: 'items',
          name: 'Записи',
          fields: [{ id: 'title', name: 'Название', type: 'text', required: true }],
        },
      ],
      screens: [
        { id: 'items', name: 'Записи', type: 'table', entityId: 'items' },
        { id: 'text', name: 'Текст', type: 'text' },
        { id: 'image', name: 'Изображение', type: 'image' },
        { id: 'convert', name: 'Преобразования', type: 'converter' },
        { id: 'custom', name: 'Расширение', type: 'custom', config: { extensionId: 'hello' } },
      ],
      actions: [],
      automations: [],
      extensions: [
        {
          id: 'hello',
          name: 'React',
          kind: 'component',
          source: 'export default function(){return <h2>Изолированный React работает</h2>}',
        },
      ],
      permissions: [],
    };
    const instance = await page.evaluate(async (d) => {
      const app = await window.platform.call('apps.create', { definition: d });
      await window.platform.call('apps.updateMeta', { appId: app.id, status: 'running' });
      await window.platform.call('records.upsert', {
        appId: app.id,
        entityId: 'items',
        values: { title: 'Локальная запись' },
      });
      return app;
    }, definition);
    await page.locator('.app-nav').filter({ hasText: 'Проверка' }).first().click();
    await page.getByText('Локальная запись', { exact: true }).waitFor();
    await page.screenshot({ path: 'artifacts/application.png' });
    await page.getByRole('tab', { name: 'Расширение', exact: true }).click();
    let extensionPage;
    for (let attempt = 0; attempt < 100; attempt++) {
      extensionPage = app
        .context()
        .pages()
        .find((p) => p !== page && !p.isClosed() && p.url().startsWith('everything-extension:'));
      if (
        extensionPage &&
        (await extensionPage
          .getByText('Изолированный React работает')
          .count()
          .catch(() => 0))
      )
        break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert(extensionPage, 'Isolated extension renderer did not open');
    await extensionPage.getByText('Изолированный React работает').waitFor();
    const isolation = await extensionPage.locator('body').evaluate(() => ({
      node: typeof (window as any).require,
      platform: typeof (window as any).platform,
      origin: location.origin,
    }));
    assert.equal(isolation.node, 'undefined');
    assert.equal(isolation.platform, 'undefined');
    await page.screenshot({ path: 'artifacts/extension.png' });
    await page.getByRole('tab', { name: 'Текст', exact: true }).click();
    await page.getByRole('button', { name: 'Новый', exact: true }).click();
    await page.locator('.cm-content').fill('Настоящий текстовый черновик');
    await page.getByRole('tab', { name: 'Преобразования', exact: true }).click();
    await page.locator('.cm-content').first().fill('Тест');
    await page.getByRole('button', { name: 'Преобразовать', exact: true }).click();
    await page.getByText('0KLQtdGB0YI=', { exact: true }).waitFor();
    await page.getByRole('tab', { name: 'Изображение', exact: true }).click();
    await page.getByRole('button', { name: 'Новый', exact: true }).click();
    const canvas = page.getByLabel('Холст растрового редактора');
    const bounds = await canvas.boundingBox();
    assert(bounds);
    await page.mouse.move(bounds.x + 20, bounds.y + 20);
    await page.mouse.down();
    await page.mouse.move(bounds.x + 120, bounds.y + 100, { steps: 5 });
    await page.mouse.up();
    const pixel = await canvas.evaluate((el: HTMLCanvasElement) => [
      ...el.getContext('2d')!.getImageData(25, 25, 1, 1).data,
    ]);
    assert(pixel[3] > 0);
    await page.screenshot({ path: 'artifacts/raster.png' });
    await page.getByRole('button', { name: 'Настройки', exact: true }).click();
    await page.getByText('Подключение AI', { exact: true }).waitFor();
    await page.screenshot({ path: 'artifacts/settings.png' });
    const built = await page.evaluate(
      async (id) => window.platform.call('extensions.build', { appId: id, extensionId: 'hello' }),
      instance.id,
    );
    assert.match(built.html, /connect-src 'none'/);
    const doc = await page.evaluate(
      async (id) =>
        window.platform.call('docs.create', {
          appId: id,
          name: 'Черновик',
          kind: 'text',
          content: 'Сохранён после перезапуска',
        }),
      instance.id,
    );
    assert(doc.dirty);
    const denied = await page.evaluate(async () => {
      try {
        await window.platform.call('state.get', { key: 'runtime.provider' });
        return false;
      } catch {
        return true;
      }
    });
    assert(denied);
    await page.locator('.app-nav').filter({ hasText: 'Проверка' }).first().click();
    await page.getByRole('tab', { name: 'Текст', exact: true }).click();
    await page.locator('.cm-content').fill('Последняя правка перед выходом');
    await app.close();
    app = await launch();
    page = await app.firstWindow();
    page.on('pageerror', (e) => errors.push(e.stack || e.message));
    await page.waitForSelector('.home-page');
    const recovered = await page.evaluate(
      async (id) => ({
        docs: await window.platform.call('docs.list', { appId: id }),
        rows: await window.platform.call('records.list', { appId: id, entityId: 'items' }),
      }),
      instance.id,
    );
    assert.equal(recovered.rows.total, 1);
    assert(recovered.docs.some((d: any) => d.content === 'Последняя правка перед выходом'));
    assert.deepEqual(errors, []);
    await writeFile(
      'artifacts/desktop-results.json',
      JSON.stringify(
        {
          passed: true,
          errors,
          instance: instance.id,
          tests: [
            'home renders',
            'local app CRUD',
            'provider settings render without credentials',
            'extension builds and renders in isolated native view',
            'text draft editor',
            'local Base64 converter',
            'raster pixels change',
            'document draft persists across actual app restart, including last edit before quit',
            'internal state IPC denied',
          ],
        },
        null,
        2,
      ),
    );
    console.log('Desktop smoke passed');
  } catch (error) {
    console.error(logs.join(''), errors, await page.locator('body').innerText());
    await page.screenshot({ path: 'artifacts/failure.png' });
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
