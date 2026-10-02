import { DatabaseSync } from 'node:sqlite';
import { randomUUID, createHash } from 'node:crypto';
import {
  mkdirSync,
  readFileSync,
  writeFileSync,
  renameSync,
  unlinkSync,
  existsSync,
  statSync,
  readdirSync,
} from 'node:fs';
import { join, basename } from 'node:path';
import { zipSync, strToU8, strFromU8 } from 'fflate';
import type { AppDefinition, AppInstance, DataRecord, EntityDefinition } from '../shared/types';
import { boundedUnzip } from './bounded-zip';
import { emptyDefinition, validateDefinition, validateValues } from './schema';

const now = () => new Date().toISOString();
const uuid = () => randomUUID();
const parse = (v: any) => JSON.parse(v);
const hash = (v: Uint8Array | string) => createHash('sha256').update(v).digest('hex');
const MAX_PACKAGE = 64 * 1024 * 1024;
const MAX_EXPANDED = 128 * 1024 * 1024;
interface Attachment {
  id: string;
  appId: string;
  name: string;
  size: number;
  sha256: string;
  createdAt: string;
}
export interface Bundle {
  definition: AppDefinition;
  records: DataRecord[];
  attachments: Attachment[];
  files: Record<string, Uint8Array>;
  manifest: any;
  documents?: any[];
  demoRecords?: DataRecord[];
}

