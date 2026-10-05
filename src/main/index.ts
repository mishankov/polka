import {
  app,
  BrowserWindow,
  ipcMain,
  dialog,
  safeStorage,
  clipboard,
  Notification,
  Menu,
  Tray,
  nativeImage,
  nativeTheme,
  globalShortcut,
  screen,
  powerMonitor,
  session,
  shell,
  autoUpdater as nativeUpdater,
} from 'electron';
import { Worker } from 'node:worker_threads';
import { promises as fs } from 'node:fs';
import { extname, join } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { z } from 'zod';
import { autoUpdater } from 'electron-updater';
import { UpdateService } from './updates';
import { chooseDocuments, openDroppedDocuments } from './documentFiles';
import { createExtensionViews } from './extension-views';
import { bindAssistantShortcut, bindSettingsShortcut } from './workspace-shortcuts';
import { ConnectionCredentials } from './connections';
import { externalWebUrl } from '../shared/externalLinks';
import type { AppInstance } from '../shared/types';
import { createShelf } from './shelf';
import { createMediaIndicator } from './media-indicator';
import { LauncherShortcut } from './launcher-shortcut';
import { BUILTIN_APPS, DEFAULT_LAUNCHER_SHORTCUT } from '../shared/launcher';
import { InstalledApps, readApplicationIcons } from './installed-apps';
import { protectTerminalOutput } from './terminal-output';
import polkaTrayPath from './assets/polkaTemplate.png?asset';
import polkaTray2xPath from './assets/polkaTemplate@2x.png?asset';
import polkaTray3xPath from './assets/polkaTemplate@3x.png?asset';
import {
  CUSTOM_APPS_ENABLED,
  FROZEN_FEATURE_MESSAGE,
  shelfMethodAllowed,
} from '../shared/features';
protectTerminalOutput();
// Keep native window materials and controls dark alongside the shelf and settings.
if (!CUSTOM_APPS_ENABLED) nativeTheme.themeSource = 'dark';
const execFileAsync = promisify(execFile);
if (process.env.EVERYTHING_PROFILE) app.setPath('userData', process.env.EVERYTHING_PROFILE);
const windows = new Map<number, { window: BrowserWindow; appId?: string; mode: string }>(),
  pending = new Map<string, { resolve: (v: any) => void; reject: (e: Error) => void }>();
let updates: UpdateService;
let extensionViews: ReturnType<typeof createExtensionViews>;
let worker: Worker,
  tray: Tray | null = null,
  quitting = false,
  quitPending = false,
  updateInstalling = false,
  pendingPackage: string | undefined;
