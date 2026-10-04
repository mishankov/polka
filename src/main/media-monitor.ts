import { parseMediaActivity, UNKNOWN_MEDIA, type MediaActivity } from '../shared/media-indicator';

// No concurrent polling within an epoch; late results cannot revive a disabled overlay.
export class MediaMonitor {
  private generation = 0;
  private timer?: ReturnType<typeof setTimeout>;
  private running = false;
  private current: MediaActivity = { ...UNKNOWN_MEDIA };

  constructor(
    private read: () => Promise<unknown>,
    private changed: (activity: MediaActivity) => void,
    private interval = 1000,
  ) {}

  get activity() {
    return { ...this.current };
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.current = { ...UNKNOWN_MEDIA };
    // Wait for the initial bounded probe before showing an unavailable state.
    void this.poll(++this.generation);
  }

  stop() {
    this.running = false;
    this.generation++;
    clearTimeout(this.timer);
    this.timer = undefined;
    this.current = { ...UNKNOWN_MEDIA };
  }

  private async poll(generation: number) {
    let next: MediaActivity;
    try {
      next = parseMediaActivity(await this.read());
    } catch {
      next = { ...UNKNOWN_MEDIA };
    }
    if (!this.running || generation !== this.generation) return;
    this.current = next;
    this.changed(this.activity);
    this.timer = setTimeout(() => void this.poll(generation), this.interval);
  }
}
