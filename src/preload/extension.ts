import { contextBridge, ipcRenderer } from 'electron';
// The host binds this sender to its instance. No IDs or privileged shell IPC are exposed.
contextBridge.exposeInMainWorld('extensionHost', {
  call: (method: string, params: unknown = {}) =>
    ipcRenderer.invoke('extension:call', method, params),
  theme: () => ipcRenderer.invoke('extension:theme'),
  onTheme: (callback: (theme: unknown) => void) => {
    const handler = (_event: unknown, theme: unknown) => callback(theme);
    ipcRenderer.on('extension:theme', handler);
    return () => ipcRenderer.removeListener('extension:theme', handler);
  },
  ready: () => ipcRenderer.send('extension:ready'),
  failure: (message: string) =>
    ipcRenderer.send('extension:failure', String(message).slice(0, 2000)),
});
setInterval(() => ipcRenderer.send('extension:heartbeat'), 750);
