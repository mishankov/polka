import { runDesktopTest, type DesktopTest } from './desktop-test';
import { shelfSearchCases, shelfSearchContext } from './shelf-search-cases';
import { expect } from '@playwright/test';
import { readFile, writeFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { parseArgs } from 'node:util';
import { join, resolve } from 'node:path';

async function main(test: DesktopTest) {
  const { values } = parseArgs({ options: { case: { type: 'string' } } });
  const scenarios = values.case
    ? shelfSearchCases.filter((scenario) => scenario.id === values.case)
    : shelfSearchCases;
  if (!scenarios.length)
    throw Error(
      `Unknown shelf/search case. Choose: ${shelfSearchCases.map((s) => s.id).join(', ')}.`,
    );
  const profile = test.profile;
  const entry = join(profile, 'main.cjs');
  const fixtureSource = stripTypeScriptTypes(
    await readFile(resolve('tests/desktop/shelf-search-fixture.ts'), 'utf8'),
  ).replace('export function', 'function');
  await writeFile(
    entry,
    `
    const { app, BrowserWindow, ipcMain } = require('electron');
    app.setPath('userData', ${JSON.stringify(profile)});
    ${fixtureSource}
    const fixture = createShelfSearchFixture();
    ipcMain.handle('platform:call', async (event, method, params) => {
      if (method === 'shelf.didShow') {
        const count = await event.sender.executeJavaScript('document.querySelector(".launcher-search") ? document.querySelectorAll(".launcher-result[data-kind=mac]").length : -1');
        if (count >= 0) fixture.catalogAtShow.push(count);
      }
      return fixture.call(method, params);
    });
    global.fixture = fixture;
    app.whenReady().then(() => {
      // This hidden renderer fixture avoids native focus and mouse input from the desktop.
      const window = new BrowserWindow({ show: false, width: 720, height: 740, webPreferences: { preload: ${JSON.stringify(resolve('out/preload/index.js'))} } });
      fixture.onEvent(event => window.webContents.send('platform:event', event));
      window.loadFile(${JSON.stringify(resolve('out/renderer/index.html'))});
    });
  `,
  );
  for (const scenario of scenarios) {
    await test.step(scenario.name, async () => {
      const app = await test.launch({ args: [entry] });
      const page = await app.firstWindow();
      const context = shelfSearchContext(test, app, page);
      await expect(context.input).toBeFocused();
      await expect(context.rows).toHaveCount(11);
      await scenario.run(context);
      await test.close(app, true);
    });
  }
}
void runDesktopTest('shelf-search-shortcuts', main).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
