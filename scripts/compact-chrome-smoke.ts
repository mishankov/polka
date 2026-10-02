import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-compact-chrome-'));
  const artifacts = resolve('artifacts/compact-chrome');
  await mkdir(artifacts, { recursive: true });
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  const errors: string[] = [];
  const name = 'Мастерская рисунков и набросков для большого творческого проекта';
  try {
    const shell = await app.firstWindow();
    shell.on('pageerror', (error) => errors.push(error.message));
    await shell.waitForSelector('.home-page');
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(1280, 850));
    const definition = {
      schemaVersion: 1,
      name,
      description: 'This description should not consume a large permanent heading above the app.',
      entities: [
        { id: 'items', name: 'Рисунки', fields: [{ id: 'title', name: 'Название', type: 'text' }] },
      ],
      screens: [{ id: 'canvas', name: 'Холст', type: 'custom', config: { extensionId: 'canvas' } }],
      actions: [],
      automations: [],
      permissions: [],
      extensions: [
        {
          id: 'canvas',
          name: 'Холст',
          kind: 'component',
          source: `import { Button } from '@mantine/core'; export default function Screen(){return <div data-testid="full-height-screen" style={{height:'100%',display:'flex',flexDirection:'column',minHeight:0}}><header style={{flexShrink:0}}><span>Рабочая область</span><Button onClick={()=>document.body.dataset.clicked='yes'}>Нарисовать</Button></header><div data-testid="scroll-area" style={{flex:1,minHeight:0,overflow:'auto'}}>{Array.from({length:100},(_,i)=><p key={i}>Рисунок {i+1}</p>)}</div><footer data-testid="screen-footer" style={{flexShrink:0}}>Нижняя панель</footer></div>}`,
        },
      ],
    };
    const instance = await shell.evaluate(async (definition) => {
      const instance = await window.platform.call('apps.create', { definition });
      await window.platform.call('apps.updateMeta', { appId: instance.id, status: 'running' });
      await window.platform.call('records.upsert', {
        appId: instance.id,
        entityId: 'items',
        values: { title: 'Сохранённый рисунок' },
      });
      return instance;
    }, definition);
    const opened = app.context().waitForEvent('page');
    await shell.locator('.app-nav').filter({ hasText: name }).first().click();
    let view = await opened;
    await view.getByText('Рабочая область', { exact: true }).waitFor();
    const nativeViews = () =>
      app.evaluate(({ BrowserWindow }) =>
        (BrowserWindow.getAllWindows()[0].contentView.children as any[])
          .filter((view) => view.webContents)
          .map((view) => ({ visible: view.getVisible(), bounds: view.getBounds() })),
      );
    const visibleView = async () => {
      await expect
        .poll(async () => {
          const views = await nativeViews();
          return views.length === 1 && views[0].visible && views[0].bounds.height > 200;
        })
        .toBe(true);
    };
    const capture = async (file: string) => {
      const png = await app.evaluate(async ({ BrowserWindow }) =>
        (await BrowserWindow.getAllWindows()[0].capturePage()).toPNG().toString('base64'),
      );
      await writeFile(join(artifacts, file), Buffer.from(png, 'base64'));
    };
    const heightChecks: unknown[] = [];
    const checkHeight = async (label: string) => {
      await visibleView();
      await expect
        .poll(
          async () => {
            const bounds = (await nativeViews())[0].bounds;
            const main = await shell.locator('.main-content').boundingBox();
            return !!main && Math.abs(main.y + main.height - bounds.y - bounds.height) <= 24;
          },
          { message: `${label}: custom screen must fill the workspace to the bottom` },
        )
        .toBe(true);
      const bounds = (await nativeViews())[0].bounds;
      const main = await shell.locator('.main-content').boundingBox();
      const navigation = await shell.locator('.runtime-navigation').boundingBox();
      assert(
        navigation && bounds.y >= navigation.y + navigation.height - 1,
        `${label}: native screen must not cover tabs or controls`,
      );
      await expect
        .poll(
          () =>
            view.evaluate(() => {
              const footer = document
                .querySelector('[data-testid="screen-footer"]')!
                .getBoundingClientRect();
              return Math.abs(innerHeight - footer.bottom) <= 24;
            }),
          { message: `${label}: extension layout should fill its native viewport` },
        )
        .toBe(true);
      const viewport = await view.evaluate(() => ({
        width: innerWidth,
        height: innerHeight,
        scrollHeight: document.documentElement.scrollHeight,
      }));
      assert(
        Math.abs(viewport.height - bounds.height) <= 1,
        `${label}: child viewport must match its native view`,
      );
      assert(
        viewport.scrollHeight <= viewport.height + 1,
        `${label}: full-height app should scroll its own content, not overflow its viewport`,
      );
      const footerBefore = await view.getByTestId('screen-footer').boundingBox();
      await view.getByTestId('scroll-area').evaluate((node) => {
        node.scrollTop = 300;
      });
      assert(
        (await view.getByTestId('scroll-area').evaluate((node) => node.scrollTop)) > 0,
        `${label}: app content should remain scrollable`,
      );
      assert.deepEqual(
        await view.getByTestId('screen-footer').boundingBox(),
        footerBefore,
        `${label}: scrolling content must keep footer in place`,
      );
      heightChecks.push({ label, bounds, main, viewport });
    };
    await visibleView();
    await expect(shell.locator('.app-heading')).toHaveCount(0);
    await expect(shell.locator('.app-identity h1')).toHaveText(name);
    await expect(shell.locator('.runtime-tabs')).toHaveCount(0);
    await expect(
      shell.getByRole('button', { name: 'Перезапустить экран', exact: true }),
    ).toBeHidden();
    await expect(shell.getByRole('button', { name: 'Остановить экран', exact: true })).toBeHidden();
    await expect(shell.getByRole('button', { name: 'Меню экрана', exact: true })).toBeVisible();
    await view.getByRole('button', { name: 'Нарисовать' }).click();
    await expect.poll(() => view.locator('body').getAttribute('data-clicked')).toBe('yes');
    const singleBounds = (await nativeViews())[0].bounds;
    assert(singleBounds.y < 150, 'single-screen app should start near the compact top bar');
    await checkHeight('single screen');
    await capture('single-screen-light.png');

    await shell.getByRole('button', { name: 'Меню экрана', exact: true }).click();
    const restarted = app.context().waitForEvent('page');
    await shell.getByRole('menuitem', { name: 'Перезапустить экран', exact: true }).click();
    view = await restarted;
    await view.getByText('Рабочая область', { exact: true }).waitFor();
    await visibleView();
    await shell.getByRole('button', { name: 'Меню экрана', exact: true }).click();
    const stopped = view.waitForEvent('close');
    await shell.getByRole('menuitem', { name: 'Остановить экран', exact: true }).click();
    await stopped;
    await expect(
      shell.getByRole('button', { name: 'Перезапустить экран', exact: true }),
    ).toBeVisible();
    const resumed = app.context().waitForEvent('page');
    await shell.getByRole('button', { name: 'Перезапустить экран', exact: true }).click();
    view = await resumed;
    await view.getByText('Рабочая область', { exact: true }).waitFor();
    await visibleView();

    const replaced = app.context().waitForEvent('page');
    await shell.evaluate(async (appId) => {
      const current = await window.platform.call('apps.get', { appId });
      current.definition.actions.push({
        id: 'export',
        name: 'Экспорт рисунков',
        type: 'records.export',
        config: { entityId: 'items' },
      });
      current.definition.screens.push({
        id: 'gallery',
        name: 'Мои рисунки',
        type: 'table',
        entityId: 'items',
      });
      const draft = await window.platform.call('definitions.prepare', {
        appId,
        definition: current.definition,
      });
      await window.platform.call('definitions.activate', { draftId: draft.draftId });
    }, instance.id);
    view = await replaced;
    await view.getByText('Рабочая область', { exact: true }).waitFor();
    await expect(shell.locator('.runtime-tabs').getByRole('tab')).toHaveCount(2);
    await visibleView();
    const tabBounds = (await nativeViews())[0].bounds;
    assert(tabBounds.y < 200, 'two-screen app should keep compact navigation above its content');
    await expect(
      shell.getByRole('button', { name: 'Экспорт рисунков', exact: true }),
    ).toBeVisible();
    const actionBounds = await shell
      .getByRole('button', { name: 'Экспорт рисунков', exact: true })
      .boundingBox();
    assert(
      actionBounds && tabBounds.y >= actionBounds.y + actionBounds.height,
      'native view must leave room for declared app actions',
    );
    for (const height of [1100, 650]) {
      await app.evaluate(
        ({ BrowserWindow }, height) => BrowserWindow.getAllWindows()[0].setSize(1280, height),
        height,
      );
      await view.getByTestId('full-height-screen').evaluate((node) => {
        node.style.height = '100%';
      });
      await checkHeight(`height ${height}, assistant closed, percentage layout`);
      await shell
        .locator('.topbar')
        .getByRole('button', { name: /Помощник/ })
        .click();
      await expect(shell.locator('.agent-panel')).toBeVisible();
      await view.getByTestId('full-height-screen').evaluate((node) => {
        node.style.height = '100vh';
      });
      await checkHeight(`height ${height}, assistant open, viewport layout`);
      const panel = await shell.locator('.agent-panel').boundingBox();
      const native = (await nativeViews())[0].bounds;
      assert(
        panel && native.x + native.width <= panel.x + 1,
        'native view must not cover assistant panel',
      );
      await shell
        .locator('.topbar')
        .getByRole('button', { name: /Помощник/ })
        .click();
      await expect(shell.locator('.agent-panel')).toHaveCount(0);
    }
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(1280, 850));
    await checkHeight('tabs and actions after resize');
    await view.getByTestId('full-height-screen').evaluate((node) => {
      node.style.height = 'auto';
    });
    await view.getByTestId('scroll-area').evaluate((node) => {
      node.style.overflow = 'visible';
    });
    await expect
      .poll(() => view.evaluate(() => document.documentElement.scrollHeight > innerHeight))
      .toBe(true);
    await view.evaluate(() => scrollTo(0, 300));
    await expect.poll(() => view.evaluate(() => scrollY)).toBeGreaterThan(0);
    await view.evaluate(() => scrollTo(0, 0));
    await view.getByTestId('full-height-screen').evaluate((node) => {
      node.style.height = '100%';
    });
    await view.getByTestId('scroll-area').evaluate((node) => {
      node.style.overflow = 'auto';
    });
    await checkHeight('full-height restored after natural document scrolling');
    await capture('two-screens-light.png');
    await shell.getByRole('tab', { name: 'Мои рисунки', exact: true }).click();
    await shell.getByRole('cell', { name: 'Сохранённый рисунок', exact: true }).waitFor();
    await expect.poll(async () => (await nativeViews()).length).toBe(0);
    const returned = app.context().waitForEvent('page');
    await shell.getByRole('tab', { name: 'Холст', exact: true }).click();
    view = await returned;
    await view.getByText('Рабочая область', { exact: true }).waitFor();
    await visibleView();

    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(720, 700));
    await expect(shell.locator('.app-identity h1')).toBeVisible();
    await expect(shell.locator('.app-identity h1')).toHaveText(name);
    await expect
      .poll(() => shell.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
      .toBe(true);
    const title = await shell.locator('.app-identity h1').boundingBox();
    assert(
      title && title.width > 30 && title.height < 50,
      'long title must remain compact and visible',
    );
    await visibleView();
    await capture('two-screens-narrow.png');
    await shell.getByRole('button', { name: 'Настройки', exact: true }).click();
    await shell.getByText('Тёмное', { exact: true }).click();
    await expect(shell.locator('html')).toHaveAttribute('data-mantine-color-scheme', 'dark');
    const darkOpened = app.context().waitForEvent('page');
    await shell.locator('.app-nav').filter({ hasText: name }).first().click();
    view = await darkOpened;
    await view.getByText('Рабочая область', { exact: true }).waitFor();
    await expect(view.locator('html')).toHaveAttribute('data-mantine-color-scheme', 'dark');
    await visibleView();
    await capture('two-screens-dark.png');
    await view.screenshot({ path: join(artifacts, 'custom-screen-dark.png') });
    assert.deepEqual(errors, []);
    await writeFile(
      join(artifacts, 'smoke.json'),
      JSON.stringify(
        {
          passed: true,
          checks: [
            'one compact app title',
            'single-screen navigation hidden',
            'two-screen navigation works',
            'native view visible and interactive',
            'screen menu restart and stop',
            'stopped-screen recovery',
            'long name at narrow width',
            'dark theme propagation',
            'workspace height at tall and short sizes, assistant open and closed',
            'native viewport and app layout fill available height',
            'tabs and actions remain visible above native content',
            'app content scrolls while footer stays fixed',
            'natural long documents remain scrollable',
          ],
          singleBounds,
          tabBounds,
          heightChecks,
          errors,
        },
        null,
        2,
      ),
    );
    console.log('Compact app chrome smoke passed');
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
