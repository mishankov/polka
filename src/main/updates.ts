export type UpdateState = {
  status:
    | 'unavailable'
    | 'idle'
    | 'checking'
    | 'current'
    | 'available'
    | 'downloading'
    | 'ready'
    | 'installing'
    | 'error';
  currentVersion: string;
  version?: string;
  progress?: number;
  message?: string;
};
export interface UpdateAdapter {
  on(event: string, listener: (...args: any[]) => void): unknown;
  checkForUpdates(): Promise<unknown>;
  downloadUpdate(): Promise<unknown>;
  quitAndInstall(): void;
}

// Pure state machine: real Electron adapter in main, deterministic event adapter in tests.
export class UpdateService {
  private state: UpdateState;
  private busy = false;
  constructor(
    private adapter: UpdateAdapter,
    currentVersion: string,
    private enabled: boolean,
    private emit: (state: UpdateState) => void,
    private beforeInstall: () => Promise<void>,
    private restoreAfterInstallFailure: () => void = () => {},
  ) {
    this.state = {
      status: enabled ? 'idle' : 'unavailable',
      currentVersion,
      ...(!enabled
        ? {
            message:
              'Эта локальная сборка не подключена к каналу обновлений. Установите подписанный выпуск, чтобы получать обновления.',
          }
        : {}),
    };
    adapter.on('update-available', (info) => {
      if (this.enabled && this.state.status === 'checking')
        this.set({ status: 'available', version: info.version, message: undefined });
    });
    adapter.on('update-not-available', () => {
      if (this.enabled && this.state.status === 'checking')
        this.set({ status: 'current', version: undefined, message: undefined });
    });
    adapter.on('download-progress', (info) => {
      if (this.state.status === 'downloading')
        this.set({ progress: Math.max(0, Math.min(100, Number(info.percent) || 0)) });
    });
    adapter.on('update-downloaded', (info) => {
      if (this.state.status === 'downloading')
        this.set({ status: 'ready', version: info.version, progress: 100 });
    });
    adapter.on('error', () => {
      if (this.state.status === 'installing') this.restoreAfterInstallFailure();
      if (enabled)
        this.set({
          status: 'error',
          message: 'Не удалось обновить приложение. Проверьте подключение и повторите проверку.',
        });
    });
  }
  private set(change: Partial<UpdateState>) {
    this.state = { ...this.state, ...change };
    this.emit(this.status());
  }
  status() {
    return { ...this.state };
  }
  async handle(method: string) {
    if (method === 'updates.status') return this.status();
    if (!this.enabled) throw Error(this.state.message);
    if (this.busy) throw Error('Дождитесь завершения текущей операции обновления');
    if (method === 'updates.check') {
      if (['downloading', 'ready', 'installing'].includes(this.state.status))
        throw Error('Сначала завершите текущее обновление');
      this.busy = true;
      this.set({ status: 'checking', message: undefined, progress: undefined });
      try {
        await this.adapter.checkForUpdates();
      } catch {
        this.set({
          status: 'error',
          message: 'Не удалось проверить обновления. Повторите попытку позже.',
        });
      } finally {
        this.busy = false;
      }
    } else if (method === 'updates.download') {
      if (this.state.status !== 'available') throw Error('Сначала проверьте наличие обновления');
      this.busy = true;
      this.set({ status: 'downloading', progress: 0, message: undefined });
      try {
        await this.adapter.downloadUpdate();
      } catch {
        this.set({
          status: 'error',
          message: 'Загрузка не завершена. Повторите проверку обновлений.',
        });
      } finally {
        this.busy = false;
      }
    } else if (method === 'updates.install') {
      if (this.state.status !== 'ready') throw Error('Обновление ещё не загружено');
      this.busy = true;
      this.set({ status: 'installing', message: undefined });
      try {
        await this.beforeInstall();
        if (this.status().status === 'installing') this.adapter.quitAndInstall();
      } catch {
        this.restoreAfterInstallFailure();
        this.set({
          status: 'ready',
          message: 'Не удалось сохранить историю буфера или начать установку. Повторите попытку.',
        });
      } finally {
        this.busy = false;
      }
    } else throw Error('Неизвестная операция обновления');
    return this.status();
  }
}
