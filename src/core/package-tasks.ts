import { Worker } from 'node:worker_threads';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rename, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { CoreService } from './service';

export interface PackageTask {
  id: string;
  kind: 'import' | 'export';
  status: 'running' | 'committing' | 'completed' | 'cancelled' | 'failed';
  phase: string;
  completed: number;
  total: number;
  error?: string;
}
/** Trusted utility-worker coordinator. Archive work never executes imported code. */
export class PackageTasks {
  private active = new Set<Promise<void>>();
  private tasks = new Map<string, PackageTask & { worker?: Worker; tempPath?: string }>();
  constructor(
    private readonly core: CoreService,
    private readonly workerPath: string,
    private readonly emit: (event: string, data: PackageTask) => void = () => {},
  ) {}
  status(id: string): PackageTask | undefined {
    const task = this.tasks.get(id);
    if (!task) return undefined;
    const { worker, tempPath, ...result } = task;
    return result;
  }
  private publish(id: string) {
    this.emit('package.task', this.status(id)!);
  }
  async cancel(id: string) {
    const task = this.tasks.get(id);
    if (!task || task.status !== 'running') return { cancelled: false };
    task.status = 'cancelled';
    task.phase = 'Отменено';
    this.publish(id);
    await task.worker?.terminate();
    if (task.tempPath) await rm(task.tempPath, { force: true });
    return { cancelled: true };
  }
  async shutdown() {
    await Promise.all([...this.tasks.keys()].map((id) => this.cancel(id)));
    await Promise.all([...this.active]);
  }
  async importPreview(path: string, taskId: string = randomUUID()) {
    return this.run(taskId, { kind: 'import', path }, (result) =>
      this.core.stageValidatedImport(result),
    );
  }
  async updatePreview(appId: string, path: string, taskId: string = randomUUID()) {
    return this.run(taskId, { kind: 'import', path }, (result) =>
      this.core.stageValidatedUpdate(appId, result),
    );
  }
  async export(params: any, taskId: string = randomUUID()) {
    if (typeof params.path !== 'string' || !params.path.endsWith('.everyapp'))
      throw new Error('Выберите файл .everyapp');
    const bundle = this.core.prepareExport(params);
    const tempPath = params.path + '.' + randomUUID() + '.tmp';
    return this.run(taskId, { kind: 'export', bundle, tempPath }, async (result) => {
      await rename(tempPath, params.path);
      return { ...result, path: params.path };
    });
  }
  private async run(id: string, data: any, finish: (result: any) => any): Promise<any> {
    if (typeof id !== 'string' || !id || id.length > 100 || this.tasks.has(id))
      throw new Error('Некорректный или повторный ID операции');
    if (
      [...this.tasks.values()].filter(
        (task) => task.status === 'running' || task.status === 'committing',
      ).length >= 2
    )
      throw new Error('Дождитесь или отмените одну из двух операций с архивами');
    const task: PackageTask & { worker?: Worker; tempPath?: string } = {
      id,
      kind: data.kind,
      status: 'running',
      phase: 'Подготовка архива',
      completed: 0,
      total: 0,
      tempPath: data.tempPath,
    };
    this.tasks.set(id, task);
    // Keep a bounded history without dropping active cancellation handles.
    for (const [oldId, old] of this.tasks) {
      if (this.tasks.size <= 40) break;
      if (!['running', 'committing'].includes(old.status)) this.tasks.delete(oldId);
    }
    let done!: () => void;
    const settled = new Promise<void>((resolve) => {
      done = resolve;
    });
    this.active.add(settled);
    this.publish(id);
    let scratchRoot: string | undefined;
    try {
      scratchRoot = await mkdtemp(join(tmpdir(), 'everything-archive-'));
      if (task.status === 'cancelled') throw new Error('Операция отменена');
      const result = await new Promise<any>((resolve, reject) => {
        const worker = new Worker(this.workerPath, { workerData: { ...data, scratchRoot } });
        task.worker = worker;
        worker.on('message', (message) => {
          if (task.status === 'cancelled') return;
          if (message.type === 'progress') {
            Object.assign(task, {
              phase: message.phase,
              completed: message.completed,
              total: message.total,
            });
            this.publish(id);
          } else if (message.type === 'result') resolve(message.result);
          else if (message.type === 'error') reject(new Error(message.error));
        });
        worker.on('error', reject);
        worker.on('exit', (code) => {
          if (task.status === 'cancelled') reject(new Error('Операция отменена'));
          else reject(new Error('Обработка архива прервана (код ' + code + ')'));
        });
      });
      if (this.tasks.get(id)?.status === 'cancelled') throw new Error('Операция отменена');
      task.status = 'committing';
      task.phase = data.kind === 'export' ? 'Сохранение файла' : 'Подготовка предпросмотра';
      this.publish(id);
      const output = await finish(result);
      task.status = 'completed';
      task.phase = 'Готово';
      this.publish(id);
      return output;
    } catch (error) {
      if (task.status !== 'cancelled') {
        task.status = 'failed';
        task.error = (error as Error).message;
      }
      this.publish(id);
      throw error;
    } finally {
      try {
        await task.worker?.terminate();
        task.worker = undefined;
        if (scratchRoot) await rm(scratchRoot, { recursive: true, force: true });
        if (task.tempPath) await rm(task.tempPath, { force: true });
      } finally {
        this.active.delete(settled);
        done();
      }
    }
  }
}
