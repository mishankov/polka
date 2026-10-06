// Test-only Electron entry point. Production has no synthetic activity RPC or env override.
import { app, BrowserWindow, screen } from 'electron';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createMediaIndicator } from '../src/main/media-indicator';
import { mediaTrackingFromSettings } from '../src/shared/media-indicator';

app.setPath('userData', process.env.EVERYTHING_PROFILE!);
void app.whenReady().then(async () => {
  app.dock?.hide();
  const root = process.env.EVERYTHING_TEST_ROOT!;
  let camera = 'inactive',
    microphone = 'inactive',
    fail = false;
  const preference = join(app.getPath('userData'), 'media-enabled.json');
  const tracking = await readFile(preference, 'utf8')
    .then(JSON.parse)
    .catch(() => mediaTrackingFromSettings());
  const target = new BrowserWindow({ width: 600, height: 360, title: 'Media test typing target' });
  await target.loadURL(
    'data:text/html,<input autofocus aria-label="Typing target" style="margin:80px;font-size:20px">',
  );
  target.show();
  target.focus();
  const indicator = createMediaIndicator({
    preload: join(root, 'out/preload/media-indicator.js'),
    page: join(root, 'out/renderer/media-indicator.html'),
    read: async () => {
      if (fail) throw Error('Fixture failure');
      return { camera: { state: camera }, microphone: { state: microphone } };
    },
    saveTracking: (value) => writeFile(preference, JSON.stringify(value)),
    changed: () => {},
  });
  const setNotched = (notched: boolean) => {
    const display = screen.getPrimaryDisplay();
    indicator.setNotches(
      notched
        ? [{ id: display.id, x: (display.bounds.width - 200) / 2, width: 200, height: 32 }]
        : [],
    );
  };
  setNotched(true);
  (globalThis as any).mediaTest = {
    indicator,
    target,
    setNotched,
    async setFullScreen(value: boolean) {
      // Only wait for a native event when requesting a state change.
      // A no-op fullscreen request emits no completion event.
      if (target.isFullScreen() === value) return;
      await new Promise<void>((resolve, reject) => {
        const done = () => {
          clearTimeout(timer);
          resolve();
        };
        const timer = setTimeout(() => {
          target.removeListener('enter-full-screen', done);
          target.removeListener('leave-full-screen', done);
          reject(Error(`Media fixture did not ${value ? 'enter' : 'leave'} fullscreen`));
        }, 15000);
        if (value) target.once('enter-full-screen', done);
        else target.once('leave-full-screen', done);
        target.setFullScreen(value);
      });
    },
    setActivity(c: string, m: string, error = false) {
      camera = c;
      microphone = m;
      fail = error;
    },
  };
  indicator.start(tracking);
  app.on('before-quit', () => {
    target.setFullScreen(false);
    indicator.stop();
  });
});
