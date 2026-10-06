import { randomUUID } from 'node:crypto';

export interface PasteReply {
  trusted?: boolean;
  token?: string;
  sent?: boolean;
  reason?: string;
}
// Only opaque target tokens cross this bridge, never the previous field's contents.
export class ClipboardPaste {
  private pending = new Map<
    string,
    { resolve: (value: PasteReply) => void; timer: ReturnType<typeof setTimeout> }
  >();
  private token: string | undefined;
  private generation = 0;
  access: 'granted' | 'required' | 'unavailable' = 'unavailable';
  failureReason: string | undefined;
  constructor(private send: (message: string) => boolean) {}
  receive(message: { id: string; result: PasteReply }) {
    const request = this.pending.get(message.id);
    if (!request) return;
    clearTimeout(request.timer);
    this.pending.delete(message.id);
    request.resolve(message.result);
  }
  private request(method: string, params: Record<string, string> = {}): Promise<PasteReply> {
    return new Promise((resolve) => {
      const id = randomUUID();
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve({});
      }, 1800);
      this.pending.set(id, { resolve, timer });
      let sent = false;
      try {
        sent = this.send(
          JSON.stringify({ id, method, expiresAt: Date.now() + 1500, ...params }) + '\n',
        );
      } catch {
        /* Disconnected helper: copying still works. */
      }
      if (!sent) {
        clearTimeout(timer);
        this.pending.delete(id);
        resolve({});
      }
    });
  }
  async status(prompt = false) {
    const generation = this.generation;
    const result = await this.request(prompt ? 'requestAccess' : 'status');
    if (generation !== this.generation) return this.access;
    this.access =
      result.trusted === true ? 'granted' : result.trusted === false ? 'required' : 'unavailable';
    return this.access;
  }
  async capture() {
    const generation = ++this.generation;
    this.token = undefined;
    this.failureReason = undefined;
    const result = await this.request('capture');
    if (generation !== this.generation) return;
    this.access =
      result.trusted === true ? 'granted' : result.trusted === false ? 'required' : 'unavailable';
    this.token = result.trusted === true ? result.token : undefined;
  }
  get ready() {
    return this.access === 'granted' && !!this.token;
  }
  async paste() {
    const token = this.token;
    this.token = undefined;
    this.failureReason = undefined;
    if (!token) return false;
    const result = await this.request('paste', { token });
    if (result.sent !== true) this.failureReason = result.reason;
    return result.sent === true;
  }
  cancel() {
    this.generation++;
    this.token = undefined;
    void this.request('cancel');
  }
  stop() {
    this.generation++;
    this.token = undefined;
    this.access = 'unavailable';
    for (const { resolve, timer } of this.pending.values()) {
      clearTimeout(timer);
      resolve({});
    }
    this.pending.clear();
  }
}
