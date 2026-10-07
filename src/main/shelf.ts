import {
  app,
  BrowserWindow,
  clipboard,
  ClipboardItem,
  globalShortcut,
  nativeImage,
  Notification,
  safeStorage,
  screen,
  dialog,
  shell,
} from 'electron';
import { promises as fs } from 'node:fs';
import { spawn, type ChildProcess } from 'node:child_process';
import { createInterface } from 'node:readline';
import { join } from 'node:path';
import { z } from 'zod';
import {
  ClipboardHistory,
  clipboardContentType,
  excludedClipboardType,
  MAX_IMAGE_BYTES,
} from './clipboard-history';
import { ClipboardHover, contains, shelfGeometry, type Notch } from './clipboard-hover';
import { ClipboardSync } from './clipboard-sync';
import { ClipboardPaste } from './clipboard-paste';
import { LauncherShortcut } from './launcher-shortcut';
import type { ClipboardState } from '../shared/clipboard';
import {
  clipboardWebUrl,
  TEXT_TRANSFORMATIONS,
  transformClipboardText,
} from '../shared/clipboard-actions';
import type { ShelfDestination, ShelfPresentation } from '../shared/shelf';
import { calculate } from '../shared/calculator';
import { emojiById } from '../shared/emoji';

export function createShelf(
  root: string,
  register: (win: BrowserWindow) => void,
  notify: () => void,
  isQuitting: () => boolean,
  screensChanged: (notches: Notch[]) => void = () => {},
) {
  let window: BrowserWindow | undefined;
  let loading: Promise<void> | undefined;
  let savingImage = false;
  let requested = false;
  let lastHiddenAt: number | undefined;
  let captureTargetPending: Promise<void> | undefined;
  let hideTimer: ReturnType<typeof setTimeout> | undefined;
  let pendingShow: { revision: number; finish: (ready: boolean) => void } | undefined;
  let expanded: boolean | 'settings' = false;
  let presentation: ShelfPresentation = {
    revision: 0,
    destination: 'apps',
    visible: false,
    focusSearch: false,
    topInset: 0,
    notchWidth: 96,
    notchHeight: 3,
  };
  let openedBy: 'hover' | 'keyboard' = 'keyboard';
  let displayId: number | undefined;
  let probe: ChildProcess | undefined;
  const paste = new ClipboardPaste((message) => {
    if (helper.status !== 'running' || !probe?.stdin?.writable) return false;
    probe.stdin.write(message);
    return true;
  });
  let hoverTimer: ReturnType<typeof setInterval> | undefined;
  let expiryTimer: ReturnType<typeof setInterval> | undefined;
  let disposed = false;
  const suspensions = new Set<string>();
  let captureBusy = false;
  let captureAgain = false;
  let generation = 0;
  let error = '';
  let helper: ClipboardState['helper'] = { status: 'starting' };
  let storageAlerted = false;
  let notches: Notch[] = [];
  let receivedScreenGeometry = false;
  const hover = new ClipboardHover();
  function changed() {
    if (history.storage.state().status === 'failed' && !storageAlerted) {
      storageAlerted = true;
      generation++;
      clearInterval(expiryTimer);
      void sync.stop().catch(failed);
      const storage = history.storage.state();
      // Do not await acknowledgement: native startup remains independent.
      void dialog
        .showMessageBox({
          type: 'error',
          title: 'История буфера недоступна',
          message: 'Не удалось открыть или сохранить историю буфера обмена',
          detail: `${storage.diagnostic?.message}. Файл не сброшен. Сохранение новых записей и синхронизация остановлены.\n\n${storage.path}\n\nВосстановите доступ к хранилищу и перезапустите Полку. Перед заменой файла сохраните его зашифрованную копию.`,
          buttons: ['Понятно'],
        })
        .catch(() => console.error('Could not display clipboard storage alert'));
    }
    notify();
  }
  const history = new ClipboardHistory(
    join(root, 'clipboard-history', 'history.enc'),
    {
      encode: (value) => {
        if (!safeStorage.isEncryptionAvailable())
          throw Error('Защищённое хранилище macOS недоступно');
        return safeStorage.encryptString(value);
      },
      decode: (value) => safeStorage.decryptString(value),
    },
    changed,
  );
  const sync = new ClipboardSync({
    path: join(root, 'clipboard-history', 'sync.enc'),
    discoveryPath: app.isPackaged
      ? join(process.resourcesPath, 'sync-discovery')
      : join(app.getAppPath(), 'build/sync-discovery'),
    history,
    changed,
    codec: {
      encode: (value) => {
        if (!safeStorage.isEncryptionAvailable())
          throw Error('Защищённое хранилище macOS недоступно');
        return safeStorage.encryptString(value);
      },
      decode: (value) => safeStorage.decryptString(value),
    },
  });
  const shortcut = new LauncherShortcut(
    globalShortcut,
    () => {
      void toggle('clipboard').catch(failed);
    },
    (accelerator) => history.preferences({ accelerator }),
  );
  function failed(reason: unknown) {
    error = reason instanceof Error ? reason.message : String(reason);
    changed();
  }
  function state(): ClipboardState {
    const snapshot = history.snapshot(false);
    return {
      ...snapshot,
      // Image originals stay in the main process; only small thumbnails cross IPC.
      clips: snapshot.clips.map((clip) => ({
        ...clip,
        content: clip.kind === 'image' ? '' : clip.content,
      })),
      sync: sync.state(),
      storage: history.storage.state(),
      preferencesAvailable: history.preferencesAvailable,
      helper: { ...helper },
      registered: shortcut.getPreferences().registered,
      pasteAccess: paste.access,
      pasteReady: paste.ready,
      error: error || shortcut.getPreferences().error,
    };
  }
  function finishHide(revision: number) {
    if (presentation.revision !== revision || requested) return;
    clearTimeout(hideTimer);
    hideTimer = undefined;
    if (window && !window.isDestroyed()) window.hide();
  }
  function hide(animate = true) {
    requested = false;
    pendingShow?.finish(false);
    hover.dismiss();
    if (!window || window.isDestroyed() || (!window.isVisible() && !presentation.visible)) return;
    if (hideTimer && animate) return;
    clearTimeout(hideTimer);
    if (presentation.visible) lastHiddenAt = Date.now();
    presentation = { ...presentation, visible: false, revision: presentation.revision + 1 };
    window.setIgnoreMouseEvents(true);
    window.webContents.send('platform:event', {
      type: 'shelf.presentation',
      presentation,
    });
    if (!animate) {
      finishHide(presentation.revision);
      return;
    }
    // The renderer confirms animation completion; this also works if it stops responding.
    const revision = presentation.revision;
    hideTimer = setTimeout(() => finishHide(revision), 240);
  }
  async function show(
    source: 'hover' | 'keyboard' = 'keyboard',
    destination?: ShelfDestination,
    searchQuery = '',
  ) {
    if (disposed || suspensions.size > 0) return;
    // Resume a built-in app for one minute after closing; explicit navigation wins.
    destination ??=
      (presentation.destination === 'clipboard' || presentation.destination === 'emoji') &&
      (presentation.visible || lastHiddenAt === undefined || Date.now() - lastHiddenAt < 60_000)
        ? presentation.destination
        : 'apps';
    pendingShow?.finish(false);
    clearTimeout(hideTimer);
    hideTimer = undefined;
    const captureTarget = !requested && !window?.isFocused();
    requested = true;
    // Target capture can wait on another app's accessibility tree. Establish the
    // opening context first so the hover timer cannot dismiss a keyboard opening.
    openedBy = source;
    const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
    displayId = display.id;
    const revision = presentation.revision + 1;
    presentation = { ...presentation, revision };
    if (captureTarget) captureTargetPending = paste.capture();
    if (captureTargetPending) await captureTargetPending;
    if (!requested || presentation.revision !== revision || disposed) return;
    expanded = destination === 'settings' || destination === 'about' ? 'settings' : false;
    const geometry = shelfGeometry(
      display.bounds,
      notches.find((item) => item.id === display.id),
      expanded,
    );
    if (!window || window.isDestroyed()) {
      const win = new BrowserWindow({
        ...geometry.panel,
        show: false,
        frame: false,
        // CSS owns the bottom curve; native rounding must not cut the top corners.
        roundedCorners: false,
        resizable: false,
        minimizable: false,
        maximizable: false,
        fullscreenable: false,
        alwaysOnTop: true,
        skipTaskbar: true,
        title: 'Полка',
        transparent: true,
        enableLargerThanScreen: true,
        hasShadow: false,
        backgroundColor: '#00000000',
        ...(process.platform === 'darwin' ? { type: 'panel' as const } : {}),
        webPreferences: {
          preload: join(__dirname, '../preload/index.js'),
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true,
        },
      });
      window = win;
      register(win);
      // Keep the background app activation policy when the panel joins Spaces.
      // Transforming the process here can disturb the current Space.
      win.setVisibleOnAllWorkspaces(true, {
        visibleOnFullScreen: true,
        skipTransformProcessType: true,
      });
      win.setAlwaysOnTop(true, 'pop-up-menu');
      win.on('blur', () => {
        if (!savingImage) hide();
      });
      win.on('close', (event) => {
        if (!isQuitting()) {
          event.preventDefault();
          hide();
        }
      });
      win.on('closed', () => {
        if (window === win) {
          window = undefined;
          requested = false;
        }
      });
      win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
      win.webContents.on('will-navigate', (event) => event.preventDefault());
      win.webContents.on('will-attach-webview', (event) => event.preventDefault());
      loading = process.env.ELECTRON_RENDERER_URL
        ? win.loadURL(`${process.env.ELECTRON_RENDERER_URL}?mode=shelf`)
        : win.loadFile(join(__dirname, '../renderer/index.html'), { query: { mode: 'shelf' } });
      loading.catch(() => {
        requested = false;
        win.destroy();
      });
    }
    await loading;
    if (
      !requested ||
      !window ||
      window.isDestroyed() ||
      disposed ||
      presentation.revision !== revision
    )
      return;
    presentation = {
      revision: revision + 1,
      destination,
      visible: true,
      focusSearch: true,
      searchQuery,
      topInset: geometry.topInset,
      notchWidth: geometry.target.width,
      notchHeight: geometry.target.height,
    };
    window.setBounds(geometry.panel);
    const shownRevision = presentation.revision;
    const ready = new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => finish(false), 2000);
      const finish = (ready: boolean) => {
        clearTimeout(timer);
        if (pendingShow?.revision === shownRevision) pendingShow = undefined;
        resolve(ready);
      };
      pendingShow = { revision: shownRevision, finish };
    });
    // Commit the destination before revealing the native window. Otherwise its
    // first frame can still contain the emoji picker from the previous opening.
    window.webContents.send('platform:event', {
      type: 'shelf.shown',
      presentation,
    });
    const rendered = await ready;
    if (!requested || disposed || presentation.revision !== shownRevision) return;
    if (!rendered) {
      hide(false);
      throw Error('Не удалось открыть полку. Попробуйте ещё раз.');
    }
    if (!window || window.isDestroyed()) return;
    window.setIgnoreMouseEvents(false);
    // A macOS panel takes keyboard focus without activating its owning app.
    // Keep the previous app's menu bar while making both entry points type-ready.
    window.show();
    window.focus();
  }
  function updateGeometry() {
    if (!window || window.isDestroyed()) return;
    const display = screen.getAllDisplays().find((item) => item.id === displayId);
    if (!display) return;
    const geometry = shelfGeometry(
      display.bounds,
      notches.find((item) => item.id === display.id),
      expanded,
    );
    presentation = {
      ...presentation,
      topInset: geometry.topInset,
      notchWidth: geometry.target.width,
      notchHeight: geometry.target.height,
    };
    window.setBounds(geometry.panel);
    window.webContents.send('platform:event', { type: 'shelf.presentation', presentation });
  }
  async function toggle(destination: 'apps' | 'clipboard') {
    if (
      requested &&
      !expanded &&
      (destination === 'apps' || presentation.destination === destination)
    )
      hide();
    else if (destination === 'apps') await show();
    else await show('keyboard', destination);
  }
  async function capture() {
    if (
      disposed ||
      suspensions.size > 0 ||
      !history.storage.ready ||
      history.getPreferences().paused
    )
      return;
    if (captureBusy) {
      captureAgain = true;
      return;
    }
    captureBusy = true;
    const currentGeneration = generation;
    try {
      const items = await clipboard.read();
      if (items.some((item) => excludedClipboardType(item.types))) {
        return;
      }
      for (const item of items) {
        const mime = clipboardContentType(item.types);
        if (!mime) continue;
        const blob = await item.getType(mime);
        const kind = mime === 'text/plain' ? 'text' : 'image';
        if (blob.size > (kind === 'text' ? 1024 * 1024 : MAX_IMAGE_BYTES))
          throw Error(
            kind === 'image'
              ? 'Изображение не сохранено: размер превышает 32 МБ. Скопируйте меньшую область.'
              : 'Текст не сохранён: размер превышает 1 МБ.',
          );
        let content: string, preview: string;
        if (kind === 'image') {
          const bytes = Buffer.from(await blob.arrayBuffer());
          const image = nativeImage.createFromBuffer(bytes);
          if (image.isEmpty())
            throw Error(
              'Не удалось прочитать скопированное изображение. Попробуйте скопировать его ещё раз.',
            );
          const png = mime === 'image/png' ? bytes : image.toPNG();
          if (png.length > MAX_IMAGE_BYTES)
            throw Error(
              'Изображение не сохранено: размер PNG превышает 32 МБ. Скопируйте меньшую область.',
            );
          content = png.toString('base64');
          const size = image.getSize();
          const scale = Math.min(1, 240 / size.width, 100 / size.height);
          preview = image
            .resize({
              width: Math.max(1, Math.round(size.width * scale)),
              height: Math.max(1, Math.round(size.height * scale)),
            })
            .toDataURL();
        } else {
          content = await blob.text();
          preview = content.slice(0, 400);
        }
        if (
          currentGeneration !== generation ||
          suspensions.size > 0 ||
          disposed ||
          !history.storage.ready ||
          history.getPreferences().paused
        )
          return;
        await history.add(kind, content, preview);
        if (error) {
          error = '';
          changed();
        }
        return;
      }
    } catch (reason) {
      failed(reason);
    } finally {
      captureBusy = false;
      if (captureAgain) {
        captureAgain = false;
        void capture();
      }
    }
  }
  function tick() {
    if (suspensions.size > 0 || disposed || savingImage) return;
    const point = screen.getCursorScreenPoint();
    const display = requested
      ? screen.getAllDisplays().find((display) => display.id === displayId)
      : screen.getDisplayNearestPoint(point);
    if (!display) {
      hide();
      return;
    }
    const geometry = shelfGeometry(
      display.bounds,
      notches.find((item) => item.id === display.id),
      expanded,
    );
    if (requested && openedBy === 'keyboard') return;
    if (!history.getPreferences().hoverEnabled && !requested) return;
    const action = hover.step(
      Date.now(),
      contains(geometry.target, point),
      contains(geometry.corridor, point),
      requested,
    );
    if (action === 'show') void show('hover').catch(failed);
    if (action === 'hide') hide();
  }
  const displayChanged = () => {
    hide(false);
  };
  const displayMetricsChanged = (
    _event: Electron.Event,
    _display: Electron.Display,
    metrics: string[],
  ) => {
    if (metrics.some((metric) => ['bounds', 'scaleFactor', 'rotation'].includes(metric)))
      displayChanged();
  };
  function helperFailed(reason: unknown) {
    if (helper.status === 'failed' || disposed) return;
    paste.stop();
    helper = {
      status: 'failed',
      error: reason instanceof Error ? reason.message : String(reason),
    };
    changed();
  }
  async function startProbe() {
    try {
      const probePath = app.isPackaged
        ? join(process.resourcesPath, 'clipboard-probe')
        : join(app.getAppPath(), 'build/clipboard-probe');
      await new Promise<void>((resolve, reject) => {
        probe = spawn(probePath, [String(process.pid)], { stdio: ['pipe', 'pipe', 'ignore'] });
        probe.stdin?.on('error', helperFailed);
        const timeout = setTimeout(() => {
          const reason = Error(
            'Не удалось запустить наблюдение за буфером обмена: помощник не ответил за 5 секунд',
          );
          helperFailed(reason);
          probe?.kill();
          reject(reason);
        }, 5000);
        const lines = createInterface({ input: probe.stdout! });
        probe.on('error', (reason) => {
          clearTimeout(timeout);
          reject(reason);
          helperFailed(reason);
        });
        probe.on('exit', (code, signal) => {
          paste.stop();
          clearTimeout(timeout);
          lines.close();
          if (!disposed) {
            const reason = Error(
              `Наблюдение за буфером остановлено (${signal ?? code ?? 'неизвестная причина'}). Перезапустите приложение.`,
            );
            helperFailed(reason);
            reject(reason);
          }
        });
        lines.on('line', (line) => {
          try {
            const message = JSON.parse(line);
            if (
              message.type === 'paste.reply' &&
              process.env.EVERYTHING_PASTE_DEBUG === '1' &&
              (message.result?.token ||
                message.result?.sent !== undefined ||
                message.result?.reason)
            )
              console.log('Clipboard paste reply', {
                trusted: message.result?.trusted,
                captured: !!message.result?.token,
                sent: message.result?.sent,
                reason: message.result?.reason,
              });
            if (message.type === 'ready' && helper.status === 'starting' && !disposed) {
              clearTimeout(timeout);
              helper = { status: 'running' };
              changed();
              resolve();
            }
            if (message.type === 'paste.reply')
              paste.receive(
                z
                  .object({
                    id: z.string(),
                    result: z.object({
                      trusted: z.boolean().optional(),
                      token: z.string().uuid().optional(),
                      sent: z.boolean().optional(),
                      reason: z.string().optional(),
                    }),
                  })
                  .parse(message),
              );
            if (message.type === 'clipboard') void capture();
            if (message.type === 'screens') {
              const initialGeometry = !receivedScreenGeometry;
              notches = z
                .array(
                  z.object({
                    id: z.number(),
                    x: z.number(),
                    width: z.number(),
                    height: z.number(),
                  }),
                )
                .parse(message.displays);
              receivedScreenGeometry = true;
              screensChanged(notches);
              if (requested) {
                // The first snapshot may arrive after the user opens the shelf.
                // Apply its geometry without treating startup as a monitor change.
                if (initialGeometry) updateGeometry();
                else hide();
              }
            }
          } catch (reason) {
            failed(reason);
          }
        });
      });
    } catch (reason) {
      helperFailed(reason);
    }
  }
  async function startHistory() {
    try {
      await history.initialize();
    } catch (reason) {
      // Storage owns its persistent diagnostic and original cause.
      if (history.storage.state().status !== 'failed') failed(reason);
    }
    if (disposed) return;
    if (history.preferencesAvailable) shortcut.initialize(history.getPreferences().accelerator);
    if (history.storage.ready) await sync.initialize().catch(failed);
  }
  async function start() {
    hoverTimer = setInterval(tick, 80);
    screen.on('display-removed', displayChanged);
    screen.on('display-metrics-changed', displayMetricsChanged);
    await Promise.all([startProbe(), startHistory()]);
    if (!disposed && history.storage.ready) {
      expiryTimer = setInterval(() => {
        void history.prune().catch(failed);
      }, 60000);
    }
    changed();
  }
  function selectionContext(select: boolean) {
    if (select && (!requested || !window?.isFocused()))
      throw Error('Откройте полку, чтобы вставить выбранное');
    return {
      revision: presentation.revision,
      autoPaste: select && history.getPreferences().pasteOnSelect && paste.ready,
    };
  }
  async function copySelection(
    content: Record<string, string | Blob>,
    { revision, autoPaste }: ReturnType<typeof selectionContext>,
  ) {
    generation++;
    await clipboard.write([
      new ClipboardItem({
        ...content,
        'electron application/osclipboard;format="org.nspasteboard.AutoGeneratedType"': new Blob([
          '',
        ]),
      }),
    ]);
    if (presentation.revision !== revision || disposed || suspensions.size > 0) return true;
    if (autoPaste) {
      // Hide the native window before restoring focus; don't race the exit animation.
      hide(false);
      const sent = await paste.paste();
      if (!sent && !requested && !disposed && Notification.isSupported()) {
        new Notification({
          title: 'Скопировано',
          body: ['focus-not-restored', 'field-changed', 'window-changed'].includes(
            paste.failureReason ?? '',
          )
            ? 'Не удалось вернуть фокус в прежнее поле. Нажмите на него и нажмите ⌘ V.'
            : 'Автоматическая вставка не выполнена. Вернитесь в нужное поле и нажмите ⌘ V.',
        }).show();
      }
    } else hide();
    return true;
  }
  async function handle(method: string, params: Record<string, unknown>) {
    if (method === 'shelf.showEmoji') {
      await show('keyboard', 'emoji');
      return true;
    }
    if (method === 'shelf.copyEmoji' || method === 'shelf.selectEmoji') {
      const context = selectionContext(method === 'shelf.selectEmoji');
      const emoji = emojiById(z.string().max(256).parse(params.id));
      if (!emoji) throw Error('Эмодзи не найден');
      return copySelection({ 'text/plain': emoji.value }, context);
    }
    if (method === 'shelf.copyCalculation') {
      const calculation = calculate(z.string().max(512).parse(params.expression), {
        sourceDate: z
          .string()
          .regex(/^\d{4}-\d{2}-\d{2}$/)
          .optional()
          .parse(params.sourceDate),
      });
      if (calculation?.status !== 'result') throw Error('Нет результата для копирования');
      generation++;
      await clipboard.write([
        new ClipboardItem({
          'text/plain': calculation.value,
          'electron application/osclipboard;format="org.nspasteboard.AutoGeneratedType"': new Blob([
            '',
          ]),
        }),
      ]);
      return true;
    }
    if (method === 'shelf.settings') {
      await show('keyboard', params.section === 'about' ? 'about' : 'settings');
      return true;
    }
    if (method === 'shelf.presentation') return presentation;
    if (method === 'shelf.didShow') {
      const revision = z.number().int().parse(params.revision);
      if (pendingShow?.revision === revision) pendingShow.finish(true);
      return true;
    }
    if (method === 'shelf.didHide') {
      finishHide(z.number().int().parse(params.revision));
      return true;
    }
    if (method === 'clipboardHistory.show') {
      await show('keyboard', 'clipboard', z.string().max(10000).optional().parse(params.query));
      return true;
    }
    if (method === 'clipboardHistory.hide') {
      hide();
      return true;
    }
    if (method === 'clipboardHistory.state' || method === 'clipboardHistory.requestPasteAccess') {
      if (method === 'clipboardHistory.requestPasteAccess') hide(false);
      await paste.status(method === 'clipboardHistory.requestPasteAccess');
      return state();
    }
    if (method === 'clipboardHistory.revealStorage') {
      const store = z.enum(['history', 'sync']).parse(params.store);
      const path = store === 'history' ? history.storage.state().path : sync.storage.state().path;
      try {
        await fs.stat(path);
        shell.showItemInFolder(path);
      } catch {
        const message = await shell.openPath(root);
        if (message) throw Error(message);
      }
      return true;
    }
    if (method === 'clipboardHistory.preview') {
      const id = z.string().parse(params.id);
      await history.prune();
      const clip = history.snapshot().clips.find((item) => item.id === id);
      if (!clip || clip.kind !== 'image') throw Error('Изображение уже удалено');
      const image = nativeImage.createFromBuffer(Buffer.from(clip.content, 'base64'));
      const size = image.getSize();
      if (image.isEmpty()) throw Error('Не удалось открыть изображение');
      const scale = Math.min(1, 1000 / size.width, 700 / size.height);
      return image
        .resize({
          width: Math.max(1, Math.round(size.width * scale)),
          height: Math.max(1, Math.round(size.height * scale)),
        })
        .toDataURL();
    }
    if (method === 'clipboardHistory.openUrl' || method === 'clipboardHistory.saveImage') {
      if (!requested || !window?.isFocused() || savingImage)
        throw Error('Откройте запись на полке, чтобы выполнить действие');
      const owner = window;
      const revision = presentation.revision;
      await history.prune();
      const clip = history.snapshot().clips.find((item) => item.id === z.string().parse(params.id));
      if (!clip) throw Error('Запись уже удалена');
      if (!requested || !owner.isFocused() || savingImage || presentation.revision !== revision)
        throw Error('Откройте запись на полке, чтобы выполнить действие');
      if (method === 'clipboardHistory.openUrl') {
        const url = clip.kind === 'text' ? clipboardWebUrl(clip.content) : undefined;
        if (!url)
          throw Error('Запись должна содержать одну ссылку HTTP или HTTPS без логина и пароля');
        await shell.openExternal(url);
        if (presentation.revision === revision) hide();
        return true;
      }
      if (clip.kind !== 'image') throw Error('Сохранение в файл доступно только для изображений');
      savingImage = true;
      try {
        const result = await dialog.showSaveDialog(owner, {
          title: 'Сохранить изображение',
          defaultPath: `Polka-${new Date(clip.createdAt).toISOString().replace(/[:.]/g, '-')}.png`,
          buttonLabel: 'Сохранить',
          filters: [{ name: 'Изображение PNG', extensions: ['png'] }],
          properties: ['createDirectory'],
        });
        if (result.canceled || !result.filePath) return 'cancelled';
        await fs.writeFile(result.filePath, Buffer.from(clip.content, 'base64'));
        return 'saved';
      } catch (reason) {
        const code = (reason as NodeJS.ErrnoException)?.code;
        const detail =
          code === 'ENOENT'
            ? 'Папка больше не существует. Выберите другую папку.'
            : code === 'EACCES' || code === 'EPERM'
              ? 'Нет доступа к файлу. Выберите другую папку или имя.'
              : code === 'ENOSPC'
                ? 'На диске нет свободного места.'
                : 'Выберите другую папку и попробуйте ещё раз.';
        throw Error(`Не удалось сохранить изображение. ${detail}`);
      } finally {
        savingImage = false;
        if (requested && presentation.revision === revision && !disposed && !owner.isDestroyed())
          owner.focus();
      }
    }
    if (method === 'clipboardHistory.syncEnabled') {
      await sync.setEnabled(z.boolean().parse(params.enabled));
      return state();
    }
    if (method === 'clipboardHistory.copyPairingCode') {
      const code = sync.state().invitation?.code;
      if (!code) throw Error('Получите новый код');
      generation++;
      await clipboard.write([
        new ClipboardItem({
          'text/plain': code,
          'electron application/osclipboard;format="org.nspasteboard.ConcealedType"': new Blob([
            '',
          ]),
        }),
      ]);
      return true;
    }
    if (method === 'clipboardHistory.syncInvite') {
      sync.invite();
      return state();
    }
    if (method === 'clipboardHistory.syncCancelInvite') {
      sync.cancelInvite();
      return state();
    }
    if (method === 'clipboardHistory.syncPair') {
      await sync.pair(z.string().max(2048).parse(params.code));
      return state();
    }
    if (method === 'clipboardHistory.syncForget') {
      await sync.forget(z.string().uuid().parse(params.id));
      return state();
    }
    if (method === 'clipboardHistory.syncNow') {
      history.storage.requireReady();
      sync.storage.requireReady();
      await sync.syncNow();
      return state();
    }
    if (method === 'clipboardHistory.preferences') {
      const patch = z
        .object({
          paused: z.boolean().optional(),
          pasteOnSelect: z.boolean().optional(),
          hoverEnabled: z.boolean().optional(),
          retentionDays: z.union([z.literal(1), z.literal(7), z.literal(30)]).optional(),
        })
        .strict()
        .parse(params);
      generation++;
      await history.preferences(patch);
    } else if (method === 'clipboardHistory.shortcut') {
      history.storage.requireReady();
      const accelerator = z.string().max(80).parse(params.accelerator);
      if (
        accelerator &&
        (!/^(?:(?:CommandOrControl|Control|Alt|Shift)\+)+(?:[A-Z0-9]|Space|F(?:[1-9]|1[0-2]))$/.test(
          accelerator,
        ) ||
          !/(CommandOrControl|Control|Alt)\+/.test(accelerator))
      )
        throw Error('Выберите сочетание с Command, Control или Option');
      await shortcut.set(accelerator);
      changed();
    } else if (method === 'clipboardHistory.clear') {
      generation++;
      await history.clear();
    } else if (method === 'clipboardHistory.remove') {
      generation++;
      await history.remove(z.string().parse(params.id));
    } else if (method === 'clipboardHistory.pin')
      await history.pin(z.string().parse(params.id), z.boolean().parse(params.pinned));
    else if (method === 'clipboardHistory.copy' || method === 'clipboardHistory.select') {
      const context = selectionContext(method === 'clipboardHistory.select');
      if (process.env.EVERYTHING_PASTE_DEBUG === '1')
        console.log('Clipboard paste selection', context);
      await history.prune();
      const clip = history.snapshot().clips.find((item) => item.id === params.id);
      if (!clip) throw Error('Запись уже удалена');
      const transformation = z.enum(TEXT_TRANSFORMATIONS).optional().parse(params.transformation);
      if (transformation && clip.kind !== 'text')
        throw Error('Преобразование доступно только для текста');
      return copySelection(
        clip.kind === 'text'
          ? {
              'text/plain': transformation
                ? transformClipboardText(clip.content, transformation)
                : clip.content,
            }
          : { 'image/png': new Blob([Buffer.from(clip.content, 'base64')], { type: 'image/png' }) },
        context,
      );
    } else throw Error('Неизвестная операция истории буфера');
    return state();
  }
  async function stop() {
    disposed = true;
    pendingShow?.finish(false);
    generation++;
    clearTimeout(hideTimer);
    clearInterval(hoverTimer);
    clearInterval(expiryTimer);
    paste.stop();
    if (helper.status !== 'failed') helper = { status: 'stopped' };
    probe?.kill();
    screen.removeListener('display-removed', displayChanged);
    screen.removeListener('display-metrics-changed', displayMetricsChanged);
    await sync.stop();
    await history.flush();
  }
  return {
    flush: () => history.flush(),
    start,
    stop,
    handle,
    show,
    hide,
    toggle,
    getRevision: () => presentation.revision,
    suspend(reason = 'sleep') {
      suspensions.add(reason);
      paste.cancel();
      generation++;
      hide(false);
    },
    resume(reason = 'sleep') {
      suspensions.delete(reason);
    },
  };
}
