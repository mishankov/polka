import { BrowserWindow, ipcMain, screen } from 'electron';
import type { Notch } from './clipboard-hover';
import { mediaIndicatorGeometry } from './media-indicator-geometry';
import { MediaMonitor } from './media-monitor';
import {
  mediaIndicatorVisible,
  type MediaIndicatorPresentation,
  type MediaIndicatorState,
} from '../shared/media-indicator';

export function createMediaIndicator(options: {
  preload: string;
  page: string;
  devURL?: string;
  read: () => Promise<unknown>;
  saveEnabled: (enabled: boolean) => Promise<unknown>;
  changed: (state: MediaIndicatorState) => void;
}) {
  const overlays = new Map<number, { window: BrowserWindow; ready: boolean }>();
  const suspensions = new Set<string>();
  let notches: Notch[] = [];
  let enabled = false;
  let sampled = false;
  let stopped = false;
  let listening = false;
  let saving = Promise.resolve();
  const monitor = new MediaMonitor(options.read, () => {
    sampled = true;
    render();
    options.changed(state());
  });
  const state = (): MediaIndicatorState => ({ enabled, ...monitor.activity });
  function presentation(displayId: number): MediaIndicatorPresentation {
    const display = screen.getAllDisplays().find((item) => item.id === displayId)!;
    return {
      ...monitor.activity,
      ...mediaIndicatorGeometry(
        display.bounds,
        notches.find((item) => item.id === displayId),
      ),
    };
  }
  function render() {
    const displays = screen.getAllDisplays();
    for (const [id, overlay] of overlays) {
      if (!displays.some((display) => display.id === id)) {
        overlay.window.destroy();
        overlays.delete(id);
      }
    }
    const visible =
      !stopped &&
      enabled &&
      sampled &&
      !suspensions.size &&
      mediaIndicatorVisible(monitor.activity);
    if (!visible) {
      for (const { window } of overlays.values()) window.hide();
      return;
    }
    for (const display of displays) {
      const geometry = mediaIndicatorGeometry(
        display.bounds,
        notches.find((item) => item.id === display.id),
      );
      let overlay = overlays.get(display.id);
      if (!overlay) {
        const win = new BrowserWindow({
          ...geometry.bounds,
          title: 'Индикатор камеры и микрофона',
          show: false,
          frame: false,
          transparent: true,
          backgroundColor: '#00000000',
          roundedCorners: false,
          enableLargerThanScreen: true,
          hasShadow: false,
          focusable: false,
          skipTaskbar: true,
          resizable: false,
          minimizable: false,
          maximizable: false,
          fullscreenable: false,
          ...(process.platform === 'darwin' ? { type: 'panel' as const } : {}),
          webPreferences: {
            preload: options.preload,
            sandbox: true,
            contextIsolation: true,
            nodeIntegration: false,
          },
        });
        overlay = { window: win, ready: false };
        overlays.set(display.id, overlay);
        win.setIgnoreMouseEvents(true);
        // Best effort: ScreenCaptureKit can ignore this macOS sharing flag.
        win.setContentProtection(true);
        win.setVisibleOnAllWorkspaces(true, {
          visibleOnFullScreen: true,
          skipTransformProcessType: true,
        });
        win.setAlwaysOnTop(true, 'screen-saver');
        win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
        win.webContents.on('will-navigate', (event) => event.preventDefault());
        win.webContents.on('will-attach-webview', (event) => event.preventDefault());
        win.on('closed', () => overlays.delete(display.id));
        const entry = overlay;
        const loading = options.devURL ? win.loadURL(options.devURL) : win.loadFile(options.page);
        void loading
          .then(() => {
            if (win.isDestroyed()) return;
            entry.ready = true;
            render();
          })
          .catch((error) => {
            console.error('Could not load media indicator', error);
            if (!win.isDestroyed()) win.destroy();
          });
      }
      overlay.window.setBounds(geometry.bounds);
      if (overlay.ready) {
        overlay.window.webContents.send('mediaIndicator:changed', presentation(display.id));
        if (!overlay.window.isVisible()) overlay.window.showInactive();
      }
    }
  }
  const getPresentation = (event: Electron.IpcMainInvokeEvent) => {
    const entry = [...overlays].find(([, item]) => item.window.webContents === event.sender);
    if (!entry || event.senderFrame !== event.sender.mainFrame)
      throw Error('Недоверенный отправитель');
    return presentation(entry[0]);
  };
  ipcMain.handle('mediaIndicator:presentation', getPresentation);
  function displayChanged() {
    render();
  }

  function applyEnabled(value: boolean) {
    enabled = value;
    sampled = false;
    monitor.stop();
    if (!enabled) {
      for (const { window } of overlays.values()) window.destroy();
      overlays.clear();
    }
    if (enabled && !suspensions.size && !stopped) monitor.start();
    render();
    options.changed(state());
  }
  return {
    state,
    start(value: boolean) {
      if (!listening) {
        screen.on('display-added', displayChanged);
        screen.on('display-removed', displayChanged);
        screen.on('display-metrics-changed', displayChanged);
        listening = true;
      }
      applyEnabled(value);
    },
    setEnabled(value: boolean) {
      const operation = saving.then(async () => {
        await options.saveEnabled(value);
        if (!stopped) applyEnabled(value);
        return state();
      });
      saving = operation.then(
        () => {},
        () => {},
      );
      return operation;
    },
    setNotches(value: Notch[]) {
      notches = value;
      render();
    },
    suspend(reason = 'sleep') {
      suspensions.add(reason);
      monitor.stop();
      sampled = false;
      render();
    },
    resume(reason = 'sleep') {
      suspensions.delete(reason);
      if (enabled && !suspensions.size && !stopped) monitor.start();
    },
    stop() {
      stopped = true;
      monitor.stop();
      for (const { window } of overlays.values()) window.destroy();
      overlays.clear();
      ipcMain.removeHandler('mediaIndicator:presentation');
      screen.removeListener('display-added', displayChanged);
      screen.removeListener('display-removed', displayChanged);
      screen.removeListener('display-metrics-changed', displayChanged);
    },
  };
}
