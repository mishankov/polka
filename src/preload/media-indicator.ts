import { contextBridge, ipcRenderer } from 'electron';
import type { MediaIndicatorPresentation } from '../shared/media-indicator';

// This noninteractive overlay has no access to the shelf's writable RPC surface.
contextBridge.exposeInMainWorld('mediaIndicator', {
  getState: () => ipcRenderer.invoke('mediaIndicator:presentation'),
  onChange: (callback: (state: MediaIndicatorPresentation) => void) => {
    const listener = (_event: unknown, state: MediaIndicatorPresentation) => callback(state);
    ipcRenderer.on('mediaIndicator:changed', listener);
    return () => ipcRenderer.removeListener('mediaIndicator:changed', listener);
  },
});
