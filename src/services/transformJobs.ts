import { randomUUID } from 'node:crypto';
import { Worker } from 'node:worker_threads';
import { validatePipeline } from './transforms';
interface Job {
  id: string;
  appId: string;
  status: 'running' | 'done' | 'cancelled' | 'error';
  completed: number;
  total: number;
  current?: string;
  error?: string;
  results?: any[];
  worker?: Worker;
  timer?: ReturnType<typeof setTimeout>;
}
export class TransformJobService {
  private jobs = new Map<string, Job>();
  constructor(
    private workerPath: string,
    private call: (method: string, p: any) => Promise<any>,
  ) {}
  private view(job: Job, results = false) {
    const { worker, timer, results: output, ...safe } = job;
    return { ...safe, ...(results ? { results: output || [] } : {}) };
  }
  async handle(method: string, p: any): Promise<any> {
    await this.call('apps.get', { appId: p.appId });
    if (method === 'transforms.jobs.start') {
      validatePipeline(p.steps);
      if ([...this.jobs.values()].filter((j) => j.status === 'running').length >= 2)
        throw Error('Уже выполняются два преобразования');
      let items: any[];
      if (p.documentIds) {
        if (!Array.isArray(p.documentIds) || p.documentIds.length > 256)
          throw Error('Выберите не более 256 документов');
        items = [];
        let inputBytes = 2;
        for (const id of [...new Set(p.documentIds)]) {
          const d = await this.call('docs.get', { appId: p.appId, id });
          // Bound the batch before expanding base64 into JS numbers or retaining another document.
          const limit = 32 * 1024 * 1024;
          const contentBytes =
            d.kind === 'binary'
              ? Buffer.byteLength(d.content, 'base64') * 4 + 2
              : Buffer.byteLength(d.content, 'utf8');
          if (inputBytes + contentBytes > limit)
            throw Error('Суммарный размер входа превышает 32 МБ');
          inputBytes +=
            (d.kind === 'binary' ? contentBytes : Buffer.byteLength(JSON.stringify(d.content))) +
            Buffer.byteLength(JSON.stringify({ id: d.id, name: d.name, revision: d.revision })) +
            16;
          if (inputBytes > limit) throw Error('Суммарный размер входа превышает 32 МБ');
          items.push({
            id: d.id,
            name: d.name,
            revision: d.revision,
            input:
              d.kind === 'binary'
                ? [...Buffer.from(d.content, 'base64')]
                : d.kind === 'image'
                  ? { type: 'image', dataUrl: d.content }
                  : d.content,
          });
        }
      } else items = [{ id: 'input', name: 'Исходный текст', input: p.input }];
      if (!items.length) throw Error('Выберите документы');
      if (Buffer.byteLength(JSON.stringify(items)) > 32 * 1024 * 1024)
        throw Error('Суммарный размер входа превышает 32 МБ');
      // Keep completed previews bounded; callers release their result when closing the panel.
      for (const [id, old] of this.jobs)
        if (this.jobs.size >= 8 && old.status !== 'running') this.jobs.delete(id);
      if ([...this.jobs.values()].filter((j) => j.status === 'running').length >= 2)
        throw Error('Уже выполняются два преобразования');
      const job: Job = {
        id: randomUUID(),
        appId: p.appId,
        status: 'running',
        completed: 0,
        total: items.length * p.steps.length,
      };
      this.jobs.set(job.id, job);
      try {
        const worker = new Worker(this.workerPath, {
          workerData: { items, steps: p.steps },
          resourceLimits: { maxOldGenerationSizeMb: 256 },
        });
        job.worker = worker;
        const finish = (status: Job['status'], error?: string) => {
          if (job.status !== 'running') return;
          job.status = status;
          job.error = error;
          clearTimeout(job.timer);
          void worker.terminate();
          job.worker = undefined;
        };
        job.timer = setTimeout(
          () => finish('error', 'Преобразование превысило лимит 2 минуты'),
          120000,
        );
        worker.on('message', (m) => {
          if (job.status !== 'running') return;
          if (m.type === 'progress') {
            job.completed = m.completed;
            job.current = m.current;
          }
          if (m.type === 'done') {
            job.results = m.results;
            finish('done');
          }
          if (m.type === 'error') finish('error', m.error);
        });
        worker.on('error', (error) =>
          finish('error', error instanceof Error ? error.message : String(error)),
        );
        worker.on('exit', (code) => {
          if (job.status === 'running')
            finish('error', `Процесс преобразования завершился (${code})`);
        });
      } catch (error) {
        job.status = 'error';
        job.error = String(error);
      }
      return this.view(job);
    }
    const job = this.jobs.get(p.id);
    if (!job || job.appId !== p.appId)
      throw Error('Предпросмотр не найден; запустите преобразование снова');
    if (method === 'transforms.jobs.status') return this.view(job, p.results === true);
    if (method === 'transforms.jobs.cancel' || method === 'transforms.jobs.release') {
      clearTimeout(job.timer);
      if (job.status === 'running') job.status = 'cancelled';
      await job.worker?.terminate();
      job.worker = undefined;
      if (method.endsWith('release')) this.jobs.delete(job.id);
      return this.view(job);
    }
    throw Error('Неизвестная операция преобразования');
  }
  async close() {
    await Promise.all(
      [...this.jobs.values()].map(async (job) => {
        clearTimeout(job.timer);
        await job.worker?.terminate();
      }),
    );
    this.jobs.clear();
  }
}
