import type { ElectronApplication, Page } from '@playwright/test';

// CDP keyboard events bypass Electron's before-input-event. Exercise the native path.
export async function pressAssistantShortcut(app: ElectronApplication, page: Page) {
  await app.evaluate(({ webContents, BrowserWindow }, url) => {
    const contents = webContents.getAllWebContents().find((entry) => entry.getURL() === url);
    if (!contents) throw Error('Shortcut target was closed');
    BrowserWindow.fromWebContents(contents)?.focus();
    contents.focus();
    const modifiers: ('meta' | 'control')[] = [process.platform === 'darwin' ? 'meta' : 'control'];
    contents.sendInputEvent({ type: 'keyDown', keyCode: 'J', modifiers });
    contents.sendInputEvent({ type: 'keyUp', keyCode: 'J', modifiers });
  }, page.url());
}

export async function pressSettingsShortcut(app: ElectronApplication, page: Page) {
  await app.evaluate(({ webContents, BrowserWindow }, url) => {
    const contents = webContents.getAllWebContents().find((entry) => entry.getURL() === url);
    if (!contents) throw Error('Shortcut target was closed');
    BrowserWindow.fromWebContents(contents)?.focus();
    contents.focus();
    const modifiers: ('meta' | 'control')[] = [process.platform === 'darwin' ? 'meta' : 'control'];
    contents.sendInputEvent({ type: 'keyDown', keyCode: ',', modifiers });
    contents.sendInputEvent({ type: 'keyUp', keyCode: ',', modifiers });
  }, page.url());
}
