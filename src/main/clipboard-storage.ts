import type { ClipboardStorageState } from '../shared/clipboard';

type Stage = NonNullable<ClipboardStorageState['diagnostic']>['stage'];
const messages: Record<Stage, string> = {
  read: 'Не удалось прочитать файл',
  decrypt: 'Не удалось расшифровать файл',
  parse: 'Не удалось прочитать формат сохранённых данных',
  encrypt: 'Не удалось зашифровать данные',
  write: 'Не удалось сохранить файл',
};

// A failed store remains closed until restart. Never expose decrypted JSON or
// schema error input through IPC; keep the original reason here for diagnostics.
export class ClipboardStorage {
  private value: ClipboardStorageState;
  private reason: unknown;
  constructor(
    path: string,
    private changed: () => void,
  ) {
    this.value = { status: 'starting', path };
  }
  state(): ClipboardStorageState {
    return structuredClone(this.value);
  }
  get ready() {
    return this.value.status === 'ready';
  }
  get failureReason() {
    return this.reason;
  }
  loaded() {
    this.assertNotFailed();
    this.value.status = 'ready';
    this.changed();
  }
  assertNotFailed() {
    if (this.value.status === 'failed') throw this.unavailable();
  }
  requireReady() {
    if (!this.ready) throw this.unavailable();
  }
  unavailable() {
    return new Error(this.value.diagnostic?.message ?? 'Хранилище ещё не готово', {
      cause: this.failureReason,
    });
  }
  async run<T>(stage: Stage, operation: () => T | Promise<T>): Promise<T> {
    this.assertNotFailed();
    try {
      return await operation();
    } catch (reason) {
      if (this.value.status !== 'failed') {
        this.reason = reason;
        const code = (reason as NodeJS.ErrnoException | null)?.code;
        this.value = {
          ...this.value,
          status: 'failed',
          diagnostic: {
            stage,
            code: typeof code === 'string' && /^[A-Z0-9_]{1,80}$/.test(code) ? code : undefined,
            message: messages[stage],
          },
        };
        console.error('Clipboard storage failed', this.state());
        this.changed();
      }
      throw this.unavailable();
    }
  }
}