/** Trusted data service. Run in a utility process to keep SQLite/ZIP work off the Electron main thread. */
export class CoreService {
  readonly db: DatabaseSync;
  private previews = new Map<
    string,
    {
      bundle: Bundle;
      path?: string;
      staged?: boolean;
      hash?: string;
      sources?: { id: string; revision: number; version: number }[];
      update?: { appId: string; version: number; revision: number; definition: AppDefinition };
    }
  >();
  constructor(readonly root: string) {
    mkdirSync(root, { recursive: true });
    mkdirSync(join(root, 'attachments'), { recursive: true });
    this.db = new DatabaseSync(join(root, 'workspace.sqlite'));
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
   CREATE TABLE IF NOT EXISTS apps(id TEXT PRIMARY KEY,name TEXT NOT NULL,icon TEXT NOT NULL,description TEXT NOT NULL,status TEXT NOT NULL,favorite INTEGER NOT NULL DEFAULT 0,version INTEGER NOT NULL,revision INTEGER NOT NULL DEFAULT 0,templateId TEXT NOT NULL,sourceVersion INTEGER NOT NULL,createdAt TEXT NOT NULL,updatedAt TEXT NOT NULL,definition TEXT NOT NULL);
   CREATE TABLE IF NOT EXISTS definitions(appId TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,version INTEGER NOT NULL,definition TEXT NOT NULL,createdAt TEXT NOT NULL,PRIMARY KEY(appId,version));
   CREATE TABLE IF NOT EXISTS records(id TEXT NOT NULL,appId TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,entityId TEXT NOT NULL,valuesJson TEXT NOT NULL,createdAt TEXT NOT NULL,updatedAt TEXT NOT NULL,PRIMARY KEY(appId,id));
   CREATE INDEX IF NOT EXISTS records_entity ON records(appId,entityId);
   CREATE TABLE IF NOT EXISTS drafts(id TEXT PRIMARY KEY,appId TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,baseVersion INTEGER NOT NULL,baseRevision INTEGER NOT NULL,definition TEXT NOT NULL,createdAt TEXT NOT NULL);
   CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
   CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL);
   CREATE TABLE IF NOT EXISTS permissions(appId TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,permission TEXT NOT NULL,scope TEXT NOT NULL,grantedAt TEXT NOT NULL,PRIMARY KEY(appId,permission));
   CREATE TABLE IF NOT EXISTS links(id TEXT PRIMARY KEY,sourceAppId TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,targetAppId TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,entityId TEXT NOT NULL,createdAt TEXT NOT NULL);
   CREATE TABLE IF NOT EXISTS snapshots(id TEXT PRIMARY KEY,appId TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,label TEXT NOT NULL,content TEXT NOT NULL,createdAt TEXT NOT NULL);
   CREATE TABLE IF NOT EXISTS origins(appId TEXT PRIMARY KEY REFERENCES apps(id) ON DELETE CASCADE,definition TEXT NOT NULL,sourceVersion INTEGER NOT NULL);
   CREATE TABLE IF NOT EXISTS attachments(id TEXT PRIMARY KEY,appId TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,name TEXT NOT NULL,size INTEGER NOT NULL,sha256 TEXT NOT NULL,createdAt TEXT NOT NULL);
  `);
    this.db.exec(
      `CREATE TABLE IF NOT EXISTS demo_data(appId TEXT PRIMARY KEY REFERENCES apps(id) ON DELETE CASCADE, recordsJson TEXT NOT NULL)`,
    );
    this.collectAttachments();
  }
  close() {
    this.db.close();
  }
  private transaction<T>(fn: () => T): T {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const result = fn();
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }
  private app(id: string): AppInstance {
    const row: any = this.db.prepare('SELECT * FROM apps WHERE id=?').get(id);
    if (!row) throw new Error('Приложение не найдено');
    return { ...row, favorite: !!row.favorite, definition: parse(row.definition) };
  }
  private entity(appId: string, entityId: string): EntityDefinition {
    const entity = this.app(appId).definition.entities.find((x) => x.id === entityId);
    if (!entity) throw new Error('Сущность не найдена в этом приложении');
    return entity;
  }
  private rows(appId: string, entityId?: string): DataRecord[] {
    const rows: any[] = entityId
      ? this.db.prepare('SELECT * FROM records WHERE appId=? AND entityId=?').all(appId, entityId)
      : this.db.prepare('SELECT * FROM records WHERE appId=?').all(appId);
    return rows.map(({ valuesJson, ...r }) => ({ ...r, values: parse(valuesJson) }));
  }
  private prunePermissions(appId: string, d: AppDefinition) {
    for (const row of this.db
      .prepare('SELECT permission FROM permissions WHERE appId=?')
      .all(appId) as any[])
      if (!d.permissions.includes(row.permission))
        this.db
          .prepare('DELETE FROM permissions WHERE appId=? AND permission=?')
          .run(appId, row.permission);
  }
  private bump(appId: string) {
    this.db.prepare('UPDATE apps SET revision=revision+1,updatedAt=? WHERE id=?').run(now(), appId);
  }
  private create(input: any): AppInstance {
    const d = validateDefinition(
      input.definition || emptyDefinition(input.name || 'Новое приложение'),
    );
    const id = uuid(),
      time = now();
    this.db
      .prepare('INSERT INTO apps VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)')
      .run(
        id,
        input.name || d.name,
        input.icon || d.icon || '✦',
        input.description || d.description || '',
        'stopped',
        0,
        1,
        0,
        input.templateId || uuid(),
        input.sourceVersion || 1,
        time,
        time,
        JSON.stringify(d),
      );
    this.db.prepare('INSERT INTO definitions VALUES(?,?,?,?)').run(id, 1, JSON.stringify(d), time);
    this.db
      .prepare('INSERT INTO origins VALUES(?,?,?)')
      .run(id, JSON.stringify(d), input.sourceVersion || 1);
    return this.app(id);
  }
  private checkRelations(
    appId: string,
    entity: EntityDefinition,
    values: Record<string, unknown>,
    records?: DataRecord[],
  ) {
    for (const f of entity.fields) {
      const value = values[f.id];
      if (!value) continue;
      if (f.type === 'relation') {
        const found = records
          ? records.some((r) => r.entityId === f.targetEntity && r.id === value)
          : this.db
              .prepare('SELECT 1 FROM records WHERE appId=? AND entityId=? AND id=?')
              .get(appId, f.targetEntity!, String(value));
        if (!found) throw new Error(`Связанная запись поля «${f.name}» недоступна`);
      }
      if (
        f.type === 'attachment' &&
        !this.db
          .prepare('SELECT 1 FROM attachments WHERE appId=? AND id=?')
          .get(appId, String(value))
      )
        throw new Error('Вложение недоступно этому приложению');
    }
  }
  private checkUnique(
    appId: string,
    entity: EntityDefinition,
    values: Record<string, unknown>,
    recordId?: string,
    records?: DataRecord[],
  ) {
    for (const f of entity.fields.filter((x) => x.unique)) {
      const value = values[f.id];
      if (value === undefined || value === null || value === '') continue;
      if (
        (records || this.rows(appId, entity.id)).some(
          (r) =>
            r.entityId === entity.id &&
            r.id !== recordId &&
            JSON.stringify(r.values[f.id]) === JSON.stringify(value),
        )
      )
        throw new Error(`Значение «${f.name}» должно быть уникальным`);
    }
  }
  private validateMigration(app: AppInstance, d: AppDefinition) {
    const records = this.rows(app.id).map((r) => {
      const e = d.entities.find((x) => x.id === r.entityId);
      if (!e)
        throw new Error(
          `Сущность ${r.entityId} содержит записи. Сначала перенесите или удалите их явно`,
        );
      return { ...r, values: validateValues(e, r.values) };
    });
    for (const r of records) {
      const e = d.entities.find((x) => x.id === r.entityId)!;
      this.checkRelations(app.id, e, r.values, records);
      this.checkUnique(app.id, e, r.values, r.id, records);
    }
    for (const link of this.db
      .prepare('SELECT * FROM links WHERE targetAppId=?')
      .all(app.id) as any[])
      if (!d.entities.some((e) => e.id === link.entityId))
        throw new Error('Удаляемая сущность используется другим приложением');
  }
  private snapshot(appId: string, label = 'Резервная копия') {
    const app = this.app(appId),
      id = uuid(),
      createdAt = now();
    const records = this.rows(appId);
    this.db
      .prepare('INSERT INTO snapshots VALUES(?,?,?,?,?)')
      .run(
        id,
        appId,
        label,
        JSON.stringify({ definition: app.definition, records, version: app.version }),
        createdAt,
      );
    return { id, appId, label, createdAt, recordCount: records.length, version: app.version };
  }
  private listRecords(p: any) {
    this.entity(p.appId, p.entityId);
    let records = this.rows(p.appId, p.entityId);
    if (p.search)
      records = records.filter((r) =>
        JSON.stringify(r.values).toLocaleLowerCase().includes(String(p.search).toLocaleLowerCase()),
      );
    if (p.filters) {
      if (!Array.isArray(p.filters) || p.filters.length > 30)
        throw new Error('Некорректные фильтры');
      for (const f of p.filters) {
        this.entity(p.appId, p.entityId).fields.find((x) => x.id === f.field) ||
          (() => {
            throw new Error('Неизвестное поле фильтра');
          })();
        records = records.filter((r) =>
          f.op === 'eq'
            ? r.values[f.field] === f.value
            : f.op === 'contains'
              ? String(r.values[f.field] ?? '').includes(String(f.value))
              : f.op === 'gt'
                ? Number(r.values[f.field]) > Number(f.value)
                : f.op === 'lt'
                  ? Number(r.values[f.field]) < Number(f.value)
                  : false,
        );
      }
    }
    if (p.sort) {
      const sign = p.sort.direction === 'desc' ? -1 : 1;
      records.sort((a, b) => {
        const av = a.values[p.sort.field],
          bv = b.values[p.sort.field];
        return (
          sign *
          (typeof av === 'number' && typeof bv === 'number'
            ? av - bv
            : String(av ?? '').localeCompare(String(bv ?? ''), 'ru'))
        );
      });
    }
    const total = records.length,
      offset = Math.max(0, Number(p.offset) || 0),
      limit = Math.min(1000, Math.max(1, Number(p.limit) || 100));
    return { records: records.slice(offset, offset + limit), total };
  }
  async callScoped(appId: string, method: string, params: any = {}) {
    this.app(appId);
    const allowed = [
      'apps.get',
      'records.list',
      'records.upsert',
      'records.delete',
      'records.batch',
      'attachments.list',
      'attachments.read',
      'links.list',
      'links.query',
    ];
    if (!allowed.includes(method)) throw new Error('Эта операция недоступна расширению');
    if (params.appId && params.appId !== appId)
      throw new Error('Доступ к другому экземпляру запрещён');
    return this.handle(method, { ...params, appId });
  }
  async handle(method: string, p: any = {}): Promise<any> {
    if (typeof method !== 'string' || !p || typeof p !== 'object' || Array.isArray(p))
      throw new Error('Некорректный запрос');
    switch (method) {
      case 'apps.list':
        return (
          this.db
            .prepare('SELECT id FROM apps ORDER BY favorite DESC,updatedAt DESC')
            .all() as any[]
        ).map((x) => this.app(x.id));
      case 'apps.get':
        return this.app(p.appId);
      case 'apps.create':
        return this.transaction(() => this.create(p));
      case 'apps.start':
        return this.transaction(() => {
          const app = this.app(p.appId);
          if (app.status === 'running') return app;
          this.db
            .prepare('UPDATE apps SET status=?,updatedAt=? WHERE id=?')
            .run('running', now(), app.id);
          return this.app(app.id);
        });
      case 'apps.updateMeta':
        return this.transaction(() => {
          const app = this.app(p.appId);
          if (p.status && !['running', 'stopped', 'archived'].includes(p.status))
            throw new Error('Неизвестное состояние');
          if (
            p.name !== undefined &&
            (typeof p.name !== 'string' || !p.name.trim() || p.name.length > 200)
          )
            throw new Error('Введите название до 200 символов');
          this.db
            .prepare('UPDATE apps SET name=?,icon=?,favorite=?,status=?,updatedAt=? WHERE id=?')
            .run(
              p.name ?? app.name,
              p.icon ?? app.icon,
              p.favorite === undefined ? Number(app.favorite) : Number(!!p.favorite),
              p.status ?? app.status,
              now(),
              app.id,
            );
          return this.app(app.id);
        });
      case 'apps.duplicate': {
        const bundle = this.bundle(p.appId, { mode: p.withData === false ? 'template' : 'data' });
        bundle.definition.name += ' — копия';
        bundle.manifest.name = bundle.definition.name;
        return this.install(bundle).app;
      }
      case 'apps.delete': {
        this.app(p.appId);
        const dependencies = this.db
          .prepare('SELECT * FROM links WHERE targetAppId=? OR sourceAppId=?')
          .all(p.appId, p.appId);
        if (p.confirm !== true)
          return { appId: p.appId, dependencies, recordCount: this.rows(p.appId).length };
        this.transaction(() => {
          this.db.prepare('DELETE FROM apps WHERE id=?').run(p.appId);
          const stored: any = this.db
            .prepare('SELECT value FROM state WHERE key=?')
            .get('documents');
          if (stored)
            this.db
              .prepare('UPDATE state SET value=? WHERE key=?')
              .run(
                JSON.stringify(parse(stored.value).filter((d: any) => d.appId !== p.appId)),
                'documents',
              );
        });
        this.collectAttachments();
        return { deleted: true };
      }
      case 'definitions.prepare':
        return this.transaction(() => {
          const app = this.app(p.appId),
            definition = validateDefinition(p.definition);
          this.validateMigration(app, definition);
          const id = uuid();
          this.db
            .prepare('INSERT INTO drafts VALUES(?,?,?,?,?,?)')
            .run(id, app.id, app.version, app.revision, JSON.stringify(definition), now());
          return {
            draftId: id,
            baseVersion: app.version,
            baseRevision: app.revision,
            changes: {
              entities: definition.entities.length,
              screens: definition.screens.length,
              recordsPreserved: this.rows(app.id).length,
            },
            warnings: definition.permissions
              .filter((x) => !app.definition.permissions.includes(x))
              .map((x) => `Новое разрешение: ${x}`),
          };
        });
      case 'definitions.activate':
        return this.transaction(() => {
          const draft: any = this.db.prepare('SELECT * FROM drafts WHERE id=?').get(p.draftId);
          if (!draft) throw new Error('Подготовленная версия не найдена');
          const app = this.app(draft.appId);
          if (app.version !== draft.baseVersion || app.revision !== draft.baseRevision)
            throw new Error('Данные или определение изменились. Подготовьте изменение заново');
          const d = validateDefinition(parse(draft.definition));
          this.validateMigration(app, d);
          this.snapshot(app.id, 'Перед изменением определения');
          for (const record of this.rows(app.id)) {
            const e = d.entities.find((x) => x.id === record.entityId)!;
            this.db
              .prepare('UPDATE records SET valuesJson=? WHERE appId=? AND id=?')
              .run(JSON.stringify(validateValues(e, record.values)), app.id, record.id);
          }
          this.db
            .prepare(
              'UPDATE apps SET definition=?,version=version+1,revision=revision+1,updatedAt=? WHERE id=?',
            )
            .run(JSON.stringify(d), now(), app.id);
          this.db
            .prepare('INSERT INTO definitions VALUES(?,?,?,?)')
            .run(app.id, app.version + 1, JSON.stringify(d), now());
          this.prunePermissions(app.id, d);
          this.db.prepare('DELETE FROM drafts WHERE id=?').run(draft.id);
          return this.app(app.id);
        });
      case 'definitions.history':
        this.app(p.appId);
        return (
          this.db
            .prepare(
              'SELECT version,definition,createdAt FROM definitions WHERE appId=? ORDER BY version DESC',
            )
            .all(p.appId) as any[]
        ).map((r) => ({ ...r, definition: parse(r.definition) }));
      case 'records.batch':
        return this.recordBatch(p);
      case 'records.list':
        return this.listRecords(p);
      case 'records.upsert':
        return this.transaction(() => {
          const e = this.entity(p.appId, p.entityId),
            values = validateValues(e, p.values),
            id = p.id || uuid();
          if (typeof id !== 'string' || id.length > 200)
            throw new Error('Неверный идентификатор записи');
          const old: any = this.db
            .prepare('SELECT * FROM records WHERE appId=? AND id=?')
            .get(p.appId, id);
          if (old && old.entityId !== p.entityId)
            throw new Error('Запись принадлежит другой сущности');
          this.checkRelations(p.appId, e, values);
          this.checkUnique(p.appId, e, values, id);
          const time = now();
          this.db
            .prepare(
              'INSERT INTO records VALUES(?,?,?,?,?,?) ON CONFLICT(appId,id) DO UPDATE SET valuesJson=excluded.valuesJson,updatedAt=excluded.updatedAt',
            )
            .run(id, p.appId, p.entityId, JSON.stringify(values), old?.createdAt || time, time);
          this.bump(p.appId);
          return {
            id,
            appId: p.appId,
            entityId: p.entityId,
            values,
            createdAt: old?.createdAt || time,
            updatedAt: time,
          };
        });
      case 'records.delete':
        return this.transaction(() => {
          const app = this.app(p.appId);
          this.entity(p.appId, p.entityId);
          for (const e of app.definition.entities)
            for (const f of e.fields.filter(
              (x) => x.type === 'relation' && x.targetEntity === p.entityId,
            ))
              if (this.rows(app.id, e.id).some((r) => r.values[f.id] === p.id && r.id !== p.id))
                throw new Error(
                  'Эта запись используется в связи. Сначала измените связанную запись',
                );
          const result = this.db
            .prepare('DELETE FROM records WHERE appId=? AND entityId=? AND id=?')
            .run(p.appId, p.entityId, p.id);
          if (!result.changes) throw new Error('Запись не найдена');
          this.bump(p.appId);
          return { deleted: true };
        });
      case 'settings.get':
      case 'state.get': {
        const table = method.startsWith('state') ? 'state' : 'settings';
        if (p.key) {
          const row: any = this.db.prepare(`SELECT value FROM ${table} WHERE key=?`).get(p.key);
          return row ? parse(row.value) : null;
        }
        return Object.fromEntries(
          (this.db.prepare(`SELECT * FROM ${table}`).all() as any[]).map((r) => [
            r.key,
            parse(r.value),
          ]),
        );
      }
      case 'settings.set':
      case 'state.set': {
        const table = method.startsWith('state') ? 'state' : 'settings';
        if (
          typeof p.key !== 'string' ||
          p.key.length > 300 ||
          p.value === undefined ||
          JSON.stringify(p.value).length > 10_000_000
        )
          throw new Error('Некорректные настройки');
        if (table === 'settings' && /secret|password|api[-_]?key|token/i.test(p.key))
          throw new Error('Секреты должны храниться в защищённом хранилище');
        this.db
          .prepare(
            `INSERT INTO ${table} VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`,
          )
          .run(p.key, JSON.stringify(p.value));
        return p.value;
      }
      case 'permissions.list':
        this.app(p.appId);
        return this.db
          .prepare('SELECT permission,scope,grantedAt FROM permissions WHERE appId=?')
          .all(p.appId);
      case 'permissions.grant': {
        const app = this.app(p.appId);
        if (!app.definition.permissions.includes(p.permission))
          throw new Error('Приложение не запрашивает это разрешение');
        if (typeof p.scope !== 'undefined' && typeof p.scope !== 'string')
          throw new Error('Неверная область разрешения');
        this.db
          .prepare(
            'INSERT INTO permissions VALUES(?,?,?,?) ON CONFLICT(appId,permission) DO UPDATE SET scope=excluded.scope,grantedAt=excluded.grantedAt',
          )
          .run(app.id, p.permission, p.scope || 'app', now());
        return { granted: true };
      }
      case 'permissions.revoke':
        this.app(p.appId);
        this.db
          .prepare('DELETE FROM permissions WHERE appId=? AND permission=?')
          .run(p.appId, p.permission);
        return { revoked: true };
      case 'search': {
        const query = String(p.query || '').toLocaleLowerCase();
        if (!query) return [];
        const appIds = p.appId
          ? [this.app(p.appId).id]
          : (this.db.prepare("SELECT id FROM apps WHERE status!='archived'").all() as any[]).map(
              (x) => x.id,
            );
        return appIds
          .flatMap((appId) =>
            this.rows(appId)
              .filter((r) => JSON.stringify(r.values).toLocaleLowerCase().includes(query))
              .map((r) => ({
                appId,
                entityId: r.entityId,
                id: r.id,
                title: String(Object.values(r.values)[0] || r.id),
                excerpt: Object.values(r.values)
                  .map((x) => (typeof x === 'object' ? JSON.stringify(x) : String(x)))
                  .join(' · ')
                  .slice(0, 250),
              })),
          )
          .slice(0, 100);
      }
      case 'links.list':
        this.app(p.appId);
        return this.db
          .prepare('SELECT * FROM links WHERE sourceAppId=? OR targetAppId=?')
          .all(p.appId, p.appId);
      case 'links.grant':
        this.app(p.sourceAppId);
        this.entity(p.targetAppId, p.entityId);
        {
          const id = uuid();
          this.db
            .prepare('INSERT INTO links VALUES(?,?,?,?,?)')
            .run(id, p.sourceAppId, p.targetAppId, p.entityId, now());
          return { id, ...p };
        }
      case 'links.revoke':
        this.db.prepare('DELETE FROM links WHERE id=?').run(p.id);
        return { revoked: true };
      case 'links.query': {
        const link: any = this.db
          .prepare('SELECT * FROM links WHERE id=? AND sourceAppId=?')
          .get(p.linkId, p.appId);
        if (!link) throw new Error('Связь не разрешена или доступ отозван');
        if (this.app(link.targetAppId).status !== 'running')
          throw new Error('Связанное приложение остановлено');
        return this.listRecords({
          appId: link.targetAppId,
          entityId: link.entityId,
          limit: p.limit,
        });
      }
      case 'snapshots.create':
        return this.snapshot(p.appId, p.label);
      case 'snapshots.list':
        this.app(p.appId);
        return (
          this.db
            .prepare(
              'SELECT id,appId,label,createdAt,content FROM snapshots WHERE appId=? ORDER BY createdAt DESC',
            )
            .all(p.appId) as any[]
        ).map(({ content, ...r }) => ({
          ...r,
          recordCount: parse(content).records.length,
          version: parse(content).version,
        }));
      case 'snapshots.restore': {
        if (p.confirm !== true) throw new Error('Подтвердите потерю изменений данных после снимка');
        return this.transaction(() => {
          const app = this.app(p.appId),
            snapshot: any = this.db
              .prepare('SELECT * FROM snapshots WHERE appId=? AND id=?')
              .get(app.id, p.snapshotId);
          if (!snapshot) throw new Error('Снимок не найден');
          const data = parse(snapshot.content),
            d = validateDefinition(data.definition);
          for (const r of data.records) {
            const e = d.entities.find((x) => x.id === r.entityId);
            if (!e) throw new Error('Повреждённый снимок');
            validateValues(e, r.values);
            this.checkRelations(app.id, e, r.values, data.records);
          }
          this.snapshot(app.id, 'Перед восстановлением');
          this.db.prepare('DELETE FROM records WHERE appId=?').run(app.id);
          for (const r of data.records) this.insertRecord({ ...r, appId: app.id });
          this.db
            .prepare(
              'UPDATE apps SET definition=?,version=version+1,revision=revision+1,status=?,updatedAt=? WHERE id=?',
            )
            .run(JSON.stringify(d), 'stopped', now(), app.id);
          this.db
            .prepare('INSERT INTO definitions VALUES(?,?,?,?)')
            .run(app.id, app.version + 1, JSON.stringify(d), now());
          this.prunePermissions(app.id, d);
          return this.app(app.id);
        });
      }
      case 'attachments.add': {
        this.app(p.appId);
        if (typeof p.path !== 'string') throw new Error('Выберите файл');
        const size = statSync(p.path).size;
        if (size > 32 * 1024 * 1024) throw new Error('Вложение превышает 32 МБ');
        const bytes = readFileSync(p.path),
          id = uuid();
        const a = {
          id,
          appId: p.appId,
          name: basename(p.name || p.path),
          size: bytes.length,
          sha256: hash(bytes),
          createdAt: now(),
        };
        writeFileSync(join(this.root, 'attachments', id), bytes, { flag: 'wx' });
        try {
          this.db
            .prepare('INSERT INTO attachments VALUES(?,?,?,?,?,?)')
            .run(id, a.appId, a.name, a.size, a.sha256, a.createdAt);
          this.bump(a.appId);
        } catch (e) {
          unlinkSync(join(this.root, 'attachments', id));
          throw e;
        }
        return a;
      }
      case 'attachments.list':
        this.app(p.appId);
        return this.db.prepare('SELECT * FROM attachments WHERE appId=?').all(p.appId);
      case 'attachments.read': {
        const a: any = this.db
          .prepare('SELECT * FROM attachments WHERE id=? AND appId=?')
          .get(p.id, p.appId);
        if (!a) throw new Error('Вложение не найдено');
        return {
          ...a,
          base64: readFileSync(join(this.root, 'attachments', a.id)).toString('base64'),
        };
      }
      case 'attachments.delete': {
        const app = this.app(p.appId);
        for (const e of app.definition.entities)
          for (const f of e.fields.filter((x) => x.type === 'attachment'))
            if (this.rows(app.id, e.id).some((r) => r.values[f.id] === p.id))
              throw new Error('Вложение используется записью');
        if (
          (
            this.db.prepare('SELECT content FROM snapshots WHERE appId=?').all(p.appId) as any[]
          ).some((s) => s.content.includes(p.id))
        )
          throw new Error('Вложение используется резервным снимком');
        const result = this.db
          .prepare('DELETE FROM attachments WHERE appId=? AND id=?')
          .run(p.appId, p.id);
        if (result.changes) {
          const file = join(this.root, 'attachments', p.id);
          if (existsSync(file)) unlinkSync(file);
          this.bump(p.appId);
        }
        return { deleted: !!result.changes };
      }
      case 'packages.demoGet': {
        this.app(p.appId);
        const stored: any = this.db
          .prepare('SELECT recordsJson FROM demo_data WHERE appId=?')
          .get(p.appId);
        return stored ? parse(stored.recordsJson) : [];
      }
      case 'packages.demoSave': {
        const app = this.app(p.appId);
        const records = this.validateDemo(app.definition, p.records);
        this.db
          .prepare(
            'INSERT INTO demo_data VALUES(?,?) ON CONFLICT(appId) DO UPDATE SET recordsJson=excluded.recordsJson',
          )
          .run(app.id, JSON.stringify(records));
        this.bump(app.id);
        return records;
      }
      case 'packages.preview': {
        const bundle = this.bundle(p.appId, p);
        return this.composition(bundle);
      }
      case 'packages.export': {
        const bundle = this.bundle(p.appId, p);
        const files = this.packageFiles(bundle);
        const bytes = zipSync(files, { level: 6 });
        if (bytes.length > MAX_PACKAGE) throw new Error('Пакет превышает 64 МБ');
        if (typeof p.path !== 'string' || !p.path.endsWith('.everyapp'))
          throw new Error('Выберите файл .everyapp');
        const temp = p.path + '.' + uuid() + '.tmp';
        try {
          writeFileSync(temp, bytes, { flag: 'wx' });
          renameSync(temp, p.path);
        } finally {
          if (existsSync(temp)) unlinkSync(temp);
        }
        return { path: p.path, bytes: bytes.length, manifest: bundle.manifest };
      }
      case 'packages.importPreview': {
        const bundle = this.readPackage(p.path),
          id = uuid();
        this.previews.set(id, { bundle, path: p.path, hash: hash(readFileSync(p.path)) });
        this.trimPreviews();
        return { previewId: id, ...this.composition(bundle), definition: bundle.definition };
      }
      case 'packages.updatePreview':
        return this.updatePreview(p);
      case 'packages.updateCommit':
        return this.updateCommit(p);
      case 'packages.importCommit': {
        const preview = this.previews.get(p.previewId);
        if (!preview) throw new Error('Предпросмотр истёк: откройте файл заново');
        if (!preview.staged && (!preview.path || hash(readFileSync(preview.path)) !== preview.hash))
          throw new Error('Файл изменился после проверки');
        const bundle = preview.staged ? preview.bundle : this.readPackage(preview.path!);
        const result = this.install(bundle);
        this.previews.delete(p.previewId);
        return result;
      }
      case 'apps.splitPreview':
        return this.splitPreview(p);
      case 'apps.mergePreview':
        return this.mergePreview(p);
      case 'apps.splitCommit':
      case 'apps.mergeCommit': {
        const preview = this.previews.get(p.previewId);
        if (!preview?.sources) throw new Error('Предпросмотр переноса не найден');
        for (const source of preview.sources) {
          const app = this.app(source.id);
          if (app.revision !== source.revision || app.version !== source.version)
            throw new Error('Исходные данные изменились: повторите предпросмотр');
        }
        const result = this.install(preview.bundle);
        this.previews.delete(p.previewId);
        return result;
      }
      default:
        throw new Error(`Неизвестная операция: ${method}`);
    }
  }
  private recordBatch(p: any) {
    if (!Array.isArray(p.operations) || !p.operations.length || p.operations.length > 1000)
      throw new Error('Транзакция должна содержать от 1 до 1000 операций');
    return this.transaction(() => {
      const app = this.app(p.appId),
        rows = this.rows(app.id),
        results: any[] = [];
      for (const operation of p.operations) {
        const e = this.entity(app.id, operation.entityId),
          id = operation.id || uuid();
        if (typeof id !== 'string' || id.length > 200)
          throw new Error('Неверный идентификатор записи');
        const index = rows.findIndex((r) => r.id === id);
        if (index >= 0 && rows[index].entityId !== e.id)
          throw new Error('Запись принадлежит другой сущности');
        if (operation.type === 'delete') {
          if (index < 0) throw new Error('Запись не найдена');
          rows.splice(index, 1);
          results.push({ id, deleted: true });
        } else if (operation.type === 'upsert') {
          const r = {
            id,
            appId: app.id,
            entityId: e.id,
            values: validateValues(e, operation.values),
            createdAt: index >= 0 ? rows[index].createdAt : now(),
            updatedAt: now(),
          };
          if (index >= 0) rows[index] = r;
          else rows.push(r);
          results.push(r);
        } else throw new Error('Неизвестная операция транзакции');
      }
      for (const r of rows) {
        const e = app.definition.entities.find((e) => e.id === r.entityId)!;
        this.checkRelations(app.id, e, r.values, rows);
        this.checkUnique(app.id, e, r.values, r.id, rows);
      }
      this.db.prepare('DELETE FROM records WHERE appId=?').run(app.id);
      for (const r of rows) this.insertRecord(r);
      this.bump(app.id);
      return { results, revision: this.app(app.id).revision };
    });
  }
  private insertRecord(r: DataRecord) {
    this.db
      .prepare('INSERT INTO records VALUES(?,?,?,?,?,?)')
      .run(r.id, r.appId, r.entityId, JSON.stringify(r.values), r.createdAt, r.updatedAt);
  }
  private collectAttachments() {
    const keep = new Set(
      (this.db.prepare('SELECT id FROM attachments').all() as any[]).map((a) => a.id),
    );
    for (const id of readdirSync(join(this.root, 'attachments')))
      if (/^[a-f0-9-]{36}$/.test(id) && !keep.has(id))
        unlinkSync(join(this.root, 'attachments', id));
  }
  private trimPreviews() {
    while (this.previews.size > 8) this.previews.delete(this.previews.keys().next().value!);
  }
  private composition(b: Bundle) {
    return {
      manifest: b.manifest,
      recordCount: b.records.length,
      demoRecordCount: b.demoRecords?.length || 0,
      attachments: b.attachments.map(({ id, name, size }) => ({ id, name, size })),
      documents: (b.documents || []).map(({ id, name, kind }) => ({ id, name, kind })),
      requiredPermissions: b.definition.permissions,
      warnings: [
        ...(b.manifest.externalConnections || []).map(
          (x: any) => `Переподключите: ${x.name || x.entityId || x.id}`,
        ),
        ...(b.definition.extensions.length
          ? [
              'Пакет содержит программируемый код. Хеш подтверждает целостность, а не доверие автору.',
            ]
          : []),
        'Разрешения и автоматизации потребуют настройки на принимающем устройстве.',
      ],
    };
  }
  private bundle(appId: string, p: any): Bundle {
    return this.transaction(() => {
      const app = this.app(appId),
        definition = structuredClone(app.definition);
      if (!['template', 'data'].includes(p.mode))
        throw new Error('Выберите режим шаблона или данных');
      this.checkPortable(definition);
      let records = p.mode === 'data' ? this.rows(appId) : [];
      if (p.entityIds) records = records.filter((r) => p.entityIds.includes(r.entityId));
      if (p.recordIds) records = records.filter((r) => p.recordIds.includes(r.id));
      const attachmentIds = new Set<string>();
      for (const r of records) {
        const entity = definition.entities.find((x) => x.id === r.entityId)!;
        for (const f of entity.fields) {
          if (
            f.type === 'relation' &&
            r.values[f.id] &&
            !records.some((x) => x.id === r.values[f.id])
          )
            throw new Error(`В выборку не включена связанная запись: ${entity.name}.${f.name}`);
          if (f.type === 'attachment' && r.values[f.id]) attachmentIds.add(String(r.values[f.id]));
        }
      }
      if (p.attachmentIds) for (const id of p.attachmentIds) attachmentIds.add(id);
      if (p.mode === 'template' && attachmentIds.size)
        throw new Error('Личные вложения нельзя включить в шаблон');
      const attachments: Attachment[] = [],
        files: Record<string, Uint8Array> = {};
      for (const id of attachmentIds) {
        const a: any = this.db
          .prepare('SELECT * FROM attachments WHERE appId=? AND id=?')
          .get(appId, id);
        if (!a) throw new Error('Выбранное вложение недоступно');
        attachments.push(a);
        files[`attachments/${id}`] = readFileSync(join(this.root, 'attachments', id));
      }
      const externalConnections = this.db
        .prepare('SELECT targetAppId,entityId FROM links WHERE sourceAppId=?')
        .all(appId)
        .map((x: any) => ({
          kind: 'application',
          entityId: x.entityId,
          name: this.app(x.targetAppId).name,
        }));
      const manifest = {
        format: 'everything-app',
        formatVersion: 1,
        apiVersion: 1,
        templateId: app.templateId,
        definitionVersion: app.version,
        name: app.name,
        description: app.description,
        icon: app.icon,
        mode: p.mode,
        createdAt: now(),
        externalConnections: [...externalConnections, ...(definition.connections || [])],
        dependencies: { platform: '1.0.0' },
        licenses: [{ name: 'User application', license: 'Author-defined; review with sender' }],
        hashes: {},
      };
      const stored: any = this.db.prepare('SELECT value FROM state WHERE key=?').get('documents');
      const allDocs = stored ? parse(stored.value) : [];
      const documents =
        p.mode === 'data' && Array.isArray(p.documentIds)
          ? allDocs
              .filter((d: any) => d.appId === appId && p.documentIds.includes(d.id))
              .map(({ id, name, kind, content, encoding, lineEnding }: any) => ({
                id,
                name,
                kind,
                content,
                encoding,
                lineEnding,
              }))
          : [];
      if (p.documentIds?.length && documents.length !== p.documentIds.length)
        throw new Error('Выбранные документы недоступны');
      const storedDemo: any = this.db
        .prepare('SELECT recordsJson FROM demo_data WHERE appId=?')
        .get(appId);
      const demoRecords =
        p.includeDemo && storedDemo
          ? this.validateDemo(definition, parse(storedDemo.recordsJson))
          : [];
      return { definition, records, attachments, files, manifest, documents, demoRecords };
    });
  }
  /** Snapshot the selected definition/data together before doing archive work elsewhere. */
  prepareExport(params: any): Bundle {
    return this.bundle(params.appId, params);
  }
  /** Only called by the trusted archive worker bridge; not an IPC method. */
  stageValidatedImport(bundle: Bundle) {
    const previewId = uuid();
    this.previews.set(previewId, { bundle, staged: true });
    this.trimPreviews();
    return { previewId, ...this.composition(bundle), definition: bundle.definition };
  }
  private validateDemo(definition: AppDefinition, input: unknown): DataRecord[] {
    if (!Array.isArray(input) || input.length > 1000)
      throw new Error('Демонстрационные данные: максимум 1000 записей');
    const ids = new Set<string>();
    const records = input.map((record: any) => {
      if (
        !record ||
        typeof record.id !== 'string' ||
        !/^[a-zA-Z][a-zA-Z0-9_-]{0,99}$/.test(record.id) ||
        ids.has(record.id)
      )
        throw new Error('Некорректный или повторный ID демонстрационной записи');
      ids.add(record.id);
      const entity = definition.entities.find((e) => e.id === record.entityId);
      if (!entity) throw new Error('Неизвестная сущность демонстрационной записи');
      const values = validateValues(entity, record.values);
      if (entity.fields.some((f) => f.type === 'attachment' && values[f.id]))
        throw new Error('Демонстрационные записи не могут ссылаться на личные вложения');
      return {
        id: record.id,
        entityId: entity.id,
        appId: '',
        values,
        createdAt: '2000-01-01T00:00:00.000Z',
        updatedAt: '2000-01-01T00:00:00.000Z',
      };
    });
    for (const record of records) {
      const entity = definition.entities.find((e) => e.id === record.entityId)!;
      this.checkRelations('', entity, record.values, records);
      this.checkUnique('', entity, record.values, record.id, records);
    }
    if (Buffer.byteLength(JSON.stringify(records)) > 1024 * 1024)
      throw new Error('Демонстрационные данные превышают 1 МБ');
    return records;
  }
  private checkPortable(value: unknown, key = '') {
    if (Array.isArray(value)) {
      for (const v of value) this.checkPortable(v, key);
      return;
    }
    if (value && typeof value === 'object') {
      for (const [k, v] of Object.entries(value)) this.checkPortable(v, k);
      return;
    }
    if (typeof value === 'string') {
      if (/^(apiKey|api_key|password|secret|accessToken|refreshToken)$/i.test(key) && value)
        throw new Error(
          'Удалите секрет из определения перед экспортом; используйте защищённое подключение',
        );
      if (
        /^(path|filePath|directory|folder|url)$/i.test(key) &&
        /^(\/|[A-Za-z]:\\|file:\/\/)/.test(value)
      )
        throw new Error(
          'Абсолютный путь не переносим. Используйте управляемое вложение или подключение',
        );
    }
  }
  packageFiles(b: Bundle) {
    const files: Record<string, Uint8Array> = {
      ...b.files,
      'documents.json': strToU8(JSON.stringify(b.documents || [])),
      'demo-data.json': strToU8(JSON.stringify(b.demoRecords || [])),
      'definition.json': strToU8(JSON.stringify(b.definition)),
      'data.json': strToU8(
        JSON.stringify(
          b.records.map(({ id, entityId, values, createdAt, updatedAt }) => ({
            id,
            entityId,
            values,
            createdAt,
            updatedAt,
          })),
        ),
      ),
      'attachments.json': strToU8(JSON.stringify(b.attachments.map(({ appId, ...a }) => a))),
    };
    let size = 0;
    for (const bytes of Object.values(files)) size += bytes.length;
    if (size > MAX_EXPANDED) throw new Error('Распакованный пакет превышает 128 МБ');
    b.manifest.hashes = Object.fromEntries(
      Object.entries(files).map(([name, bytes]) => [name, hash(bytes)]),
    );
    return { ...files, 'manifest.json': strToU8(JSON.stringify(b.manifest)) };
  }
  readPackage(path: string, onProgress?: (completed: number, total: number) => void): Bundle {
    if (typeof path !== 'string' || statSync(path).size > MAX_PACKAGE)
      throw new Error('Пакет не выбран или превышает 64 МБ');
    const bytes = readFileSync(path);
    let files: Record<string, Uint8Array>;
    try {
      files = boundedUnzip(bytes, MAX_EXPANDED, onProgress);
    } catch (e) {
      throw new Error('Небезопасный или повреждённый архив: ' + (e as Error).message);
    }
    let manifest: any,
      definition: AppDefinition,
      records: DataRecord[],
      attachments: Attachment[],
      documents: any[] = [];
    try {
      manifest = parse(strFromU8(files['manifest.json']));
      if (
        manifest.format !== 'everything-app' ||
        manifest.formatVersion !== 1 ||
        manifest.apiVersion !== 1 ||
        typeof manifest.templateId !== 'string' ||
        !Number.isInteger(manifest.definitionVersion) ||
        !['template', 'data'].includes(manifest.mode)
      )
        throw new Error('Несовместимый manifest');
      if (
        manifest.externalConnections !== undefined &&
        (!Array.isArray(manifest.externalConnections) ||
          manifest.externalConnections.length > 100 ||
          manifest.externalConnections.some(
            (connection: any) =>
              !connection ||
              typeof connection !== 'object' ||
              Array.isArray(connection) ||
              Object.entries(connection).some(
                ([key, value]) =>
                  !['id', 'name', 'kind', 'entityId'].includes(key) ||
                  typeof value !== 'string' ||
                  value.length > 1000,
              ),
          ))
      )
        throw new Error('Некорректные внешние подключения');
      if (!manifest.hashes || typeof manifest.hashes !== 'object')
        throw new Error('Отсутствуют хеши');
      for (const [name, data] of Object.entries(files))
        if (name !== 'manifest.json' && manifest.hashes[name] !== hash(data))
          throw new Error(`Не совпал хеш ${name}`);
      for (const name of Object.keys(manifest.hashes))
        if (!files[name] || name === 'manifest.json')
          throw new Error('Manifest ссылается на отсутствующий файл');
      if (manifest.dependencies?.platform !== '1.0.0')
        throw new Error('Неподдерживаемая версия платформы');
      definition = validateDefinition(parse(strFromU8(files['definition.json'])));
      this.checkPortable(definition);
      records = parse(strFromU8(files['data.json']));
      attachments = parse(strFromU8(files['attachments.json']));
      if (
        !Array.isArray(records) ||
        records.length > 100000 ||
        !Array.isArray(attachments) ||
        attachments.length > 997
      )
        throw new Error('Превышены ограничения данных');
      documents = files['documents.json'] ? parse(strFromU8(files['documents.json'])) : [];
      if (
        !Array.isArray(documents) ||
        documents.length > 1000 ||
        new Set(documents.map((d) => d.id)).size !== documents.length
      )
        throw new Error('Неверный список документов');
      for (const d of documents)
        if (
          typeof d.id !== 'string' ||
          typeof d.name !== 'string' ||
          typeof d.content !== 'string' ||
          !['text', 'image', 'binary'].includes(d.kind) ||
          Object.keys(d).some(
            (k) => !['id', 'name', 'kind', 'content', 'encoding', 'lineEnding'].includes(k),
          )
        )
          throw new Error('Некорректный документ');
      if (
        manifest.mode === 'template' &&
        (records.length || attachments.length || documents.length)
      )
        throw new Error('Шаблон содержит личные данные');
      const recordIds = new Set<string>(),
        attachmentIds = new Set<string>();
      for (const a of attachments) {
        if (
          typeof a.id !== 'string' ||
          !/^[a-zA-Z0-9-]+$/.test(a.id) ||
          attachmentIds.has(a.id) ||
          typeof a.name !== 'string' ||
          a.name !== basename(a.name) ||
          a.name.length > 255
        )
          throw new Error('Некорректное вложение');
        attachmentIds.add(a.id);
        const content = files[`attachments/${a.id}`];
        if (!content || content.length !== a.size || hash(content) !== a.sha256)
          throw new Error('Повреждено вложение');
      }
      for (const name of Object.keys(files))
        if (name.startsWith('attachments/') && !attachmentIds.has(name.slice(12)))
          throw new Error('Вложение не описано в метаданных');
      for (const r of records) {
        if (
          typeof r.id !== 'string' ||
          r.id.length > 200 ||
          recordIds.has(r.id) ||
          typeof r.createdAt !== 'string' ||
          typeof r.updatedAt !== 'string'
        )
          throw new Error('Некорректный идентификатор записи');
        recordIds.add(r.id);
        const e = definition.entities.find((x) => x.id === r.entityId);
        if (!e) throw new Error('Данные неизвестной сущности');
        r.values = validateValues(e, r.values);
        this.checkUnique('', e, r.values, r.id, records);
        for (const f of e.fields) {
          if (
            f.type === 'relation' &&
            r.values[f.id] &&
            !records.some((x) => x.id === r.values[f.id] && x.entityId === f.targetEntity)
          )
            throw new Error('Неразрешённая ссылка в пакете');
          if (
            f.type === 'attachment' &&
            r.values[f.id] &&
            !attachmentIds.has(String(r.values[f.id]))
          )
            throw new Error('Отсутствует вложение записи');
        }
      }
    } catch (e) {
      throw new Error('Проверка пакета не пройдена: ' + (e as Error).message);
    }
    const demoRecords = this.validateDemo(
      definition,
      files['demo-data.json'] ? parse(strFromU8(files['demo-data.json'])) : [],
    );
    return { manifest, definition, records, attachments, files, documents, demoRecords };
  }
  private install(b: Bundle) {
    const written: string[] = [];
    try {
      return this.transaction(() => {
        const d = structuredClone(b.definition);
        d.automations = d.automations.map((a) => ({ ...a, enabled: false }));
        const installRecords = b.manifest.mode === 'template' ? b.demoRecords || [] : b.records;
        const app = this.create({
            definition: d,
            name: b.manifest.name || d.name,
            description: b.manifest.description || d.description,
            icon: b.manifest.icon || d.icon,
            templateId: b.manifest.templateId,
            sourceVersion: b.manifest.definitionVersion,
          }),
          ids = new Map(installRecords.map((r) => [r.id, uuid()])),
          attachmentIds = new Map(b.attachments.map((a) => [a.id, uuid()]));
        for (const a of b.attachments) {
          const id = attachmentIds.get(a.id)!;
          const file = join(this.root, 'attachments', id);
          writeFileSync(file, b.files[`attachments/${a.id}`], { flag: 'wx' });
          written.push(file);
          this.db
            .prepare('INSERT INTO attachments VALUES(?,?,?,?,?,?)')
            .run(id, app.id, a.name, a.size, a.sha256, now());
        }
        for (const record of installRecords) {
          const r = structuredClone(record);
          r.id = ids.get(record.id)!;
          r.appId = app.id;
          const e = d.entities.find((x) => x.id === r.entityId)!;
          for (const f of e.fields) {
            if (f.type === 'relation' && r.values[f.id])
              r.values[f.id] = ids.get(String(r.values[f.id]));
            if (f.type === 'attachment' && r.values[f.id])
              r.values[f.id] = attachmentIds.get(String(r.values[f.id]));
          }
          this.insertRecord(r);
        }
        if (b.documents?.length) {
          const stored: any = this.db
            .prepare('SELECT value FROM state WHERE key=?')
            .get('documents');
          const docs = stored ? parse(stored.value) : [];
          for (const d of b.documents)
            docs.push({
              ...d,
              id: uuid(),
              appId: app.id,
              dirty: true,
              revision: 1,
              external: false,
              updatedAt: now(),
              history: [],
            });
          this.db
            .prepare(
              'INSERT INTO state VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
            )
            .run('documents', JSON.stringify(docs));
        }
        if (b.demoRecords?.length)
          this.db
            .prepare('INSERT INTO demo_data VALUES(?,?)')
            .run(app.id, JSON.stringify(b.demoRecords));
        this.bump(app.id);
        return {
          app: this.app(app.id),
          report: {
            records: installRecords.length,
            demoRecords: b.demoRecords?.length || 0,
            requiredPermissions: d.permissions,
            attachments: b.attachments.length,
            documents: b.documents?.length || 0,
            permissionsGranted: 0,
            automationsEnabled: 0,
            reconnect: b.manifest.externalConnections || [],
            message:
              'Создан независимый экземпляр. Настройте подключения и разрешения перед включением автоматизаций.',
          },
        };
      });
    } catch (e) {
      for (const file of written) if (existsSync(file)) unlinkSync(file);
      throw e;
    }
  }
  stageValidatedUpdate(appId: string, bundle: Bundle) {
    return this.updatePreview({ appId }, bundle);
  }
  private updatePreview(p: any, stagedBundle?: Bundle) {
    const app = this.app(p.appId),
      bundle = stagedBundle || this.readPackage(p.path);
    if (bundle.manifest.templateId !== app.templateId)
      throw new Error('Пакет принадлежит другому шаблону');
    const origin: any = this.db.prepare('SELECT * FROM origins WHERE appId=?').get(app.id);
    if (!origin)
      throw new Error('Исходная версия неизвестна: используйте импорт независимой копии');
    if (bundle.manifest.definitionVersion <= origin.sourceVersion)
      throw new Error('Выберите более новую версию исходного шаблона');
    const conflicts: string[] = [];
    const equal = (a: any, b: any) => JSON.stringify(a) === JSON.stringify(b);
    const merge = (base: any, local: any, remote: any, path: string): any => {
      if (equal(local, base)) return remote;
      if (equal(remote, base) || equal(local, remote)) return local;
      if (
        [base, local, remote].every(
          (x) =>
            Array.isArray(x) &&
            x.every((i: any) => i && typeof i === 'object' && typeof i.id === 'string'),
        )
      ) {
        const keys = new Set([...base, ...local, ...remote].map((x: any) => x.id));
        return [...keys]
          .map((id) =>
            merge(
              base.find((x: any) => x.id === id),
              local.find((x: any) => x.id === id),
              remote.find((x: any) => x.id === id),
              path + '.' + id,
            ),
          )
          .filter((v) => v !== undefined);
      }
      if ([base, local, remote].every((x) => x && typeof x === 'object' && !Array.isArray(x))) {
        const keys = new Set([...Object.keys(base), ...Object.keys(local), ...Object.keys(remote)]);
        return Object.fromEntries(
          [...keys]
            .map((key) => [key, merge(base[key], local[key], remote[key], path + '.' + key)])
            .filter(([, v]) => v !== undefined),
        );
      }
      conflicts.push(path);
      return local;
    };
    const merged = merge(parse(origin.definition), app.definition, bundle.definition, 'definition');
    if (conflicts.length)
      throw new Error('Конфликт исходных и персональных изменений: ' + conflicts.join(', '));
    const definition = validateDefinition(merged);
    this.validateMigration(app, definition);
    const previewId = uuid();
    this.previews.set(previewId, {
      bundle,
      path: p.path,
      hash: stagedBundle ? undefined : hash(readFileSync(p.path)),
      staged: !!stagedBundle,
      update: { appId: app.id, version: app.version, revision: app.revision, definition },
    });
    this.trimPreviews();
    return {
      previewId,
      definition,
      manifest: bundle.manifest,
      requiredPermissions: definition.permissions,
      recordCount: this.rows(app.id).length,
      warnings: [
        'Личные данные сохраняются. Данные и документы из обновления не заменяют ваши записи. Автоматизации будут выключены до проверки.',
      ],
    };
  }
  private updateCommit(p: any) {
    const preview = this.previews.get(p.previewId);
    if (!preview?.update || (!preview.staged && !preview.path))
      throw new Error('Предпросмотр обновления не найден');
    if (!preview.staged && hash(readFileSync(preview.path!)) !== preview.hash)
      throw new Error('Файл изменился после проверки');
    const result = this.transaction(() => {
      const update = preview.update!,
        app = this.app(update.appId);
      if (app.version !== update.version || app.revision !== update.revision)
        throw new Error('Данные изменились: повторите предпросмотр обновления');
      const d = structuredClone(update.definition);
      d.automations = d.automations.map((a) => ({ ...a, enabled: false }));
      this.validateMigration(app, d);
      this.snapshot(app.id, 'Перед обновлением из пакета');
      for (const r of this.rows(app.id)) {
        const e = d.entities.find((x) => x.id === r.entityId)!;
        this.db
          .prepare('UPDATE records SET valuesJson=? WHERE appId=? AND id=?')
          .run(JSON.stringify(validateValues(e, r.values)), app.id, r.id);
      }
      this.db
        .prepare(
          'UPDATE apps SET definition=?,version=version+1,revision=revision+1,sourceVersion=?,status=?,updatedAt=? WHERE id=?',
        )
        .run(
          JSON.stringify(d),
          preview.bundle.manifest.definitionVersion,
          'stopped',
          now(),
          app.id,
        );
      this.db
        .prepare('INSERT INTO definitions VALUES(?,?,?,?)')
        .run(app.id, app.version + 1, JSON.stringify(d), now());
      this.db
        .prepare('UPDATE origins SET definition=?,sourceVersion=? WHERE appId=?')
        .run(
          JSON.stringify(preview.bundle.definition),
          preview.bundle.manifest.definitionVersion,
          app.id,
        );
      this.prunePermissions(app.id, d);
      return {
        app: this.app(app.id),
        report: {
          recordsPreserved: this.rows(app.id).length,
          reconnect: preview.bundle.manifest.externalConnections || [],
          requiredPermissions: d.permissions,
          sourceVersion: preview.bundle.manifest.definitionVersion,
          automationsEnabled: 0,
        },
      };
    });
    this.previews.delete(p.previewId);
    return result;
  }
  private splitPreview(p: any) {
    const app = this.app(p.appId);
    if (app.definition.extensions.length)
      throw new Error(
        'Выделение приложения с программируемым кодом требует явной адаптации кода; автоматический перенос запрещён',
      );
    if (!Array.isArray(p.entityIds) || !p.entityIds.length) throw new Error('Выберите сущности');
    const bundle = this.bundle(app.id, { mode: 'data', entityIds: p.entityIds });
    bundle.definition.entities = bundle.definition.entities.filter((e) =>
      p.entityIds.includes(e.id),
    );
    bundle.definition.screens = bundle.definition.screens.filter(
      (s) => !s.entityId || p.entityIds.includes(s.entityId),
    );
    for (const action of bundle.definition.actions) {
      if (action.config?.entityId && !p.entityIds.includes(action.config.entityId))
        throw new Error('Действие использует сущность вне выборки: ' + action.name);
    }
    bundle.definition.name = p.name || app.name + ' — часть';
    bundle.manifest.name = bundle.definition.name;
    bundle.definition = validateDefinition(bundle.definition);
    bundle.manifest.templateId = uuid();
    const id = uuid();
    this.previews.set(id, {
      bundle,
      sources: [{ id: app.id, revision: app.revision, version: app.version }],
    });
    this.trimPreviews();
    return {
      previewId: id,
      definition: bundle.definition,
      recordCount: bundle.records.length,
      warnings: ['Создаётся независимая копия выбранных сущностей. Исходные данные сохраняются.'],
    };
  }
  private mergePreview(p: any) {
    if (
      !Array.isArray(p.appIds) ||
      p.appIds.length < 2 ||
      p.appIds.length > 10 ||
      new Set(p.appIds).size !== p.appIds.length
    )
      throw new Error('Выберите от 2 до 10 разных приложений');
    const apps = p.appIds.map((id: string) => this.app(id)),
      bundles = apps.map((a: AppInstance) => this.bundle(a.id, { mode: 'data' }));
    const result: Bundle = {
      definition: emptyDefinition(p.name || 'Объединённое приложение'),
      records: [],
      attachments: [],
      files: {},
      manifest: {
        ...bundles[0].manifest,
        templateId: uuid(),
        externalConnections: bundles.flatMap((b: Bundle) => b.manifest.externalConnections),
      },
    };
    bundles.forEach((b: Bundle, index: number) => {
      const prefix = `a${index + 1}_`,
        d = b.definition;
      if (d.extensions.length)
        throw new Error(
          'Объединение приложения с программируемым кодом требует явной адаптации кода; автоматический перенос запрещён',
        );
      const remap = (v: any): any =>
        Array.isArray(v)
          ? v.map(remap)
          : v && typeof v === 'object'
            ? Object.fromEntries(
                Object.entries(v).map(([k, x]) => [
                  k,
                  [
                    'entityId',
                    'actionId',
                    'screenId',
                    'extensionId',
                    'automationId',
                    'targetEntity',
                  ].includes(k) && typeof x === 'string'
                    ? prefix + x
                    : remap(x),
                ]),
              )
            : v;
      for (const action of d.actions) if (action.config) action.config = remap(action.config);
      for (const screen of d.screens) if (screen.config) screen.config = remap(screen.config);
      for (const automation of d.automations)
        if (automation.config) automation.config = remap(automation.config);
      for (const e of d.entities) {
        e.id = prefix + e.id;
        for (const f of e.fields) if (f.targetEntity) f.targetEntity = prefix + f.targetEntity;
      }
      for (const s of d.screens) {
        s.id = prefix + s.id;
        if (s.entityId) s.entityId = prefix + s.entityId;
      }
      for (const a of d.actions) a.id = prefix + a.id;
      for (const a of d.automations) {
        a.id = prefix + a.id;
        a.actionId = prefix + a.actionId;
      }
      for (const e of d.extensions) e.id = prefix + e.id;
      const rowIds = new Map(b.records.map((r) => [r.id, prefix + r.id]));
      for (const r of b.records) {
        r.id = prefix + r.id;
        r.entityId = prefix + r.entityId;
        const e = d.entities.find((e) => e.id === r.entityId)!;
        for (const f of e.fields)
          if (f.type === 'relation' && r.values[f.id])
            r.values[f.id] = rowIds.get(String(r.values[f.id]));
      }
      result.definition.entities.push(...d.entities);
      result.definition.screens.push(...d.screens);
      result.definition.actions.push(...d.actions);
      result.definition.automations.push(...d.automations);
      result.definition.extensions.push(...d.extensions);
      result.definition.permissions.push(...d.permissions);
      result.records.push(...b.records);
      result.attachments.push(...b.attachments);
      Object.assign(result.files, b.files);
    });
    result.manifest.name = result.definition.name;
    result.definition.permissions = [...new Set(result.definition.permissions)];
    result.definition = validateDefinition(result.definition);
    const previewId = uuid();
    this.previews.set(previewId, {
      bundle: result,
      sources: apps.map((a: AppInstance) => ({
        id: a.id,
        version: a.version,
        revision: a.revision,
      })),
    });
    this.trimPreviews();
    return {
      previewId,
      definition: result.definition,
      recordCount: result.records.length,
      warnings: [
        'Идентификаторы сущностей и экранов получили префиксы a1_, a2_. Проверьте ссылки в программируемом коде и конфигурации действий перед запуском.',
        'Исходные приложения сохраняются.',
      ],
    };
  }
}
