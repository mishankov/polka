import {
  app,
  BrowserWindow,
  ipcMain,
  Menu,
  Tray,
  nativeImage,
  globalShortcut,
  screen,
  powerMonitor,
  session,
  shell,
  autoUpdater as nativeUpdater,
} from 'electron';
import { Worker } from 'node:worker_threads';
import { promises as fs } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { z } from 'zod';
import { autoUpdater } from 'electron-updater';
import { UpdateService } from './updates';
import { bindSettingsShortcut } from './workspace-shortcuts';
import { createShelf } from './shelf';
import { createMediaIndicator } from './media-indicator';
import { LauncherShortcut } from './launcher-shortcut';
import { BUILTIN_APPS, DEFAULT_LAUNCHER_SHORTCUT } from '../shared/launcher';
import { InstalledApps, readApplicationIcons } from './installed-apps';
import { protectTerminalOutput } from './terminal-output';
import polkaTrayPath from './assets/polkaTemplate.png?asset';
import polkaTray2xPath from './assets/polkaTemplate@2x.png?asset';
import polkaTray3xPath from './assets/polkaTemplate@3x.png?asset';
import { shelfMethodAllowed } from '../shared/features';
protectTerminalOutput();
const execFileAsync = promisify(execFile);
if (process.env.EVERYTHING_PROFILE) app.setPath('userData', process.env.EVERYTHING_PROFILE);
const windows = new Map<number, { window: BrowserWindow; mode: string }>(),
  pending = new Map<string, { resolve: (v: any) => void; reject: (e: Error) => void }>();
let updates: UpdateService;
let worker: Worker,
  tray: Tray | null = null,
  quitting = false,
  quitPending = false,
  updateInstalling = false;
