import { parentPort, workerData } from 'node:worker_threads';
import { openSync, writeSync, closeSync } from 'node:fs';
import { Zip, ZipDeflate } from 'fflate';
import { CoreService } from './service';

const port = parentPort!;
const root = workerData.scratchRoot;
const core = new CoreService(root);
try {
  if (workerData.kind === 'import') {
    const bundle = core.readPackage(workerData.path, (completed, total) =>
      port.postMessage({
        type: 'progress',
        phase: completed === total ? 'Проверка содержимого' : 'Распаковка архива',
        completed: completed === total ? 0 : completed,
        total: completed === total ? 0 : total,
      }),
    );
    port.postMessage({ type: 'result', result: bundle });
  } else if (workerData.kind === 'export') {
    const files = core.packageFiles(workerData.bundle);
    const entries = Object.entries(files);
    const total = entries.reduce((sum, [, data]) => sum + data.length, 0);
    let completed = 0,
      size = 0;
    const fd = openSync(workerData.tempPath, 'wx');
    try {
      const zip = new Zip((error, chunk) => {
        if (error) throw error;
        size += chunk.length;
        if (size > 64 * 1024 * 1024) throw new Error('Пакет превышает 64 МБ');
        let offset = 0;
        while (offset < chunk.length) offset += writeSync(fd, chunk, offset, chunk.length - offset);
      });
      for (const [name, bytes] of entries) {
        const file = new ZipDeflate(name, { level: 6 });
        zip.add(file);
        if (!bytes.length) file.push(bytes, true);
        for (let offset = 0; offset < bytes.length; offset += 64 * 1024) {
          const chunk = bytes.subarray(offset, offset + 64 * 1024);
          file.push(chunk, offset + chunk.length === bytes.length);
          completed += chunk.length;
          port.postMessage({ type: 'progress', phase: 'Запись архива', completed, total });
        }
      }
      zip.end();
      port.postMessage({
        type: 'result',
        result: { bytes: size, manifest: workerData.bundle.manifest },
      });
    } finally {
      closeSync(fd);
    }
  } else throw new Error('Неизвестная операция архива');
} catch (error) {
  port.postMessage({ type: 'error', error: (error as Error).message });
} finally {
  core.close();
}
