import { randomUUID } from 'node:crypto';
import { access, stat } from 'node:fs/promises';
import { accessSync, constants, statSync } from 'node:fs';
import { basename, isAbsolute, normalize } from 'node:path';
import { MAX_SHELF_FILES, type FileShelfState, type ShelfFile } from '../shared/file-shelf';

/** Session-only references. Never writes, moves, deletes or syncs source files. */
export class FileShelf {
  private items: (ShelfFile & { identity: string })[] = [];
  private error = '';
  private queue: Promise<unknown> = Promise.resolve();
  constructor(private icon: (path: string) => Promise<string>) {}
  private serial<T>(operation: () => Promise<T>) {
    const next = this.queue.then(operation);
    this.queue = next.catch(() => {});
    return next;
  }
  snapshot(): FileShelfState {
    return {
      items: this.items.map(({ identity: _, ...item }) => ({ ...item })),
      error: this.error,
    };
  }
  add(paths: string[]) {
    return this.serial(async () => {
      this.error = '';
      for (const input of paths) {
        if (!isAbsolute(input) || input.includes('\0')) throw Error('Нужен локальный файл');
        const path = normalize(input);
        if (this.items.some((item) => item.path === path)) continue;
        if (this.items.length >= MAX_SHELF_FILES) {
          this.error = `На полке может быть до ${MAX_SHELF_FILES} файлов. Уберите ненужные и повторите.`;
          break;
        }
        try {
          const info = await stat(path);
          await access(path, constants.R_OK);
          if (!info.isFile() && !info.isDirectory()) throw Error('Unsupported file');
          this.items.push({
            id: randomUUID(),
            name: basename(path),
            path,
            identity: `${info.dev}:${info.ino}`,
            directory: info.isDirectory(),
            available: true,
            icon: await this.icon(path).catch(() => ''),
          });
        } catch {
          this.error = 'Некоторые файлы недоступны. Проверьте доступ и перетащите их ещё раз.';
        }
      }
      return this.snapshot();
    });
  }
  refresh() {
    return this.serial(async () => {
      await Promise.all(
        this.items.map(async (item) => {
          try {
            const info = await stat(item.path);
            await access(item.path, constants.R_OK);
            item.available = item.identity === `${info.dev}:${info.ino}`;
          } catch {
            item.available = false;
          }
        }),
      );
      return this.snapshot();
    });
  }
  remove(ids: string[]) {
    return this.serial(async () => {
      this.items = this.items.filter((item) => !ids.includes(item.id));
      this.error = '';
      return this.snapshot();
    });
  }
  clear() {
    return this.serial(async () => {
      this.items = [];
      this.error = '';
      return this.snapshot();
    });
  }
  /** Revalidate synchronously inside the native drag gesture; reject the entire selection. */
  drag(ids: string[]) {
    const selected = [...new Set(ids)].map((id) => this.items.find((item) => item.id === id));
    if (!selected.length || selected.some((item) => !item)) throw Error('Выберите файлы на полке');
    for (const item of selected) {
      try {
        const info = statSync(item!.path);
        accessSync(item!.path, constants.R_OK);
        if (item!.identity !== `${info.dev}:${info.ino}`) throw Error('File replaced');
      } catch {
        item!.available = false;
        this.error =
          'Файл перемещён, удалён или недоступен. Уберите ссылку и добавьте файл заново.';
        throw Error(this.error);
      }
    }
    return selected.map((item) => item!.path);
  }
}