const root = app.getPath('userData');
const mediaIndicator = createMediaIndicator({
  preload: join(__dirname, '../preload/media-indicator.js'),
  page: join(__dirname, '../renderer/media-indicator.html'),
  devURL: process.env.ELECTRON_RENDERER_URL
    ? `${process.env.ELECTRON_RENDERER_URL}/media-indicator.html`
    : undefined,
  read: () => host('system.media', {}),
  saveEnabled: (enabled) => call('settings.set', { key: 'mediaIndicatorEnabled', value: enabled }),
  changed: (state) => broadcast({ type: 'mediaIndicator.changed', state }),
});
const installedApps = new InstalledApps({
  getIcons: readApplicationIcons,
  getIcon: async (path) => {
    const icon = await app.getFileIcon(path, { size: 'normal' });
    return icon.isEmpty() ? '' : icon.resize({ width: 32, height: 32 }).toDataURL();
  },
  openPath: (path) => shell.openPath(path),
});
const shelf = createShelf(
  root,
  (win) => {
    windows.set(win.id, { window: win, mode: 'shelf' });
    bindSettingsShortcut(win.webContents, showSettings);
    win.on('closed', () => windows.delete(win.id));
  },
  () => broadcast({ type: 'clipboardHistory.changed' }),
  () => quitting,
  (notches) => mediaIndicator.setNotches(notches),
);
const launcherShortcut = new LauncherShortcut(
  globalShortcut,
  () => {
    void shelf.toggle('apps').catch((error) => console.error('Could not open shelf', error));
  },
  (accelerator) => call('settings.set', { key: 'launcherShortcut', value: accelerator }),
);
function broadcast(event: any) {
  for (const { window } of windows.values())
    if (!window.isDestroyed()) window.webContents.send('platform:event', event);
}
function call(method: string, params: any = {}) {
  return new Promise<any>((resolve, reject) => {
    const id = randomUUID();
    pending.set(id, { resolve, reject });
    worker.postMessage({ kind: 'call', id, method, params });
  });
}
async function host(method: string, p: any): Promise<any> {
  if (method === 'system.media') {
    try {
      const { stdout } = await execFileAsync(
        app.isPackaged
          ? join(process.resourcesPath, 'media-probe')
          : join(app.getAppPath(), 'build/media-probe'),
        [],
        { timeout: 2000, maxBuffer: 128 * 1024 },
      );
      return JSON.parse(stdout);
    } catch {
      return Object.fromEntries(
        ['camera', 'microphone', 'screen', 'mute'].map((k) => [
          k,
          { state: 'unknown', detail: 'Нативный адаптер недоступен' },
        ]),
      );
    }
  }
  throw Error('Неизвестная системная операция');
}
async function refreshTrayMenu() {
  if (!tray || tray.isDestroyed()) return;
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: 'Открыть полку', click: () => void shelf.show().catch(console.error) },
      {
        label: 'История буфера обмена',
        click: () => void shelf.show('keyboard', 'clipboard').catch(console.error),
      },
      { label: 'Настройки…', click: showSettings },
      {
        label: 'О приложении и обновления',
        click: () => void shelf.show('keyboard', 'about').catch(console.error),
      },
      { type: 'separator' },
      { label: 'Выйти из Полки', click: () => app.quit() },
    ]),
  );
}
function showSettings() {
  void shelf.show('keyboard', 'settings').catch(console.error);
}
async function openWindow() {
  await shelf.show();
}
const rpcSchema = z.tuple([
  z
    .string()
    .min(1)
    .max(80)
    .regex(/^[a-zA-Z][a-zA-Z0-9.]*$/),
  z.record(z.string(), z.unknown()),
]);
async function rendererCall(event: Electron.IpcMainInvokeEvent, method: string, params: any = {}) {
  const sender = [...windows.values()].find((w) => w.window.webContents === event.sender);
  if (!sender || event.senderFrame !== event.sender.mainFrame)
    throw Error('Недоверенный отправитель');
  rpcSchema.parse([method, params]);
  if (!shelfMethodAllowed(method)) throw Error('Неизвестная операция');
  if (JSON.stringify(params).length > 48 * 1024 * 1024) throw Error('Запрос превышает лимит');
  if (method === 'clipboardHistory.select' && sender.mode !== 'shelf')
    throw Error('Вставка доступна только из истории на полке');
  if (method === 'mediaIndicator.getState') return mediaIndicator.state();
  if (method === 'mediaIndicator.setEnabled')
    return mediaIndicator.setEnabled(z.boolean().parse(params.enabled));
  if (method === 'settings.set' && params.key === 'mediaIndicatorEnabled')
    return mediaIndicator.setEnabled(z.boolean().parse(params.value));
  if (method.startsWith('clipboardHistory.') || method.startsWith('shelf.'))
    return shelf.handle(method, params);
  if (method === 'launcher.show') {
    await shelf.show();
    return true;
  }
  if (method === 'launcher.hide') {
    shelf.hide();
    return true;
  }
  if (method === 'launcher.apps') return BUILTIN_APPS;
  if (method === 'launcher.macApps') return installedApps.list();
  if (method === 'launcher.openMac') {
    const revision = shelf.getRevision();
    const id = z
      .string()
      .regex(/^mac:[a-f0-9]{32}$/)
      .parse(params.id);
    const result = await installedApps.open(id);
    if (revision === shelf.getRevision()) shelf.hide();
    return result;
  }
  if (method === 'launcher.getPreferences') return launcherShortcut.getPreferences();
  if (method === 'launcher.setShortcut') {
    const accelerator = z.string().max(80).parse(params.accelerator);
    if (
      accelerator &&
      !/^(?:(?:CommandOrControl|Control|Alt|Shift)\+)+(?:[A-Z0-9]|Space|F(?:[1-9]|1[0-2]))$/.test(
        accelerator,
      )
    )
      throw Error('Выберите сочетание клавиш с Command, Control или Option.');
    if (accelerator && !/(CommandOrControl|Control|Alt)\+/.test(accelerator))
      throw Error('Добавьте Command, Control или Option.');
    const preferences = await launcherShortcut.set(accelerator);
    broadcast({ type: 'launcher.preferencesChanged', preferences });
    return preferences;
  }
  if (method === 'windows.close') {
    sender.window.close();
    return true;
  }
  if (method === 'system.media') return host(method, {});
  if (method === 'system.status')
    return {
      platform: process.platform,
      arch: process.arch,
      electron: process.versions.electron,
      node: process.versions.node,
      login: app.getLoginItemSettings().openAtLogin,
      windows: [...windows.values()].map((w) => ({ mode: w.mode })),
    };
  if (method === 'system.quit') {
    app.quit();
    return true;
  }
  if (method === 'system.login') {
    app.setLoginItemSettings({ openAtLogin: !!params.enabled, args: ['--hidden'] });
    return app.getLoginItemSettings().openAtLogin;
  }
  if (method.startsWith('updates.')) return updates.handle(method);
  return call(method, params);
}
if (!app.requestSingleInstanceLock()) app.quit();
app.on('second-instance', () => {
  void openWindow();
});
app
  .whenReady()
  .then(async () => {
    if (process.platform === 'darwin') app.setActivationPolicy('accessory');
    await fs.mkdir(root, { recursive: true, mode: 0o700 });
    session.defaultSession.setPermissionRequestHandler((_wc, _p, cb) => cb(false));
    session.defaultSession.setPermissionCheckHandler(() => false);
    worker = new Worker(join(__dirname, 'worker.js'), {
      workerData: { root },
    });
    worker.on('message', async (m) => {
      if (m.kind === 'result') {
        const request = pending.get(m.id);
        if (request) {
          pending.delete(m.id);
          m.error ? request.reject(Error(m.error)) : request.resolve(m.result);
        }
      }
    });
    worker.on('error', (e) => {
      for (const p of pending.values()) p.reject(e instanceof Error ? e : Error(String(e)));
      pending.clear();
      broadcast({
        type: 'platform.error',
        message:
          'Рабочий процесс остановился. Перезапустите платформу; локальные данные сохранены.',
      });
    });
    await new Promise<void>((resolve, reject) => {
      worker.once('error', reject);
      const ready = (m: any) => {
        if (m.kind === 'ready') {
          worker.off('message', ready);
          resolve();
        }
      };
      worker.on('message', ready);
    });
    ipcMain.handle('platform:call', rendererCall);
    void installedApps
      .list()
      .catch((error) => console.error('Could not list installed apps', error));
    Menu.setApplicationMenu(
      Menu.buildFromTemplate([
        {
          label: 'Полка',
          submenu: [
            {
              label: 'О приложении и обновления',
              click: () => void shelf.show('keyboard', 'about').catch(console.error),
            },
            {
              id: 'settings',
              label: 'Настройки…',
              accelerator: 'CommandOrControl+,',
              click: showSettings,
            },
            { type: 'separator' },
            {
              label: 'Открыть полку',
              click: () => void openWindow(),
            },
            { label: 'Запуск приложений', click: () => void shelf.show().catch(console.error) },
            {
              label: 'История буфера обмена',
              click: () => void shelf.show('keyboard', 'clipboard').catch(console.error),
            },
            { type: 'separator' },
            { role: 'hide' },
            { role: 'quit', label: 'Выйти из Полки' },
          ],
        },
        {
          label: 'Правка',
          submenu: [
            { role: 'undo' },
            { role: 'redo' },
            { type: 'separator' },
            { role: 'cut' },
            { role: 'copy' },
            { role: 'paste' },
            { role: 'selectAll' },
          ],
        },
        {
          label: 'Вид',
          submenu: [
            { role: 'reload' },
            { role: 'toggleDevTools' },
            { role: 'resetZoom' },
            { role: 'zoomIn' },
            { role: 'zoomOut' },
          ],
        },
      ]),
    );
    const image = nativeImage.createFromPath(polkaTrayPath);
    image.addRepresentation({ scaleFactor: 2, buffer: await fs.readFile(polkaTray2xPath) });
    image.addRepresentation({ scaleFactor: 3, buffer: await fs.readFile(polkaTray3xPath) });
    image.setTemplateImage(true);
    tray = new Tray(image);
    tray.setToolTip('Полка');
    await refreshTrayMenu();
    powerMonitor.on('resume', () => {
      shelf.resume();
      mediaIndicator.resume();
      broadcast({ type: 'system.resume' });
    });
    powerMonitor.on('suspend', () => {
      shelf.suspend();
      mediaIndicator.suspend();
      broadcast({ type: 'system.suspend' });
    });
    powerMonitor.on('lock-screen', () => {
      shelf.suspend('lock');
      mediaIndicator.suspend('lock');
    });
    powerMonitor.on('unlock-screen', () => {
      shelf.resume('lock');
      mediaIndicator.resume('lock');
    });
    screen.on('display-removed', () => {
      const area = screen.getPrimaryDisplay().workArea;
      for (const { window } of windows.values()) {
        const bounds = window.getBounds();
        if (
          !screen
            .getAllDisplays()
            .some((d) => bounds.x >= d.bounds.x && bounds.x < d.bounds.x + d.bounds.width)
        )
          window.setBounds({
            x: area.x,
            y: area.y,
            width: Math.min(bounds.width, area.width),
            height: Math.min(bounds.height, area.height),
          });
      }
    });
    autoUpdater.autoDownload = false;
    autoUpdater.autoInstallOnAppQuit = false;
    autoUpdater.allowPrerelease = false;
    autoUpdater.allowDowngrade = false;
    const metadata = JSON.parse(await fs.readFile(join(app.getAppPath(), 'package.json'), 'utf8'));
    const officialRelease =
      app.isPackaged &&
      metadata.release?.signed === true &&
      /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(metadata.release?.repository || '');
    updates = new UpdateService(
      autoUpdater,
      app.getVersion(),
      officialRelease,
      (state) => broadcast({ type: 'updates.state', state }),
      async () => {
        updateInstalling = true;
        for (const { window } of windows.values())
          if (!window.isDestroyed()) window.setEnabled(false);
        await shelf.flush();
      },
      () => {
        updateInstalling = false;
        for (const { window } of windows.values())
          if (!window.isDestroyed()) window.setEnabled(true);
      },
    );
    const settings = await call('settings.get');
    launcherShortcut.initialize(
      typeof settings?.launcherShortcut === 'string'
        ? settings.launcherShortcut
        : DEFAULT_LAUNCHER_SHORTCUT,
    );
    await shelf.start();
    if (!process.argv.includes('--hidden') && !app.getLoginItemSettings().wasOpenedAtLogin)
      await openWindow();
    mediaIndicator.start(settings?.mediaIndicatorEnabled !== false);
  })
  .catch((e) => {
    console.error('Startup failed', e);
    app.quit();
  });