function desktopAppearance() {
  return {
    dark: nativeTheme.shouldUseDarkColors,
    contrast: nativeTheme.shouldUseHighContrastColors,
    reducedTransparency: nativeTheme.prefersReducedTransparency,
  };
}
nativeTheme.on('updated', () =>
  broadcast({ type: 'appearance.changed', appearance: desktopAppearance() }),
);
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
    const ownerId = win.webContents.id;
    win.webContents.on('destroyed', () => extensionViews?.disposeOwner(ownerId));
    win.webContents.on('did-start-navigation', (details) => {
      if (details.isMainFrame && !details.isSameDocument) extensionViews?.disposeOwner(ownerId);
    });
    win.on('closed', () => windows.delete(win.id));
  },
  () => broadcast({ type: 'clipboardHistory.changed' }),
  () => quitting,
  flushWindow,
  (notches) => mediaIndicator.setNotches(notches),
);
const launcherShortcut = new LauncherShortcut(
  globalShortcut,
  () => {
    void shelf.toggle('apps').catch((error) => console.error('Could not open shelf', error));
  },
  (accelerator) => call('settings.set', { key: 'launcherShortcut', value: accelerator }),
);
const flushRequests = new Map<
  string,
  {
    senderId: number;
    resolve: () => void;
    reject: (e: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }
>();
function flushWindow(win: BrowserWindow) {
  if (win.isDestroyed()) return Promise.resolve();
  const token = randomUUID();
  return new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      flushRequests.delete(token);
      reject(
        Error(
          'Окно не подтвердило сохранение черновиков. Повторите закрытие после завершения операции.',
        ),
      );
    }, 10000);
    flushRequests.set(token, { senderId: win.webContents.id, resolve, reject, timer });
    win.webContents.send('platform:event', { type: 'workspace.beforeClose', token });
  });
}
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
function secretPath(id: string) {
  return join(root, 'secrets', createHash('sha256').update(id).digest('hex'));
}
async function host(method: string, p: any): Promise<any> {
  if (method === 'secret.read') {
    const encrypted = await fs.readFile(secretPath(p.id)).catch(() => null);
    if (!encrypted) return null;
    if (!safeStorage.isEncryptionAvailable()) throw Error('Связка ключей macOS недоступна');
    return safeStorage.decryptString(encrypted);
  }
  if (method === 'secret.write') {
    if (!safeStorage.isEncryptionAvailable()) throw Error('Связка ключей macOS недоступна');
    await fs.mkdir(join(root, 'secrets'), { recursive: true, mode: 0o700 });
    const target = secretPath(p.id),
      temp = target + '.tmp';
    await fs.writeFile(temp, safeStorage.encryptString(p.value), { mode: 0o600 });
    await fs.rename(temp, target);
    return true;
  }
  if (method === 'connection.read') {
    const instance = await call('apps.get', { appId: p.appId });
    if (!instance.definition.connections?.some((c: any) => c.id === p.connectionId))
      throw Error('Подключение не объявлено');
    return connections.read(p.appId, p.connectionId, p.origin);
  }
  if (method === 'clipboard.read') return clipboard.readText();
  if (method === 'clipboard.write') {
    clipboard.writeText(String(p.text || ''));
    return true;
  }
  if (method === 'notifications.show') {
    if (Notification.isSupported())
      new Notification({
        title: String(p.title || 'Everything App'),
        body: String(p.body || ''),
      }).show();
    return true;
  }
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
const connections = new ConnectionCredentials({
  getMetadata: (key) => call('settings.get', { key }),
  setMetadata: (key, value) => call('settings.set', { key, value }),
  readSecret: (id) => host('secret.read', { id }),
  writeSecret: (id, value) => host('secret.write', { id, value }),
  removeSecret: (id) => fs.rm(secretPath(id), { force: true }),
});
let trayRefresh = 0;
let trayAppsKey: string | undefined;
async function refreshTrayMenu() {
  if (!tray || tray.isDestroyed()) return;
  if (!CUSTOM_APPS_ENABLED) {
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
          click: () => void openSettings('about').catch(console.error),
        },
        { type: 'separator' },
        { label: 'Выйти из Everything App', click: () => app.quit() },
      ]),
    );
    return;
  }
  const refresh = ++trayRefresh;
  try {
    const apps: AppInstance[] = await call('apps.list');
    if (refresh !== trayRefresh || !tray || tray.isDestroyed()) return;
    const listed = apps
      .filter((instance) => instance.status !== 'archived')
      .sort(
        (a, b) =>
          Number(b.favorite) - Number(a.favorite) ||
          a.name.localeCompare(b.name, 'ru') ||
          a.id.localeCompare(b.id),
      );
    const key = JSON.stringify(listed.map(({ id, name }) => [id, name]));
    if (key === trayAppsKey) return;
    tray.setContextMenu(
      Menu.buildFromTemplate([
        { label: 'Открыть Everything App', click: () => void openWindow() },
        { label: 'Запуск приложений', click: () => void shelf.show().catch(console.error) },
        {
          label: 'История буфера обмена',
          click: () => void shelf.show('keyboard', 'clipboard').catch(console.error),
        },
        {
          label: 'Работающие приложения',
          click: () => {
            void openWindow().then(() => broadcast({ type: 'navigate', page: 'inbox' }));
          },
        },
        { type: 'separator' },
        ...(listed.length
          ? listed.map((instance) => ({
              id: `app:${instance.id}`,
              label: instance.name,
              click: () => {
                void openWindow(instance.id).catch((error) => {
                  dialog.showErrorBox('Не удалось открыть приложение', String(error));
                });
              },
            }))
          : [{ label: 'Пока нет приложений', enabled: false }]),
        { type: 'separator' },
        { label: 'Выйти из платформы', click: () => app.quit() },
      ]),
    );
    trayAppsKey = key;
  } catch (error) {
    console.error('Could not refresh tray apps', error);
  }
}
async function windowPreferences(appId: string) {
  await call('apps.get', { appId });
  const alwaysOnTop = await call('settings.get', { key: `window:${appId}:alwaysOnTop` });
  return { alwaysOnTop: alwaysOnTop === true };
}
function applyWindowPreferences(win: BrowserWindow, alwaysOnTop: boolean) {
  win.setAlwaysOnTop(alwaysOnTop, 'floating');
  win.setVisibleOnAllWorkspaces(alwaysOnTop, { visibleOnFullScreen: alwaysOnTop });
}
let settingsOpening: Promise<void> | undefined;
async function openSettings(pane?: 'about') {
  shelf.hide();
  if (settingsOpening) await settingsOpening;
  const existing = [...windows.values()].find((entry) => entry.mode === 'settings');
  if (existing) {
    existing.window.show();
    existing.window.focus();
    if (pane)
      existing.window.webContents.send('platform:event', { type: 'settings.navigate', pane });
    return;
  }
  settingsOpening = (async () => {
    const win = new BrowserWindow({
      width: 760,
      height: 620,
      minWidth: 660,
      minHeight: 480,
      title: 'Настройки — Everything App',
      show: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      titleBarStyle: 'hiddenInset',
      backgroundColor: '#00000000',
      ...(process.platform === 'darwin' ? { vibrancy: 'sidebar' as const } : {}),
      webPreferences: {
        preload: join(__dirname, '../preload/index.js'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
      },
    });
    windows.set(win.id, { window: win, mode: 'settings' });
    bindSettingsShortcut(win.webContents, showSettings);
    win.on('closed', () => windows.delete(win.id));
    win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    win.webContents.on('will-navigate', (event) => event.preventDefault());
    win.webContents.on('will-attach-webview', (event) => event.preventDefault());
    const query = { mode: 'settings', ...(pane ? { pane } : {}) };
    try {
      if (process.env.ELECTRON_RENDERER_URL)
        await win.loadURL(`${process.env.ELECTRON_RENDERER_URL}?${new URLSearchParams(query)}`);
      else await win.loadFile(join(__dirname, '../renderer/index.html'), { query });
      win.show();
      win.focus();
    } catch (error) {
      win.destroy();
      throw error;
    }
  })();
  try {
    await settingsOpening;
  } finally {
    settingsOpening = undefined;
  }
}
function showSettings() {
  void openSettings().catch((error) =>
    dialog.showErrorBox('Не удалось открыть настройки', String(error)),
  );
}
async function openWindow(appId?: string, page?: 'settings') {
  if (!CUSTOM_APPS_ENABLED) {
    if (appId) throw Error(FROZEN_FEATURE_MESSAGE);
    await shelf.show('keyboard', page || 'apps');
    return;
  }
  const mode = 'window';
  // Opening an app also resumes it, including when its window already exists.
  const instance = appId ? await call('apps.start', { appId }) : undefined;
  const existing = [...windows.values()].find((w) => w.appId === appId && w.mode === 'window');
  if (existing) {
    if (existing.window.isMinimized()) existing.window.restore();
    existing.window.show();
    existing.window.focus();
    if (page) existing.window.webContents.send('platform:event', { type: 'navigate', page });
    return existing.window.id;
  }
  const geometry = await call('settings.get', { key: `window:${appId || 'shell'}:${mode}` });
  const preferences = appId ? await windowPreferences(appId) : { alwaysOnTop: false };
  const display = screen.getPrimaryDisplay().workArea;
  const width = Math.min(geometry?.width || 1280, display.width),
    height = Math.min(geometry?.height || 840, display.height);
  const visible =
    geometry &&
    screen
      .getAllDisplays()
      .some(
        (d) =>
          geometry.x >= d.workArea.x &&
          geometry.y >= d.workArea.y &&
          geometry.x + 80 < d.workArea.x + d.workArea.width &&
          geometry.y + 80 < d.workArea.y + d.workArea.height,
      );
  const win = new BrowserWindow({
    width,
    height,
    ...(visible ? { x: geometry.x, y: geometry.y } : {}),
    minWidth: 560,
    minHeight: 420,
    title: instance?.name || 'Everything App',
    titleBarStyle: 'hiddenInset',
    // Center the 14px macOS controls in the standalone renderer's 48px title bar.
    ...(appId && process.platform === 'darwin' ? { trafficLightPosition: { x: 12, y: 17 } } : {}),
    backgroundColor: '#f5f5f3',
    alwaysOnTop: preferences.alwaysOnTop,
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webviewTag: false,
    },
  });
  if (appId) applyWindowPreferences(win, preferences.alwaysOnTop);
  windows.set(win.id, { window: win, appId, mode });
  bindSettingsShortcut(win.webContents, showSettings);
  if (!appId) bindAssistantShortcut(win.webContents, win.webContents);
  if (updateInstalling) win.setEnabled(false);
  let closing = false;
  win.on('close', (event) => {
    if (quitting || closing) return;
    event.preventDefault();
    void flushWindow(win)
      .then(() => {
        closing = true;
        win.close();
      })
      .catch((error) => {
        broadcast({ type: 'platform.error', message: String(error) });
      });
  });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  win.webContents.on('will-attach-webview', (e) => e.preventDefault());
  const save = () => {
    if (!win.isDestroyed())
      void call('settings.set', {
        key: `window:${appId || 'shell'}:${mode}`,
        value: win.getBounds(),
      });
  };
  win.on('resized', save);
  win.on('moved', save);
  const ownerContentsId = win.webContents.id;
  win.webContents.on('destroyed', () => extensionViews?.disposeOwner(ownerContentsId));
  win.webContents.on('did-start-navigation', (details) => {
    if (details.isMainFrame && !details.isSameDocument)
      extensionViews?.disposeOwner(ownerContentsId);
  });
  win.on('closed', () => windows.delete(win.id));
  const query: Record<string, string> = appId ? { appId } : page ? { page } : {};
  if (process.env.ELECTRON_RENDERER_URL)
    await win.loadURL(`${process.env.ELECTRON_RENDERER_URL}?${new URLSearchParams(query)}`);
  else await win.loadFile(join(__dirname, '../renderer/index.html'), { query });
  if (pendingPackage) {
    const file = pendingPackage;
    pendingPackage = undefined;
    setTimeout(() => void previewPackage(file), 500);
  }
  return win.id;
}
async function previewPackage(path: string) {
  try {
    const preview = await call('packages.importPreview', { path });
    broadcast({ type: 'package.opened', preview });
  } catch (e) {
    broadcast({ type: 'platform.error', message: String(e) });
  }
}
const rpcSchema = z.tuple([
  z
    .string()
    .min(1)
    .max(80)
    .regex(/^[a-zA-Z][a-zA-Z0-9.]*$/),
  z.record(z.string(), z.unknown()),
]);
const forbidden = new Set([
  'packages.export',
  'packages.importPreview',
  'packages.updatePreview',
  'attachments.add',
  'docs.openPath',
  'docs.savePath',
  'docs.path',
]);
async function packageOperation(method: string, params: any) {
  const taskId = params.taskId || randomUUID();
  try {
    return await call(method, { ...params, taskId });
  } catch (error) {
    const task = await call('packages.taskStatus', { taskId }).catch(() => undefined);
    if (task?.status === 'cancelled') return null;
    throw error;
  }
}
async function rendererCall(event: Electron.IpcMainInvokeEvent, method: string, params: any = {}) {
  const sender = [...windows.values()].find((w) => w.window.webContents === event.sender);
  if (!sender || event.senderFrame !== event.sender.mainFrame)
    throw Error('Недоверенный отправитель');
  rpcSchema.parse([method, params]);
  if (!CUSTOM_APPS_ENABLED && !shelfMethodAllowed(method)) throw Error(FROZEN_FEATURE_MESSAGE);
  if (JSON.stringify(params).length > 48 * 1024 * 1024) throw Error('Запрос превышает лимит');
  if (method === 'clipboardHistory.select' && sender.mode !== 'shelf')
    throw Error('Вставка доступна только из истории на полке');
  if (method === 'mediaIndicator.getState') return mediaIndicator.state();
  if (method === 'mediaIndicator.setEnabled')
    return mediaIndicator.setEnabled(z.boolean().parse(params.enabled));
  if (method === 'settings.set' && params.key === 'mediaIndicatorEnabled')
    return mediaIndicator.setEnabled(z.boolean().parse(params.value));
  if (method === 'shelf.appearance') return desktopAppearance();
  if (method === 'shelf.settings') {
    await openSettings(params.section === 'about' ? 'about' : undefined);
    return true;
  }
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
  if (method === 'launcher.apps' && !CUSTOM_APPS_ENABLED) return BUILTIN_APPS;
  if (method === 'launcher.apps') {
    const apps: AppInstance[] = await call('apps.list');
    return [
      ...BUILTIN_APPS,
      ...apps
        .filter((instance) => instance.status !== 'archived')
        .map(({ id, name, icon, description, favorite, status }) => ({
          kind: 'everything',
          id,
          name,
          icon,
          description,
          favorite,
          status,
        })),
    ];
  }
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
  if (method === 'launcher.open') {
    const revision = shelf.getRevision();
    const appId = z.string().min(1).max(200).parse(params.appId);
    const instance: AppInstance = await call('apps.get', { appId });
    if (instance.status === 'archived')
      throw Error('Приложение находится в архиве. Восстановите его в рабочем пространстве.');
    const started = await call('apps.start', { appId });
    if (revision === shelf.getRevision()) shelf.setExpanded(true);
    return started;
  }
  if (method === 'launcher.back') {
    shelf.setExpanded(false);
    return true;
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
  if (
    method.startsWith('state.') ||
    method.startsWith('secret.') ||
    method.startsWith('runtime.') ||
    forbidden.has(method)
  )
    throw Error('Операция доступна только ядру');
  if (method.startsWith('extensions.view.'))
    return extensionViews.handle(event.sender, method, params);
  if (method === 'links.openExternal') {
    const url = externalWebUrl(params.url);
    if (!url) throw Error('Можно открыть только веб-ссылки HTTP или HTTPS без логина и пароля');
    await shell.openExternal(url);
    return { opened: true };
  }
  if (method === 'docs.openMany') return chooseDocuments(sender.window, call, params);
  if (method.startsWith('connections.')) {
    const instance = await call('apps.get', { appId: params.appId });
    const declared = instance.definition.connections || [];
    if (method === 'connections.list')
      return Promise.all(
        declared.map(async (connection: any) => {
          const meta = await call('settings.get', {
            key: `connection:${instance.id}:${connection.id}`,
          });
          return { ...connection, origin: meta?.origin || '', configured: !!meta?.configured };
        }),
      );
    if (!declared.some((c: any) => c.id === params.connectionId))
      throw Error('Подключение не объявлено приложением');
    if (method === 'connections.remove')
      return connections.remove(instance.id, params.connectionId);
    if (method === 'connections.save')
      return connections.save(instance.id, params.connectionId, params.origin, params.token);
    throw Error('Неизвестная операция подключения');
  }
  if (method === 'packages.chooseImport') {
    const r = await dialog.showOpenDialog(sender.window, {
      properties: ['openFile'],
      filters: [{ name: 'Приложение Everything', extensions: ['everyapp'] }],
    });
    return r.canceled
      ? null
      : packageOperation('packages.importPreview', { path: r.filePaths[0], taskId: params.taskId });
  }
  if (method === 'packages.chooseUpdate') {
    const r = await dialog.showOpenDialog(sender.window, {
      properties: ['openFile'],
      filters: [{ name: 'Приложение Everything', extensions: ['everyapp'] }],
    });
    return r.canceled
      ? null
      : packageOperation('packages.updatePreview', {
          appId: params.appId,
          path: r.filePaths[0],
          taskId: params.taskId,
        });
  }
  if (method === 'packages.saveExport') {
    const preview = await call('packages.preview', params);
    const r = await dialog.showSaveDialog(sender.window, {
      defaultPath: `${String(preview.name || 'Приложение').replace(/[\\/:]/g, '-')}.everyapp`,
      filters: [{ name: 'Приложение Everything', extensions: ['everyapp'] }],
    });
    return r.canceled ? null : packageOperation('packages.export', { ...params, path: r.filePath });
  }
  if (method === 'attachments.choose') {
    const r = await dialog.showOpenDialog(sender.window, { properties: ['openFile'] });
    return r.canceled
      ? null
      : call('attachments.add', { appId: params.appId, path: r.filePaths[0] });
  }
  if (method === 'docs.open') {
    const r = await dialog.showOpenDialog(sender.window, { properties: ['openFile'] });
    return r.canceled
      ? null
      : call('docs.openPath', {
          appId: params.appId,
          path: r.filePaths[0],
          encoding: params.encoding,
          kind: params.kind,
        });
  }
  if (method === 'docs.save') {
    let path = await call('docs.path', params);
    const doc = await call('docs.get', params);
    const mime =
      doc.kind === 'image'
        ? String(doc.content || '')
            .match(/^data:image\/(png|jpeg|gif|webp);base64,/i)?.[1]
            .toLowerCase()
        : undefined;
    const extension = mime === 'jpeg' ? 'jpg' : mime;
    const currentExtension = path ? extname(path).slice(1).toLowerCase() : '';
    const matches =
      !mime ||
      (mime === 'jpeg' ? ['jpg', 'jpeg'].includes(currentExtension) : currentExtension === mime);
    if (!path || params.saveAs || !matches) {
      const defaultPath = extension
        ? `${String(doc.name).replace(/\.[^.]+$/, '')}.${extension}`
        : doc.name;
      const r = await dialog.showSaveDialog(sender.window, {
        defaultPath,
        ...(extension
          ? {
              filters: [
                {
                  name: `${extension.toUpperCase()} image`,
                  extensions: extension === 'jpg' ? ['jpg', 'jpeg'] : [extension],
                },
              ],
            }
          : {}),
      });
      if (r.canceled) return null;
      path = r.filePath;
    }
    return call('docs.savePath', { appId: params.appId, id: params.id, path, force: params.force });
  }
  if (method === 'windows.confirmClose') {
    const request = flushRequests.get(params.token);
    if (!request || request.senderId !== event.sender.id)
      throw Error('Неверное подтверждение закрытия');
    clearTimeout(request.timer);
    flushRequests.delete(params.token);
    params.error ? request.reject(Error(String(params.error))) : request.resolve();
    return true;
  }
  // Legacy mode parameters also resolve to the app's single separate window.
  if (method === 'windows.open') return openWindow(params.appId);
  if (method === 'windows.getPreferences') {
    const appId = z.string().min(1).max(200).parse(params.appId);
    return windowPreferences(appId);
  }
  if (method === 'windows.setPreferences') {
    const { appId, alwaysOnTop } = z
      .object({ appId: z.string().min(1).max(200), alwaysOnTop: z.boolean() })
      .parse(params);
    await call('apps.get', { appId });
    await call('settings.set', { key: `window:${appId}:alwaysOnTop`, value: alwaysOnTop });
    for (const entry of windows.values())
      if (entry.appId === appId && !entry.window.isDestroyed())
        applyWindowPreferences(entry.window, alwaysOnTop);
    const preferences = { alwaysOnTop };
    broadcast({ type: 'windows.preferencesChanged', appId, preferences });
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
      windows: [...windows.values()].map((w) => ({ appId: w.appId, mode: w.mode })),
      backgroundPolicy:
        'Локальные задания выполняются только при включённом компьютере. Во сне запуски пропускаются или переносятся по политике правила.',
    };
  if (method === 'system.quit') {
    app.quit();
    return true;
  }
  if (method === 'system.login') {
    app.setLoginItemSettings({ openAtLogin: !!params.enabled, args: ['--hidden'] });
    return app.getLoginItemSettings().openAtLogin;
  }
  if (method === 'system.shortcut') {
    const accelerator = z.string().max(80).parse(params.accelerator);
    if (globalShortcut.isRegistered(accelerator)) throw Error('Сочетание уже занято');
    const ok = globalShortcut.register(accelerator, () => void openWindow(params.appId));
    if (!ok) throw Error('Сочетание недоступно или занято другой программой');
    await call('settings.set', { key: `shortcut:${params.appId || 'shell'}`, value: accelerator });
    return true;
  }
  if (method.startsWith('updates.')) return updates.handle(method);
  return call(method, params);
}
if (!app.requestSingleInstanceLock()) app.quit();
app.on('second-instance', (_e, argv) => {
  void openWindow();
  const file = argv.find((a) => a.endsWith('.everyapp'));
  if (file && CUSTOM_APPS_ENABLED) void previewPackage(file);
});
app.on('open-file', (event, path) => {
  event.preventDefault();
  if (!CUSTOM_APPS_ENABLED) {
    if (worker) void shelf.show().catch(console.error);
    return;
  }
  if (worker) void openWindow().then(() => previewPackage(path));
  else pendingPackage = path;
});
app
  .whenReady()
  .then(async () => {
    if (process.platform === 'darwin') app.setActivationPolicy('accessory');
    await fs.mkdir(root, { recursive: true, mode: 0o700 });
    session.defaultSession.setPermissionRequestHandler((_wc, _p, cb) => cb(false));
    session.defaultSession.setPermissionCheckHandler(() => false);
    if (app.isPackaged)
      process.env.ESBUILD_BINARY_PATH = join(
        process.resourcesPath,
        'app.asar.unpacked/node_modules/@esbuild/darwin-arm64/bin/esbuild',
      );
    worker = new Worker(join(__dirname, 'worker.js'), {
      workerData: { root, customAppsEnabled: CUSTOM_APPS_ENABLED },
    });
    worker.on('message', async (m) => {
      if (m.kind === 'result') {
        const request = pending.get(m.id);
        if (request) {
          pending.delete(m.id);
          m.error ? request.reject(Error(m.error)) : request.resolve(m.result);
        }
      } else if (m.kind === 'event') {
        broadcast(m.event);
        if (m.event.type === 'workspace.changed') void refreshTrayMenu();
        if (m.event.type === 'workspace.changed' && m.event.appId)
          void extensionViews?.refreshApp(m.event.appId);
      } else if (m.kind === 'host') {
        try {
          worker.postMessage({
            kind: 'hostResult',
            id: m.id,
            result: await host(m.method, m.params),
          });
        } catch (e) {
          worker.postMessage({ kind: 'hostResult', id: m.id, error: String(e) });
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
    extensionViews = createExtensionViews({
      call,
      preloadPath: join(__dirname, '../preload/extension.js'),
      onViewCreated: (contents, owner) => {
        bindSettingsShortcut(contents, showSettings);
        const workspace = [...windows.values()].find(
          (entry) => entry.window.webContents === owner && entry.mode === 'window' && !entry.appId,
        );
        if (workspace) bindAssistantShortcut(contents, owner);
        const panel = [...windows.values()].find(
          (entry) => entry.window.webContents === owner && entry.mode === 'shelf',
        );
        if (panel)
          contents.on('before-input-event', (event, input) => {
            if (input.type === 'keyDown' && input.key === 'Escape' && !input.isComposing) {
              event.preventDefault();
              shelf.hide();
            }
          });
      },
    });
    ipcMain.handle('platform:call', rendererCall);
    void installedApps
      .list()
      .catch((error) => console.error('Could not list installed apps', error));
    ipcMain.handle('docs:drop', async (event, params, paths) => {
      if (!CUSTOM_APPS_ENABLED) throw Error(FROZEN_FEATURE_MESSAGE);
      const sender = [...windows.values()].find((w) => w.window.webContents === event.sender);
      if (!sender || event.senderFrame !== event.sender.mainFrame)
        throw Error('Недоверенный отправитель');
      const input = z
        .object({ appId: z.string().max(200), encoding: z.string().max(50).optional() })
        .parse(params);
      const selected = z.array(z.string().min(1).max(4096)).max(100).parse(paths);
      return openDroppedDocuments(call, input, selected);
    });
    Menu.setApplicationMenu(
      Menu.buildFromTemplate([
        {
          label: 'Everything App',
          submenu: [
            {
              label: 'О приложении и обновления',
              click: () => void openSettings('about').catch(console.error),
            },
            {
              id: 'settings',
              label: 'Настройки…',
              accelerator: 'CommandOrControl+,',
              click: showSettings,
            },
            { type: 'separator' },
            {
              label: CUSTOM_APPS_ENABLED ? 'Открыть рабочее пространство' : 'Открыть полку',
              click: () => void openWindow(),
            },
            { label: 'Запуск приложений', click: () => void shelf.show().catch(console.error) },
            {
              label: 'История буфера обмена',
              click: () => void shelf.show('keyboard', 'clipboard').catch(console.error),
            },
            { type: 'separator' },
            { role: 'hide' },
            { role: 'quit', label: 'Выйти из платформы' },
          ],
        },
        {
          label: 'Файл',
          visible: CUSTOM_APPS_ENABLED,
          submenu: [
            {
              label: 'Импортировать приложение…',
              enabled: CUSTOM_APPS_ENABLED,
              acceleratorWorksWhenHidden: false,
              accelerator: 'CmdOrCtrl+O',
              click: async () => {
                const r = await dialog.showOpenDialog({
                  properties: ['openFile'],
                  filters: [{ name: 'Everything App', extensions: ['everyapp'] }],
                });
                if (!r.canceled) {
                  await openWindow();
                  await previewPackage(r.filePaths[0]);
                }
              },
            },
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
    tray.setToolTip('Polka — полка');
    await refreshTrayMenu();
    powerMonitor.on('resume', () => {
      shelf.resume();
      mediaIndicator.resume();
      if (CUSTOM_APPS_ENABLED) void call('runtime.signal', { event: 'resume' });
      broadcast({ type: 'system.resume' });
    });
    powerMonitor.on('suspend', () => {
      shelf.suspend();
      mediaIndicator.suspend();
      if (CUSTOM_APPS_ENABLED) void call('runtime.signal', { event: 'suspend' });
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
        await Promise.all([...windows.values()].map(({ window }) => flushWindow(window)));
      },
      () => {
        updateInstalling = false;
        for (const { window } of windows.values())
          if (!window.isDestroyed()) window.setEnabled(true);
      },
    );
    const settings = await call('settings.get');
    for (const [key, value] of Object.entries(settings || {})) {
      if (CUSTOM_APPS_ENABLED && key.startsWith('shortcut:') && typeof value === 'string')
        globalShortcut.register(
          value,
          () => void openWindow(key.slice(9) === 'shell' ? undefined : key.slice(9)),
        );
    }
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
  /* Closing a workspace does not stop background work. */
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
  // Keep core alive during download/staging; persisted jobs recover if exit wins this flush.
  try {
    worker?.postMessage({ kind: 'shutdown' });
  } catch {
    /* Native install must still exit if core has already stopped. */
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
  void Promise.all([...windows.values()].map(({ window }) => flushWindow(window)))
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
