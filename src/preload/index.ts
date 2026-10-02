import { contextBridge, ipcRenderer, webUtils } from 'electron';
contextBridge.exposeInMainWorld('platform', {
  openDropped: (appId: string, files: File[]) =>
    ipcRenderer.invoke(
      'docs:drop',
      { appId },
      files.map((file) => webUtils.getPathForFile(file)).filter(Boolean),
    ),
  call: (method: string, params: unknown = {}) =>
    ipcRenderer.invoke('platform:call', method, params),
  onEvent: (callback: (event: unknown) => void) => {
    const handler = (_event: unknown, payload: unknown) => callback(payload);
    ipcRenderer.on('platform:event', handler);
    return () => ipcRenderer.removeListener('platform:event', handler);
  },
});