app.on('window-all-closed', () => {
  /* Keep the shelf and clipboard history available in the menu bar. */
});
app.on('activate', () => {
  if (worker) void openWindow();
});
// Squirrel emits this only when staging succeeded, immediately before closing windows.
// A normal before-quit arrives too late for the updater's window-close sequence.
nativeUpdater.on('before-quit-for-update', () => {
  if (!updateInstalling) return;
  quitting = true;
  globalShortcut.unregisterAll();
  void shelf.stop();
  mediaIndicator.stop();
  // Close the settings database before the native installer exits.
  try {
    worker?.postMessage({ kind: 'shutdown' });
  } catch {
    /* Native install must still exit if the settings worker has already stopped. */
  }
});
app.on('before-quit', (event) => {
  if (quitting) return;
  if (!worker) {
    quitting = true;
    return;
  }
  event.preventDefault();
  if (quitPending) return;
  quitPending = true;
  void Promise.resolve()
    .then(async () => {
      globalShortcut.unregisterAll();
      await shelf.stop();
      mediaIndicator.stop();
      const stopped = new Promise<void>((resolve) => worker.once('exit', () => resolve()));
      worker.postMessage({ kind: 'shutdown' });
      await stopped;
      quitting = true;
      app.quit();
    })
    .catch((error) => {
      quitPending = false;
      broadcast({ type: 'platform.error', message: String(error) });
    });
});
