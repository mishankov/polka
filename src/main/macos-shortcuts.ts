import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { SHORTCUT_ID, type MacShortcut, type ShortcutsState } from '../shared/macos-shortcuts';

const execute = promisify(execFile);
type SavedShortcut = { id: string; name: string };
export function parseShortcutList(output: string): SavedShortcut[] {
  const entries = new Map<string, SavedShortcut>();
  let offset = 0;
  for (const match of output.matchAll(/ \(([0-9a-f-]{36})\)\r?(?:\n|$)/gi)) {
    const name = output.slice(offset, match.index);
    if (!SHORTCUT_ID.test(match[1]) || !name.trim())
      throw Error('Не удалось прочитать список команд macOS. Откройте «Команды» и повторите.');
    const id = match[1].toLowerCase();
    entries.set(id, { id, name });
    offset = match.index + match[0].length;
  }
  // Preserve names with line breaks, but reject unsupported output rather than
  // marking the user's entire selection removed.
  if (output.slice(offset).trim())
    throw Error('Не удалось прочитать список команд macOS. Откройте «Команды» и повторите.');
  return [...entries.values()];
}
export function shortcutRunResult(
  code: number | null,
  stderr: string,
): {
  status: 'completed' | 'cancelled' | 'failed';
  message?: string;
} {
  if (code === 0) return { status: 'completed' };
  const message = stderr.trim();
  return {
    status: /\bcancell?ed\b|отмен[а-я]*|NSUserCancelledError|\(-128\)/i.test(message)
      ? 'cancelled'
      : 'failed',
    message:
      message || 'macOS прервала команду без пояснения. Проверьте её в приложении «Команды».',
  };
}
export const macShortcutsBackend = {
  async list() {
    const { stdout } = await execute('/usr/bin/shortcuts', ['list', '--show-identifiers'], {
      timeout: 15000,
      maxBuffer: 2 * 1024 * 1024,
    });
    return parseShortcutList(stdout);
  },
  run(
    id: string,
    signal: AbortSignal,
  ): Promise<{ status: 'completed' | 'cancelled' | 'failed'; message?: string }> {
    return new Promise((resolve) => {
      // Output can contain private content or large files; never collect or print it.
      const child = spawn('/usr/bin/shortcuts', ['run', id], {
        stdio: ['ignore', 'ignore', 'pipe'],
        signal,
      });
      let stderr = '';
      child.stderr.on('data', (chunk) => {
        if (stderr.length < 8192) stderr += chunk.toString().slice(0, 8192 - stderr.length);
      });
      child.on('error', (error) => resolve({ status: 'failed', message: error.message }));
      child.on('close', (code) => resolve(shortcutRunResult(code, stderr)));
    });
  },
};

