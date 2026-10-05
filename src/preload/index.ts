import { contextBridge, ipcRenderer } from 'electron';
contextBridge.exposeInMainWorld('platform', {
  call: (method: string, params: unknown = {}) =>
    ipcRenderer.invoke('platform:call', method, params),
  onEvent: (callback: (event: unknown) => void) => {
    const handler = (_event: unknown, payload: unknown) => callback(payload);
    ipcRenderer.on('platform:event', handler);
    return () => ipcRenderer.removeListener('platform:event', handler);
  },
});
