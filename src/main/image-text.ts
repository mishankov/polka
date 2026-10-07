import { spawn } from 'node:child_process';
import { release } from 'node:os';
import { z } from 'zod';
import type { ClipboardHistory } from './clipboard-history';
import type { ImageText } from '../shared/clipboard';

// Bump on any recognition/normalization change. OS upgrades may change models.
export const IMAGE_TEXT_VERSION = `vision-r3-accurate-ru-en-correction-cpu-v3-${release()}`;
const outputSchema = z.object({
  text: z.string().max(1024 * 1024),
  languages: z.array(z.string().max(40)).max(20),
});
export function recognizeImageText(path: string, content: string, signal: AbortSignal) {
  return new Promise<{ text: string; languages: string[] }>((resolve, reject) => {
    const child = spawn(path, [], { stdio: ['pipe', 'pipe', 'ignore'], signal });
    let bytes = 0;
    const output: Buffer[] = [];
    let failed = false;
    const timer = setTimeout(() => child.kill('SIGKILL'), 60000);
    child.stdin.on('error', () => {}); // A failed helper can close before receiving its PNG.
    child.stdout.on('data', (data: Buffer) => {
      bytes += data.length;
      if (bytes > 8 * 1024 * 1024) child.kill('SIGKILL');
      else output.push(data);
    });
    // Abort emits error before exit. Wait for close before allowing another
    // worker, including after cancellation, so native concurrency stays bounded.
    child.on('error', () => {
      failed = true;
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (failed || code !== 0 || signal.aborted) {
        let diagnostic = '';
        try {
          const result = z
            .object({
              error: z.object({
                domain: z.string().regex(/^[A-Za-z0-9_.-]{1,120}$/),
                code: z.number().int(),
              }),
            })
            .parse(JSON.parse(Buffer.concat(output).toString('utf8')));
          diagnostic = ` (${result.error.domain}:${result.error.code})`;
        } catch {
          /* Missing helper, cancellation or invalid diagnostics. */
        }
        return reject(Error(`Image text recognition failed${diagnostic}`));
      }
      try {
        resolve(outputSchema.parse(JSON.parse(Buffer.concat(output).toString('utf8'))));
      } catch {
        reject(Error('Invalid image text result'));
      }
    });
    child.stdin.end(Buffer.from(content, 'base64'));
  });
}

/** One bounded native worker; choose the next live image lazily, without copying
 * the whole history or holding recognition inside the persistence queue. */
export class ImageTextIndexer {
  private timer?: ReturnType<typeof setTimeout>;
  private active?: { id: string; incarnation: number; controller: AbortController };
  private stopped = false;
  private running?: Promise<void>;
  constructor(
    private history: ClipboardHistory,
    private recognize: (
      content: string,
      signal: AbortSignal,
    ) => Promise<{ text: string; languages: string[] }>,
    readonly version = IMAGE_TEXT_VERSION,
  ) {}
  changed() {
    if (this.stopped) return;
    if (
      this.active &&
      (!this.history.storage.ready ||
        !this.history
          .imageTextImages()
          .some(
            (clip) => clip.id === this.active!.id && clip.incarnation === this.active!.incarnation,
          ))
    )
      this.active.controller.abort();
    if (!this.timer && !this.active && this.history.storage.ready)
      this.timer = setTimeout(() => {
        this.timer = undefined;
        this.running = this.next();
      }, 100);
  }
  private async next() {
    if (this.stopped || !this.history.storage.ready) return;
    const clip = this.history.imageTextImages().find((clip) => clip.ocr?.version !== this.version);
    if (!clip) return;
    const task = { id: clip.id, incarnation: clip.incarnation, controller: new AbortController() };
    this.active = task;
    let result: ImageText;
    try {
      const recognized = outputSchema.parse(
        await this.recognize(clip.content, task.controller.signal),
      );
      const text = recognized.text.trim();
      result = {
        version: this.version,
        status: text ? 'ready' : 'empty',
        text,
        languages: recognized.languages,
      };
    } catch {
      result = { version: this.version, status: 'failed', text: '', languages: [] };
    }
    try {
      if (!this.stopped && !task.controller.signal.aborted)
        await this.history.saveImageText(clip.id, clip.incarnation, result);
    } catch {
      // History reports persistence failures through its existing storage state.
    } finally {
      this.active = undefined;
      this.changed();
    }
  }
  stop() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.active?.controller.abort();
    return this.running ?? Promise.resolve();
  }
}
