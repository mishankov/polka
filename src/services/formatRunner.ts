import { Worker } from 'node:worker_threads';
import { MAX_TRANSFORM_INPUT } from './transforms';
/** Bounded parsing outside the core worker so a large input cannot block app data or shutdown. */
export class FormatRunner {
  private active = new Map<Worker, () => void>();
  constructor(private workerPath: string) {}
  run(operation: string, input: unknown, signal?: AbortSignal): Promise<any> {
    signal?.throwIfAborted();
    if (this.active.size >= 2)
      return Promise.reject(Error('Уже выполняются две операции форматов'));
    const serialized = JSON.stringify(input);
    if (serialized === undefined || Buffer.byteLength(serialized) > MAX_TRANSFORM_INPUT)
      return Promise.reject(Error('Ввод должен быть JSON и не превышать 1 МиБ'));
    return new Promise((resolve, reject) => {
      const worker = new Worker(this.workerPath, {
        workerData: { operation, input },
        resourceLimits: { maxOldGenerationSizeMb: 64 },
      });
      const finish = (error?: Error, result?: unknown) => {
        if (!this.active.delete(worker)) return;
        clearTimeout(timer);
        signal?.removeEventListener('abort', abort);
        void worker.terminate();
        error ? reject(error) : resolve(result);
      };
      const abort = () => finish(Error('Операция отменена'));
      const timer = setTimeout(() => finish(Error('Обработка превысила 5 секунд')), 5000);
      this.active.set(worker, abort);
      signal?.addEventListener('abort', abort, { once: true });
      worker.once('message', (message) =>
        finish(message.error ? Error(message.error) : undefined, message.result),
      );
      worker.once('error', (error) =>
        finish(error instanceof Error ? error : Error(String(error))),
      );
      worker.once('exit', () => finish(Error('Процесс обработки завершился без результата')));
      if (signal?.aborted) abort();
    });
  }
  close() {
    for (const cancel of this.active.values()) cancel();
  }
}
