import { defineConfig, externalizeDepsPlugin } from 'electron-vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'node:path';
export default defineConfig({
  main: {
    plugins: [externalizeDepsPlugin()],
    build: {
      rollupOptions: {
        input: {
          index: resolve('src/main/index.ts'),
          worker: resolve('src/main/worker.ts'),
          transformWorker: resolve('src/main/transformWorker.ts'),
          'package-worker': resolve('src/core/package-worker.ts'),
        },
      },
    },
  },
  preload: {
    plugins: [externalizeDepsPlugin()],
    build: {
      rollupOptions: {
        input: {
          index: resolve('src/preload/index.ts'),
          extension: resolve('src/preload/extension.ts'),
          'media-indicator': resolve('src/preload/media-indicator.ts'),
        },
      },
    },
  },
  renderer: {
    plugins: [react()],
    build: {
      rollupOptions: {
        input: {
          index: resolve('src/renderer/index.html'),
          'media-indicator': resolve('src/renderer/media-indicator.html'),
        },
      },
    },
  },
});
