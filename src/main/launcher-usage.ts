import type { LauncherUsageStats } from '../shared/launcher';

interface Options {
  read: () => Promise<unknown>;
  save: (usage: LauncherUsageStats) => Promise<unknown>;
  open: (id: string) => Promise<{ opened: boolean }>;
  now?: () => number;
  onError: (error: unknown) => void;
}

/** Local ranking is best effort: a storage error must not turn a successful launch into a failure. */
export class LauncherUsage {
  private usage: LauncherUsageStats = {};
  private loading?: Promise<void>;
  private saving = Promise.resolve();
  constructor(private readonly options: Options) {}

  async state(): Promise<LauncherUsageStats> {
    if (!this.loading) {
      this.loading = this.options
        .read()
        .then((saved) => {
          if (!saved || typeof saved !== 'object' || Array.isArray(saved)) return;
          for (const [id, value] of Object.entries(saved)) {
            if (
              !/^mac:[a-f0-9]{32}$/.test(id) ||
              !value ||
              !Number.isSafeInteger(value.count) ||
              value.count <= 0 ||
              !Number.isSafeInteger(value.lastLaunchedAt) ||
              value.lastLaunchedAt < 0
            )
              continue;
            this.usage[id] = { count: value.count, lastLaunchedAt: value.lastLaunchedAt };
          }
        })
        .catch(this.options.onError);
    }
    await this.loading;
    return structuredClone(this.usage);
  }

  async open(id: string) {
    const result = await this.options.open(id);
    if (!result.opened) return { ...result, usage: await this.state() };
    const save = async () => {
      await this.state();
      this.usage[id] = {
        count: Math.min(Number.MAX_SAFE_INTEGER, (this.usage[id]?.count || 0) + 1),
        lastLaunchedAt: (this.options.now || Date.now)(),
      };
      try {
        await this.options.save(structuredClone(this.usage));
      } catch (error) {
        this.options.onError(error);
      }
    };
    this.saving = this.saving.then(save);
    await this.saving;
    return { ...result, usage: await this.state() };
  }
}
