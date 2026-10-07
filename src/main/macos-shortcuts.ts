import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { SHORTCUT_ID, type MacShortcut, type ShortcutsState } from '../shared/macos-shortcuts';

const execute = promisify(execFile);
type InstalledShortcut = { id: string; name: string };
export function parseShortcutList(output: string): InstalledShortcut[] {
  const entries = new Map<string, InstalledShortcut>();
  let offset = 0;
  for (const match of output.matchAll(/ \(([0-9a-f-]{36})\)\r?(?:\n|$)/gi)) {
    const name = output.slice(offset, match.index);
    if (!SHORTCUT_ID.test(match[1]) || !name.trim())
      throw Error('Не удалось прочитать список команд macOS. Откройте «Команды» и повторите.');
    const id = match[1];
    entries.set(id.toLowerCase(), { id, name });
    offset = match.index + match[0].length;
  }
  // Preserve names with line breaks, but reject unsupported output rather than
  // discarding the last known catalog.
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
  private catalog: InstalledShortcut[] = [];
  private discovered = false;
  private error?: string;
  private runState?: ShortcutsState['run'];
  private queue: Promise<unknown> = Promise.resolve();
  private stopped = false;
  private controller?: AbortController;
  constructor(
    private readonly deps: {
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
  snapshot(): ShortcutsState {
    const shortcuts: MacShortcut[] = this.catalog.map((s) => ({
      ...s,
      availability: this.error ? 'unknown' : 'available',
    }));
    shortcuts.sort((a, b) => a.name.localeCompare(b.name, 'ru') || a.id.localeCompare(b.id));
    return { shortcuts, error: this.error, run: this.runState && { ...this.runState } };
  }
  private notify() {
    this.deps.changed(this.snapshot());
  }
  state(refresh = false) {
    return this.serial(async () => {
      if (refresh || !this.discovered) await this.refresh();
      return this.snapshot();
    });
  }
  private async refresh() {
    try {
      this.catalog = await this.deps.list();
      this.discovered = true;
      this.error = undefined;
    } catch {
      this.error =
        'Не удалось обновить команды macOS. Откройте «Команды», затем обновите список. Последний список сохранён до следующего обновления.';
    }
    this.notify();
  }
  async run(id: string) {
    if (this.stopped) throw Error('Полка завершает работу.');
    if (this.runState?.status === 'running') throw Error('Дождитесь завершения текущей команды.');
    // Reserve before async discovery so concurrent IPC calls cannot start duplicates.
    this.runState = {
      id,
      name: this.catalog.find((s) => s.id.toLowerCase() === id.toLowerCase())?.name || 'Команда',
      status: 'running',
    };
    this.notify();
    try {
      const state = await this.state(true);
      if (state.error)
        throw Error('Не удалось проверить доступность команды. Обновите список на полке.');
      const shortcut = state.shortcuts.find((s) => s.id.toLowerCase() === id.toLowerCase());
      if (!shortcut) throw Error('Команда удалена или недоступна на этом Mac. Список обновлён.');
      if (shortcut.availability !== 'available')
        throw Error('Не удалось проверить доступность команды. Обновите список на полке.');
      this.runState.name = shortcut.name;
      if (this.stopped) throw Error('Полка завершает работу.');
      this.controller = new AbortController();
      // Treat UUIDs case-insensitively for lookup, but pass the native catalog
      // identifier unchanged to macOS.
      const result = await this.deps.run(shortcut.id, this.controller.signal);
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
