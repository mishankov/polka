import { spawn, type ChildProcess } from 'node:child_process';
import { createInterface } from 'node:readline';

type ProbeOptions = {
  path: () => string;
  onLine: (line: string, markReady: () => void) => void;
  onAttemptFailure: () => void;
  onFailure: (reason: unknown) => void;
};

/** Owns process readiness, retries and cancellation; shelf owns protocol effects. */
export class ClipboardProbeSupervisor {
  private child?: ChildProcess;
  private stopAttempt?: () => void;
  private stopped = false;
  constructor(private readonly options: ProbeOptions) {}
  write(message: string) {
    if (!this.child?.stdin?.writable) return false;
    this.child.stdin.write(message);
    return true;
  }
  stop() {
    this.stopped = true;
    this.stopAttempt?.();
  }
  async start() {
    // The first launch after bundle replacement can be slow. Retry just the
    // native helper, keeping history and the rest of the app independent.
    const timeouts = [5000, 15000, 30000];
    for (const [attempt, timeout] of timeouts.entries()) {
      if (this.stopped) return;
      try {
        await this.startAttempt(timeout);
        return;
      } catch (reason) {
        if (this.stopped) return;
        const code = (reason as NodeJS.ErrnoException)?.code;
        if (attempt === timeouts.length - 1 || code === 'ENOENT' || code === 'EACCES') {
          this.options.onFailure(reason);
          return;
        }
        await new Promise<void>((resolve) => {
          const timer = setTimeout(() => {
            this.stopAttempt = undefined;
            resolve();
          }, 1000);
          this.stopAttempt = () => {
            clearTimeout(timer);
            this.stopAttempt = undefined;
            resolve();
          };
        });
      }
    }
  }
  private async startAttempt(timeoutMs: number) {
    const probePath = this.options.path();
    await new Promise<void>((resolve, reject) => {
      const child = spawn(probePath, [String(process.pid)], {
        stdio: ['pipe', 'pipe', 'ignore'],
      });
      this.child = child;
      let active = true;
      let ready = false;
      let exited = false;
      let didExit: () => void;
      const exit = new Promise<void>((resolve) => {
        didExit = resolve;
      });
      const lines = createInterface({ input: child.stdout! });
      const cleanup = () => {
        active = false;
        clearTimeout(timeout);
        lines.close();
        if (this.child === child) this.child = undefined;
      };
      const release = () => {
        if (this.stopAttempt === cancel) this.stopAttempt = undefined;
      };
      const attemptFailed = (reason: unknown) => {
        if (!active || this.stopped) return;
        cleanup();
        this.options.onAttemptFailure();
        // Wait for the old process to exit before starting its replacement.
        // Its late stdout, stdin errors and exit can no longer change state.
        if (!exited) child.kill('SIGKILL');
        if (ready) {
          release();
          this.options.onFailure(reason);
        } else
          void exit.then(() => {
            release();
            reject(reason);
          });
      };
      const timeout = setTimeout(() => {
        const reason = Error(
          `Не удалось запустить наблюдение за буфером обмена: помощник не ответил за ${timeoutMs / 1000} секунд`,
        );
        attemptFailed(reason);
      }, timeoutMs);
      const cancel = () => {
        const wasActive = active;
        cleanup();
        release();
        if (wasActive && !exited) child.kill();
        resolve();
      };
      this.stopAttempt = cancel;
      child.stdin?.on('error', attemptFailed);
      child.on('error', (reason) => {
        if (!child.pid) {
          exited = true;
          didExit();
        }
        attemptFailed(reason);
      });
      child.on('exit', (code, signal) => {
        exited = true;
        didExit();
        const reason = Error(
          `Наблюдение за буфером остановлено (${signal ?? code ?? 'неизвестная причина'}). Перезапустите приложение.`,
        );
        attemptFailed(reason);
      });
      lines.on('line', (line) => {
        if (!active || this.stopped) return;
        this.options.onLine(line, () => {
          clearTimeout(timeout);
          ready = true;
          resolve();
        });
      });
    });
  }
}
