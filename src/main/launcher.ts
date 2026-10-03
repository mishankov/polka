import { BrowserWindow, screen } from 'electron';
import { join } from 'node:path';

export function createLauncher(register: (win: BrowserWindow) => void, isQuitting: () => boolean) {
  let window: BrowserWindow | undefined;
  let loading: Promise<void> | undefined;
  let requested = false;
  let expanded = false;
  const hide = () => {
    requested = false;
    if (window && !window.isDestroyed()) window.hide();
  };
  async function show() {
    requested = true;
    if (!window || window.isDestroyed()) {
      const win = new BrowserWindow({
        width: 640,
        height: 460,
        show: false,
        frame: false,
        resizable: false,
        minimizable: false,
        maximizable: false,
        fullscreenable: false,
        alwaysOnTop: true,
        skipTaskbar: true,
        title: 'Запуск приложений',
        transparent: true,
        ...(process.platform === 'darwin'
          ? {
              type: 'panel' as const,
              vibrancy: 'popover' as const,
              visualEffectState: 'active' as const,
            }
          : {}),
        backgroundColor: '#00000000',
        webPreferences: {
          preload: join(__dirname, '../preload/index.js'),
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true,
        },
      });
      window = win;
      register(win);
      win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
      win.on('blur', hide);
      win.on('close', (event) => {
        if (isQuitting()) return;
        event.preventDefault();
        hide();
      });
      win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
      win.webContents.on('will-navigate', (event) => event.preventDefault());
      win.webContents.on('will-attach-webview', (event) => event.preventDefault());
      loading = process.env.ELECTRON_RENDERER_URL
        ? win.loadURL(`${process.env.ELECTRON_RENDERER_URL}?mode=launcher`)
        : win.loadFile(join(__dirname, '../renderer/index.html'), { query: { mode: 'launcher' } });
      loading.catch(() => {
        requested = false;
        win.destroy();
      });
    }
    await loading;
    if (!requested || !window || window.isDestroyed()) return;
    const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
    const width = Math.min(expanded ? 960 : 640, area.width),
      height = Math.min(expanded ? 680 : 460, area.height);
    window.setBounds({
      x: Math.round(area.x + (area.width - width) / 2),
      y: Math.round(area.y + (area.height - height) / 3),
      width,
      height,
    });
    window.show();
    window.focus();
    window.webContents.send('platform:event', { type: 'launcher.shown' });
  }
  function setExpanded(value: boolean) {
    expanded = value;
    if (!window || window.isDestroyed()) return;
    const area = screen.getDisplayMatching(window.getBounds()).workArea;
    const width = Math.min(expanded ? 960 : 640, area.width),
      height = Math.min(expanded ? 680 : 460, area.height);
    window.setBounds({
      x: Math.round(area.x + (area.width - width) / 2),
      y: Math.round(area.y + (area.height - height) / 3),
      width,
      height,
    });
  }
  return { show, hide, setExpanded, toggle: () => (requested ? hide() : show()) };
}
