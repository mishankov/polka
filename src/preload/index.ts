import { contextBridge, ipcRenderer, webUtils } from 'electron';
contextBridge.exposeInMainWorld('platform', {
  filePaths: (files: File[]) => files.map((file) => webUtils.getPathForFile(file)).filter(Boolean),
  startFileDrag: (ids: string[]) => ipcRenderer.send('shelf:fileDrag', ids),
  call: (method: string, params: unknown = {}) =>
    ipcRenderer.invoke('platform:call', method, params),
  onEvent: (callback: (event: unknown) => void) => {
    const handler = (_event: unknown, payload: unknown) => callback(payload);
    ipcRenderer.on('platform:event', handler);
    return () => ipcRenderer.removeListener('platform:event', handler);
  },
});
