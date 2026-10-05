import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

/** Reuse the existing settings table without loading or changing legacy workspace data. */
export class SettingsStore {
  private readonly db: DatabaseSync;
  constructor(root: string) {
    mkdirSync(root, { recursive: true });
    this.db = new DatabaseSync(join(root, 'workspace.sqlite'));
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);`);
  }
  async handle(method: string, params: any = {}) {
    if (method === 'settings.get') {
      if (params.key) {
        const row = this.db.prepare('SELECT value FROM settings WHERE key=?').get(params.key);
        return row ? JSON.parse(String(row.value)) : null;
      }
      return Object.fromEntries(
        this.db
          .prepare('SELECT key,value FROM settings')
          .all()
          .map((row) => [row.key, JSON.parse(String(row.value))]),
      );
    }
    if (method === 'settings.set') {
      const value = JSON.stringify(params.value);
      if (
        typeof params.key !== 'string' ||
        params.key.length > 300 ||
        value === undefined ||
        value.length > 10_000_000
      )
        throw Error('Некорректные настройки');
      if (/secret|password|api[-_]?key|token/i.test(params.key))
        throw Error('Секреты должны храниться в защищённом хранилище');
      this.db
        .prepare(
          'INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
        )
        .run(params.key, value);
      return params.value;
    }
    throw Error('Неизвестная операция');
  }
  close() {
    this.db.close();
  }
}
