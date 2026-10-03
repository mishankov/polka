import {
  BrowserWindow,
  WebContentsView,
  ipcMain,
  session,
  type Session,
  type WebContents,
} from 'electron';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
const boundsSchema = z.object({
  x: z.number().finite(),
  y: z.number().finite(),
  width: z.number().finite().min(0),
  height: z.number().finite().min(0),
});
const themeSchema = z.object({ scheme: z.enum(['light', 'dark']) });
type Theme = { scheme: 'light' | 'dark'; primaryColor?: string; radius?: string; density?: string };
type Slot = {
  id: string;
  owner: WebContents;
  ownerId: number;
  ownerWindow: BrowserWindow;
  view?: WebContentsView;
  contents?: WebContents;
  contentsId?: number;
  isolatedSession?: Session;
  appId: string;
  extensionId: string;
  theme: Theme;
  heartbeat: number;
  count: number;
  stopped: boolean;
};
/** A unique in-memory storage partition forces a separate renderer process per untrusted view. */
export function createExtensionViews({
  call,
  preloadPath,
  onViewCreated,
}: {
  call: (method: string, params?: any) => Promise<any>;
  preloadPath: string;
  onViewCreated: (contents: WebContents, owner: WebContents) => void;
}) {
  const slots = new Map<string, Slot>(),
    senders = new Map<number, Slot>();
  function publish(slot: Slot, status: string, message?: string) {
    if (!slot.owner.isDestroyed())
      slot.owner.send('platform:event', {
        type: 'extension.status',
        viewId: slot.id,
        status,
        message,
      });
  }
  function destroy(slot: Slot, status = 'stopped', message?: string) {
    slot.stopped = true;
    const view = slot.view,
      contents = slot.contents,
      contentsId = slot.contentsId,
      isolated = slot.isolatedSession;
    slot.view = undefined;
    slot.contents = undefined;
    slot.contentsId = undefined;
    slot.isolatedSession = undefined;
    if (contentsId !== undefined) senders.delete(contentsId);
    // The owner's destroyed event runs after its WebContents is gone. Resolve
    // ownership at creation, never through fromWebContents during teardown.
    if (view && !slot.owner.isDestroyed() && !slot.ownerWindow.isDestroyed())
      slot.ownerWindow.contentView.removeChildView(view);
    isolated?.protocol.unhandle('everything-extension');
    if (contents && !contents.isDestroyed()) {
      // A synchronous loop cannot prevent this main-process recovery path.
      contents.forcefullyCrashRenderer();
      if (!contents.isDestroyed()) contents.close({ waitForBeforeUnload: false });
    }
    publish(slot, status, message);
  }
  function bound(event: Electron.IpcMainEvent | Electron.IpcMainInvokeEvent) {
    const slot = senders.get(event.sender.id);
    if (!slot || slot.stopped || event.senderFrame !== event.sender.mainFrame)
      throw Error('Недоверенный отправитель расширения');
    return slot;
  }
  ipcMain.handle('extension:call', async (event, method: unknown, params: any = {}) => {
    const slot = bound(event);
    if (
      typeof method !== 'string' ||
      method.length > 80 ||
      !params ||
      typeof params !== 'object' ||
      Array.isArray(params)
    )
      throw Error('Неверный запрос');
    if (JSON.stringify(params).length > 2 * 1024 * 1024) throw Error('Запрос превышает 2 МБ');
    if (slot.count >= 32) throw Error('Слишком много одновременных запросов');
    slot.count++;
    try {
      return await call('extensions.call', {
        appId: slot.appId,
        extensionId: slot.extensionId,
        method,
        params,
      });
    } finally {
      slot.count--;
    }
  });
  ipcMain.handle('extension:theme', (event) => bound(event).theme);
  ipcMain.on('extension:heartbeat', (event) => {
    try {
      bound(event).heartbeat = Date.now();
    } catch {}
  });
  ipcMain.on('extension:ready', (event) => {
    try {
      publish(bound(event), 'ready');
    } catch {}
  });
  ipcMain.on('extension:failure', (event, message) => {
    try {
      publish(bound(event), 'error', String(message).slice(0, 2000));
    } catch {}
  });
  const timer = setInterval(() => {
    for (const slot of slots.values())
      if (slot.view && Date.now() - slot.heartbeat > 6500)
        destroy(
          slot,
          'unresponsive',
          'Экран не отвечает. Можно перезапустить его; остальные приложения продолжают работать.',
        );
  }, 1000);
  timer.unref();
  function ownerSlot(sender: WebContents, id: unknown) {
    const slot = typeof id === 'string' ? slots.get(id) : undefined;
    if (!slot || slot.owner !== sender) throw Error('Экран расширения не найден');
    return slot;
  }
  function setBounds(slot: Slot, value: unknown, visible: unknown) {
    if (
      !slot.view ||
      slot.owner.isDestroyed() ||
      slot.ownerWindow.isDestroyed() ||
      slot.contents?.isDestroyed()
    )
      return;
    const bounds = boundsSchema.parse(value),
      win = slot.ownerWindow;
    const [width, height] = win.getContentSize();
    const x = Math.max(0, Math.min(width, Math.round(bounds.x))),
      y = Math.max(0, Math.min(height, Math.round(bounds.y)));
    slot.view.setBounds({
      x,
      y,
      width: Math.max(0, Math.min(width - x, Math.round(bounds.width))),
      height: Math.max(0, Math.min(height - y, Math.round(bounds.height))),
    });
    slot.view.setVisible(visible === true && bounds.width > 0 && bounds.height > 0);
  }
  async function handle(sender: WebContents, method: string, p: any) {
    if (method === 'extensions.view.open') {
      const appId = z.string().max(200).parse(p.appId),
        extensionId = z.string().max(100).parse(p.extensionId);
      if (sender.isDestroyed()) throw Error('Окно уже закрыто');
      const win = BrowserWindow.fromWebContents(sender);
      if (!win || win.webContents !== sender) throw Error('Недоверенное окно');
      // Bound early so cleanup can cancel compilation/loading, too.
      const id = z.string().uuid().parse(p.viewId);
      if (slots.has(id)) throw Error('Экран уже открыт');
      if ([...slots.values()].filter((s) => s.owner === sender).length >= 8)
        throw Error('Не более восьми экранов расширений в окне');
      const slot: Slot = {
        id,
        owner: sender,
        ownerId: sender.id,
        ownerWindow: win,
        appId,
        extensionId,
        theme: themeSchema.parse(p.theme),
        heartbeat: Date.now(),
        count: 0,
        stopped: false,
      };
      slots.set(id, slot);
      try {
        const [result, app] = await Promise.all([
          call('extensions.build', { appId, extensionId }),
          call('apps.get', { appId }),
        ]);
        if (slot.stopped || sender.isDestroyed() || win.isDestroyed()) return { viewId: id };
        if (result.kind !== 'component') throw Error('Выберите компонент');
        slot.theme = { ...app.definition.theme, ...slot.theme };
        const isolated = session.fromPartition(`extension-${randomUUID()}`, { cache: false });
        slot.isolatedSession = isolated;
        isolated.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
        isolated.setPermissionCheckHandler(() => false);
        isolated.on('will-download', (e) => e.preventDefault());
        const documentURL = `everything-extension://view/${id}/index.html`;
        isolated.protocol.handle('everything-extension', (request) => {
          if (request.url !== documentURL || request.method !== 'GET')
            return new Response('Not found', { status: 404 });
          return new Response(result.html, {
            headers: { 'content-type': 'text/html; charset=utf-8' },
          });
        });
        isolated.webRequest.onBeforeRequest((details, callback) =>
          callback({ cancel: details.url !== documentURL || details.resourceType !== 'mainFrame' }),
        );
        const view = new WebContentsView({
          webPreferences: {
            preload: preloadPath,
            session: isolated,
            sandbox: true,
            nodeIntegration: false,
            contextIsolation: true,
            webSecurity: true,
            webviewTag: false,
            backgroundThrottling: false,
            spellcheck: false,
            devTools: false,
          },
        });
        slot.view = view;
        slot.contents = view.webContents;
        slot.contentsId = view.webContents.id;
        slot.heartbeat = Date.now();
        senders.set(view.webContents.id, slot);
        onViewCreated(view.webContents, sender);
        view.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
        view.webContents.on('will-navigate', (e) => e.preventDefault());
        view.webContents.on('will-redirect', (e) => e.preventDefault());
        view.webContents.on('will-attach-webview', (e) => e.preventDefault());
        view.webContents.on('render-process-gone', () => {
          if (!slot.stopped) destroy(slot, 'error', 'Экран завершил работу. Перезапустите его.');
        });
        win.contentView.addChildView(view);
        setBounds(slot, p.bounds, p.visible);
        await view.webContents.loadURL(documentURL).catch(() => {
          throw Error('Не удалось загрузить изолированный экран');
        });
        return { viewId: id };
      } catch (error) {
        if (slot.stopped) return { viewId: id };
        destroy(slot, 'error', error instanceof Error ? error.message : String(error));
        throw error;
      }
    }
    const slot = ownerSlot(sender, p.viewId);
    if (method === 'extensions.view.close') {
      destroy(slot);
      slots.delete(slot.id);
      return true;
    }
    if (method === 'extensions.view.bounds') {
      setBounds(slot, p.bounds, p.visible);
      return true;
    }
    if (method === 'extensions.view.theme') {
      slot.theme = { ...slot.theme, ...themeSchema.parse(p.theme) };
      if (slot.contents && !slot.contents.isDestroyed())
        slot.contents.send('extension:theme', slot.theme);
      return true;
    }
    throw Error('Неизвестная операция экрана');
  }
  function disposeOwner(senderId: number) {
    for (const slot of slots.values())
      if (slot.ownerId === senderId) {
        destroy(slot);
        slots.delete(slot.id);
      }
  }
  async function refreshApp(appId: string) {
    const affected = [...slots.values()].filter((slot) => slot.appId === appId);
    if (!affected.length) return;
    const app = await call('apps.get', { appId }).catch(() => null);
    for (const slot of affected) {
      if (!app || app.status !== 'running') destroy(slot, 'stopped', 'Приложение остановлено');
      else {
        slot.theme = { scheme: slot.theme.scheme, ...app.definition.theme };
        if (slot.contents && !slot.contents.isDestroyed())
          slot.contents.send('extension:theme', slot.theme);
      }
    }
  }
  return { handle, disposeOwner, refreshApp };
}
