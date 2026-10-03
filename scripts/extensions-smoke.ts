import { _electron as electron, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pressAssistantShortcut } from './native-shortcuts';
async function main() {
  const profile = await mkdtemp(join(tmpdir(), 'everything-extension-'));
  const app = await electron.launch({
    ...(process.env.EVERYTHING_EXECUTABLE
      ? { executablePath: resolve(process.env.EVERYTHING_EXECUTABLE), args: [], cwd: profile }
      : { args: [resolve('.')] }),
    env: { ...process.env, EVERYTHING_PROFILE: profile },
  });
  const shell = await app.firstWindow();
  const errors: string[] = [];
  shell.on('pageerror', (error) => errors.push(error.message));
  try {
    await shell.waitForSelector('.home-page');
    await pressAssistantShortcut(app, shell);
    await expect(shell.locator('.agent-panel')).toBeVisible();
    await shell.locator('.agent-panel textarea').focus();
    await pressAssistantShortcut(app, shell);
    await expect(shell.locator('.agent-panel')).toHaveCount(0);
    await shell.evaluate(() => {
      (window as any).extensionEvents = [];
      window.platform.onEvent((event) => {
        if (event.type === 'extension.status') (window as any).extensionEvents.push(event);
      });
    });
    const source = `import { useState } from 'react'; import { Button, Stack, Title } from '@mantine/core'; import { RecordTable, EntityForm } from '@everything/ui'; const entity={id:'items',name:'Записи',fields:[{id:'title',name:'Название',type:'text',required:true}]}; export default function Screen({sdk}){const [refresh,setRefresh]=useState(0); return <Stack><Title order={3}>Isolated Mantine</Title><EntityForm entity={entity} onSaved={()=>setRefresh(x=>x+1)}/><RecordTable entity={entity} refresh={refresh}/><Button onClick={()=>setTimeout(()=>{while(true){}},100)}>Block extension</Button></Stack>}`;
    const definition = {
      schemaVersion: 1,
      name: 'Isolation QA',
      entities: [
        {
          id: 'items',
          name: 'Записи',
          fields: [{ id: 'title', name: 'Название', type: 'text', required: true }],
        },
      ],
      screens: [
        { id: 'screen', name: 'Screen', type: 'custom', config: { extensionId: 'screen' } },
      ],
      actions: [],
      automations: [],
      permissions: [],
      extensions: [
        {
          id: 'screen',
          name: 'Screen',
          kind: 'component',
          source,
          dependencies: { '@mantine/core': '9.6.3', '@everything/ui': '1.0.0' },
        },
      ],
    };
    const instance = await shell.evaluate(async (definition) => {
      const instance = await window.platform.call('apps.create', { definition });
      await window.platform.call('apps.updateMeta', { appId: instance.id, status: 'running' });
      return instance;
    }, definition);
    const opened = app.context().waitForEvent('page');
    await shell.locator('.app-nav').filter({ hasText: 'Isolation QA' }).first().click();
    let view = await opened;
    await view.getByText('Isolated Mantine').waitFor({ timeout: 30000 });
    assert.equal(await view.evaluate(() => typeof (window as any).require), 'undefined');
    assert.equal(await view.evaluate(() => typeof (window as any).platform), 'undefined');
    const denied = await view.evaluate(async () => {
      try {
        await (window as any).extensionHost.call('state.get', { key: 'secret' });
        return false;
      } catch {
        return true;
      }
    });
    assert(denied);
    const wrongApp = await view.evaluate(async () => {
      try {
        await (window as any).extensionHost.call('records.list', {
          appId: 'other',
          entityId: 'items',
        });
        return false;
      } catch {
        return true;
      }
    });
    assert(wrongApp);
    const processIds = await app.evaluate(({ BrowserWindow }) => {
      const win = BrowserWindow.getAllWindows()[0];
      return [
        win.webContents.getOSProcessId(),
        ...(win.contentView.children as any[])
          .filter((v) => v.webContents)
          .map((v) => v.webContents.getOSProcessId()),
      ];
    });
    assert.equal(new Set(processIds).size, processIds.length);
    assert(processIds.length >= 2);
    await view.getByRole('textbox', { name: 'Название', exact: true }).fill('SDK record');
    await view.getByRole('button', { name: 'Сохранить', exact: true }).click();
    await view.getByRole('cell', { name: 'SDK record', exact: true }).waitFor();
    const nativeViews = () =>
      app.evaluate(({ BrowserWindow }) =>
        (BrowserWindow.getAllWindows()[0].contentView.children as any[])
          .filter((view) => view.webContents)
          .map((view) => ({ visible: view.getVisible(), bounds: view.getBounds() })),
      );
    // Keyboard events in an isolated custom screen do not bubble to the workspace DOM.
    await view.getByRole('textbox', { name: 'Название', exact: true }).focus();
    await pressAssistantShortcut(app, view);
    await shell.locator('.agent-panel').waitFor();
    const panel = await shell.locator('.agent-panel').boundingBox();
    assert(panel);
    await expect
      .poll(
        async () => {
          const views = await nativeViews();
          return (
            views.length > 0 &&
            views.every(({ visible, bounds }) => visible && bounds.x + bounds.width <= panel.x + 1)
          );
        },
        { message: 'The assistant beside a custom screen must not hide that screen' },
      )
      .toBe(true);
    await view.getByRole('cell', { name: 'SDK record', exact: true }).waitFor();
    await view.getByRole('textbox', { name: 'Название', exact: true }).focus();
    await pressAssistantShortcut(app, view);
    await shell.locator('.agent-panel').waitFor({ state: 'hidden' });
    await expect.poll(async () => (await nativeViews()).every((view) => view.visible)).toBe(true);
    const [{ bounds }] = await nativeViews();
    await shell.evaluate((bounds) => {
      const overlay = document.createElement('div');
      overlay.id = 'test-overlay';
      overlay.setAttribute('role', 'dialog');
      overlay.style.cssText = `position:fixed;left:${bounds.x + 10}px;top:${bounds.y + 10}px;width:100px;height:100px`;
      document.body.appendChild(overlay);
    }, bounds);
    await expect.poll(async () => (await nativeViews()).every((view) => !view.visible)).toBe(true);
    await shell.evaluate(() => {
      const overlay = document.getElementById('test-overlay')!;
      overlay.style.cssText = 'position:fixed;left:0;top:0;width:10px;height:10px';
    });
    await expect
      .poll(async () => (await nativeViews()).every((view) => view.visible), {
        message: 'A dialog outside the custom screen must not hide it',
      })
      .toBe(true);
    await shell.evaluate(() => document.getElementById('test-overlay')?.remove());
    await shell.evaluate(async () => {
      const event = (window as any).extensionEvents.find((e: any) => e.status === 'ready');
      await window.platform.call('extensions.view.theme', {
        viewId: event.viewId,
        theme: { scheme: 'dark' },
      });
    });
    await view.waitForFunction(
      () => document.documentElement.getAttribute('data-mantine-color-scheme') === 'dark',
    );
    await mkdir('artifacts', { recursive: true });
    await view.screenshot({ path: 'artifacts/extension-kit-dark.png' });
    const closed = view.waitForEvent('close');
    await view.getByRole('button', { name: 'Block extension' }).click({ noWaitAfter: true });
    assert.equal(await shell.evaluate(() => 1 + 1), 2);
    await shell
      .getByText('Не удалось открыть экран. Попросите помощника проверить и исправить приложение.')
      .waitFor({ timeout: 20000 });
    await expect(shell.getByText('Экран не отвечает.', { exact: false })).toBeHidden();
    await shell.getByText('Подробности ошибки', { exact: true }).click();
    await shell.getByText('Экран не отвечает.', { exact: false }).waitFor();
    await closed;
    const reloaded = app.context().waitForEvent('page');
    await shell.getByRole('button', { name: 'Перезапустить экран' }).click();
    view = await reloaded;
    await view.getByText('Isolated Mantine').waitFor();
    await view.getByRole('cell', { name: 'SDK record', exact: true }).waitFor();
    const oldViewClosed = view.waitForEvent('close');
    await shell.reload();
    await oldViewClosed;
    await shell.waitForSelector('.home-page');
    const afterReload = app.context().waitForEvent('page');
    await shell.locator('.app-nav').filter({ hasText: 'Isolation QA' }).first().click();
    view = await afterReload;
    await view.getByText('Isolated Mantine').waitFor();
    await view.getByRole('cell', { name: 'SDK record', exact: true }).waitFor();
    const previousVersionClosed = view.waitForEvent('close');
    const activatedVersion = app.context().waitForEvent('page');
    await shell.evaluate(async (appId) => {
      const current = await window.platform.call('apps.get', { appId });
      current.definition.extensions[0].source = current.definition.extensions[0].source.replace(
        'Isolated Mantine',
        'Updated Mantine',
      );
      const draft = await window.platform.call('definitions.prepare', {
        appId,
        definition: current.definition,
      });
      await window.platform.call('definitions.activate', { draftId: draft.draftId });
    }, instance.id);
    await previousVersionClosed;
    view = await activatedVersion;
    await view.getByText('Updated Mantine').waitFor();
    await view.getByRole('cell', { name: 'SDK record', exact: true }).waitFor();
    const stopped = view.waitForEvent('close');
    await shell.evaluate(
      (appId) => window.platform.call('apps.updateMeta', { appId, status: 'stopped' }),
      instance.id,
    );
    await stopped;
    assert.deepEqual(errors, []);
    await writeFile(
      'artifacts/extensions-smoke.json',
      JSON.stringify(
        {
          passed: true,
          processIds,
          checks: [
            'Mantine/platform render',
            'scoped CRUD',
            'blocked state and cross-app calls',
            'separate process',
            'assistant beside custom screen stays visible',
            'Cmd+J toggles from workspace, assistant input, and isolated custom screen',
            'overlapping overlay hides screen; non-overlapping overlay keeps it visible',
            'theme propagation',
            'busy-loop recovery',
            'restart persistence',
            'shell reload disposes old view and permits fresh view',
            'definition activation replaces UI code and preserves records',
            'stopped-app teardown',
          ],
        },
        null,
        2,
      ),
    );
    console.log('Extension isolation smoke passed');
  } finally {
    await app.close();
    await rm(profile, { recursive: true, force: true });
  }
}
void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
