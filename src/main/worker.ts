import { parentPort, workerData } from 'node:worker_threads';
import { SettingsStore } from './settings-store';
const port = parentPort!;
const settings = new SettingsStore(workerData.root);
port.on('message', async (message: any) => {
  if (message.kind === 'shutdown') {
    settings.close();
    process.exit(0);
  }
  if (message.kind !== 'call') return;
  try {
    const result = await settings.handle(message.method, message.params);
    port.postMessage({ kind: 'result', id: message.id, result });
  } catch (error) {
    port.postMessage({
      kind: 'result',
      id: message.id,
      error: error instanceof Error ? error.message : 'Ошибка выполнения',
    });
  }
});
port.postMessage({ kind: 'ready' });
