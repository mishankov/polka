import { DEFAULT_LAUNCHER_SHORTCUT, type LauncherPreferences } from '../shared/launcher';

interface Shortcuts {
  register(accelerator: string, callback: () => void): boolean;
  unregister(accelerator: string): void;
}

// Reserve the replacement before releasing the old shortcut, including on save failure.
export class LauncherShortcut {
  private state: LauncherPreferences = {
    accelerator: DEFAULT_LAUNCHER_SHORTCUT,
    registered: false,
  };
  private queue: Promise<unknown> = Promise.resolve();
  constructor(
    private shortcuts: Shortcuts,
    private toggle: () => void,
    private save: (accelerator: string) => Promise<unknown>,
  ) {}
  getPreferences() {
    return { ...this.state };
  }
  initialize(accelerator: string) {
    this.state = { accelerator, registered: false };
    if (!accelerator) return;
    try {
      if (!this.shortcuts.register(accelerator, this.toggle))
        throw Error('Сочетание занято другой программой. Выберите другое в настройках.');
      this.state.registered = true;
    } catch (error) {
      this.state.error = String(error);
    }
  }
  set(accelerator: string): Promise<LauncherPreferences> {
    const operation = this.queue.then(async () => {
      const previous = this.state;
      if (previous.accelerator === accelerator && previous.registered) return this.getPreferences();
      if (accelerator && !this.shortcuts.register(accelerator, this.toggle))
        throw Error('Сочетание недоступно или занято другой программой. Выберите другое.');
      try {
        await this.save(accelerator);
      } catch (error) {
        if (accelerator) this.shortcuts.unregister(accelerator);
        throw error;
      }
      if (previous.registered && previous.accelerator !== accelerator)
        this.shortcuts.unregister(previous.accelerator);
      this.state = { accelerator, registered: !!accelerator };
      return this.getPreferences();
    });
    this.queue = operation.catch(() => {});
    return operation;
  }
}