export class MacShortcuts {
  private selected: SavedShortcut[] = [];
  private catalog: SavedShortcut[] = [];
  private loaded = false;
  private discovered = false;
  private error?: string;
  private runState?: ShortcutsState['run'];
  private queue: Promise<unknown> = Promise.resolve();
  private stopped = false;
  private controller?: AbortController;
  constructor(
    private readonly deps: {
      read: () => Promise<unknown>;
      save: (value: SavedShortcut[]) => Promise<unknown>;
      list: typeof macShortcutsBackend.list;
      run: typeof macShortcutsBackend.run;
      changed: (state: ShortcutsState) => void;
    },
  ) {}
  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.queue.then(fn);
    this.queue = next.catch(() => {});
    return next;
  }
  private async load() {
    if (this.loaded) return;
    const saved = await this.deps.read();
    if (
      saved !== null &&
      saved !== undefined &&
      (!Array.isArray(saved) ||
        saved.some(
          (s) =>
            !s || typeof s.id !== 'string' || !SHORTCUT_ID.test(s.id) || typeof s.name !== 'string',
        ))
    )
      throw Error(
        'Не удалось прочитать выбранные команды. Настройки сохранены; перезапустите Полку.',
      );
    this.selected = ((saved as SavedShortcut[]) || []).map((s) => ({
      id: s.id.toLowerCase(),
      name: s.name,
    }));
    this.loaded = true;
  }
  snapshot(): ShortcutsState {
    const names = new Map(this.catalog.map((s) => [s.id, s]));
    const chosen = new Set(this.selected.map((s) => s.id));
    const shortcuts: MacShortcut[] = [
      ...this.catalog.map((s) => ({
        ...s,
        selected: chosen.has(s.id),
        availability: this.error ? ('unknown' as const) : ('available' as const),
      })),
      ...this.selected
        .filter((s) => !names.has(s.id))
        .map((s) => ({
          ...s,
          selected: true,
          availability:
            this.error || !this.discovered ? ('unknown' as const) : ('missing' as const),
        })),
    ];
    shortcuts.sort((a, b) => a.name.localeCompare(b.name, 'ru') || a.id.localeCompare(b.id));
    return { shortcuts, error: this.error, run: this.runState && { ...this.runState } };
  }
  private notify() {
    this.deps.changed(this.snapshot());
  }
  state(refresh = false, discover = false) {
    return this.serial(async () => {
      await this.load();
      if (refresh && (discover || this.selected.length)) await this.refresh();
      return this.snapshot();
    });
  }
  private async refresh() {
    try {
      const catalog = await this.deps.list();
      const names = new Map(catalog.map((s) => [s.id, s.name]));
      const selected = this.selected.map((s) => ({ ...s, name: names.get(s.id) || s.name }));
      if (JSON.stringify(selected) !== JSON.stringify(this.selected))
        await this.deps.save(selected);
      this.selected = selected;
      this.catalog = catalog;
      this.discovered = true;
      this.error = undefined;
    } catch {
      this.error =
        'Не удалось обновить команды macOS. Откройте «Команды», затем обновите список. Выбранные команды сохранены.';
    }
    this.notify();
  }
  select(id: string, enabled: boolean) {
    return this.serial(async () => {
      await this.load();
      const existing = this.selected.find((s) => s.id === id);
      const shortcut = this.catalog.find((s) => s.id === id);
      if (enabled && (!shortcut || this.error))
        throw Error('Обновите список перед выбором команды.');
      const selected = this.selected.filter((s) => s.id !== id);
      if (enabled) selected.push(shortcut!);
      if (!existing && !enabled) return this.snapshot();
      await this.deps.save(selected);
      this.selected = selected;
      this.notify();
      return this.snapshot();
    });
  }
  async run(id: string) {
    if (this.stopped) throw Error('Полка завершает работу.');
    if (this.runState?.status === 'running') throw Error('Дождитесь завершения текущей команды.');
    // Reserve before async discovery so concurrent IPC calls cannot start duplicates.
    this.runState = {
      id,
      name: this.selected.find((s) => s.id === id)?.name || 'Команда',
      status: 'running',
    };
    this.notify();
    try {
      const state = await this.state(true);
      const shortcut = state.shortcuts.find((s) => s.id === id && s.selected);
      if (!shortcut) throw Error('Команда не выбрана. Добавьте её в настройках.');
      if (shortcut.availability !== 'available')
        throw Error(
          shortcut.availability === 'missing'
            ? 'Команда удалена или недоступна на этом Mac. Обновите выбор в настройках.'
            : 'Не удалось проверить доступность команды. Обновите список в настройках.',
        );
      this.runState.name = shortcut.name;
      if (this.stopped) throw Error('Полка завершает работу.');
      this.controller = new AbortController();
      const result = await this.deps.run(id, this.controller.signal);
      this.runState = { id, name: shortcut.name, ...result };
    } catch (error) {
      this.runState = {
        ...this.runState!,
        status: 'failed',
        message: error instanceof Error ? error.message : String(error),
      };
    } finally {
      this.controller = undefined;
      this.notify();
    }
    return this.snapshot();
  }
  stop() {
    this.stopped = true;
    this.controller?.abort();
  }
}
