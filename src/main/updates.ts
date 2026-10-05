export type UpdateState = {
  status:
    | 'unavailable'
    | 'idle'
    | 'checking'
    | 'current'
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
  quitAndInstall(): void;
  cancelPendingUpdate?(): void;
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
              'Эта сборка не подключена к каналу обновлений. Установите выпуск с GitHub, чтобы получать обновления.',
          }
        : {}),
    };
    adapter.on('checking', () => {
      if (this.enabled && ['idle', 'current', 'error'].includes(this.state.status))
        this.set({ status: 'checking', message: undefined, progress: undefined });
    });
    adapter.on('update-available', (info) => {
      if (this.enabled && ['idle', 'current', 'error', 'checking'].includes(this.state.status))
        this.set({ status: 'downloading', version: info.version, progress: 0, message: undefined });
    });
    adapter.on('update-not-available', () => {
      if (this.enabled && ['idle', 'current', 'error', 'checking'].includes(this.state.status))
        this.set({ status: 'current', version: undefined, message: undefined });
    });
    adapter.on('download-progress', (info) => {
      if (this.state.status === 'downloading')
        this.set({ progress: Math.max(0, Math.min(100, Number(info.percent) || 0)) });
    });
    adapter.on('update-downloaded', (info) => {
      if (this.enabled && this.state.status !== 'installing')
        this.set({ status: 'ready', version: info.version, progress: 100, message: undefined });
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
  cancelForQuit(explicitUpdate = false) {
    if (this.enabled && !explicitUpdate) {
      this.adapter.cancelPendingUpdate?.();
      // A save still in progress must not authorize installation after ordinary quit.
      this.set({ status: 'idle', version: undefined, progress: undefined });
    }
  }
  async handle(method: string) {
    if (method === 'updates.status') return this.status();
    if (!this.enabled) throw Error(this.state.message);
    if (this.busy) throw Error('Дождитесь завершения текущей операции обновления');
    if (method === 'updates.check') {
      if (['checking', 'downloading', 'ready', 'installing'].includes(this.state.status))
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
