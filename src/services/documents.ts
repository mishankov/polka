import { randomUUID, createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import iconv from 'iconv-lite';
type Revision = string | Pick<Document, 'content' | 'kind' | 'encoding' | 'lineEnding'>;
const snapshot = (d: Document): Revision => ({
  content: d.content,
  kind: d.kind,
  encoding: d.encoding,
  lineEnding: d.lineEnding,
});
function restore(d: Document, revision: Revision) {
  if (typeof revision === 'string') d.content = revision;
  else Object.assign(d, revision);
}
interface Store {
  handle(method: string, params?: any): Promise<any>;
}
export interface Document {
  id: string;
  appId: string;
  name: string;
  kind: 'text' | 'image' | 'binary';
  content: string;
  dirty: boolean;
  revision: number;
  encoding: string;
  lineEnding: string;
  external: boolean;
  updatedAt: string;
  path?: string;
  diskHash?: string;
  history?: Revision[];
  future?: Revision[];
}
const hash = (b: Buffer) => createHash('sha256').update(b).digest('hex');
export class DocumentService {
  constructor(private store: Store) {}
  private async all(): Promise<Document[]> {
    return (await this.store.handle('state.get', { key: 'documents' })) || [];
  }
  private async write(docs: Document[]) {
    await this.store.handle('state.set', { key: 'documents', value: docs });
  }
  private public(d: Document) {
    const { path, diskHash, history, future, ...safe } = d;
    return safe;
  }
  async handle(method: string, p: any): Promise<any> {
    const docs = await this.all();
    const d = docs.find((d) => d.id === p.id && d.appId === p.appId);
    if (method === 'docs.list')
      return docs.filter((d) => d.appId === p.appId).map((d) => this.public(d));
    if (method === 'docs.applyBatch') {
      if (!Array.isArray(p.changes) || !p.changes.length || p.changes.length > 256)
        throw Error('Выберите от 1 до 256 документов');
      const ids = new Set<string>();
      const changes = p.changes.map((change: any) => {
        const doc = docs.find((x) => x.id === change.id && x.appId === p.appId);
        if (!doc || ids.has(doc.id)) throw Error('Документ не найден или выбран дважды');
        ids.add(doc.id);
        if (doc.revision !== change.revision)
          throw Error(
            `${doc.name}: документ изменился после предпросмотра. Повторите преобразование.`,
          );
        if (typeof change.content !== 'string' || change.content.length > 44 * 1024 * 1024)
          throw Error('Результат превышает лимит документа');
        if (!['text', 'binary', 'image'].includes(change.kind || doc.kind))
          throw Error('Неизвестный тип документа');
        if (
          (change.kind || doc.kind) === 'image' &&
          !change.content.startsWith('data:image/png;base64,')
        )
          throw Error('Результат изображения должен быть PNG');
        return { doc, change };
      });
      for (const { doc, change } of changes) {
        doc.history = [...(doc.history || []), snapshot(doc)].slice(-10);
        doc.future = [];
        doc.content = change.content;
        doc.kind = change.kind || doc.kind;
        if (doc.kind === 'text') doc.lineEnding = doc.content.includes('\r\n') ? 'CRLF' : 'LF';
        doc.dirty = true;
        doc.revision++;
        doc.updatedAt = new Date().toISOString();
      }
      await this.write(docs);
      return changes.map(({ doc }: { doc: Document }) => this.public(doc));
    }
    if (method === 'docs.create' || method === 'docs.openPath') {
      await this.store.handle('apps.get', { appId: p.appId });
      let content = p.content || '',
        kind = p.kind || 'text',
        encoding = p.encoding || 'utf8',
        diskHash: string | undefined;
      if (typeof content !== 'string' || content.length > 44 * 1024 * 1024)
        throw Error('Документ превышает лимит');
      if (!['text', 'binary', 'image'].includes(kind)) throw Error('Неизвестный тип документа');
      if (!iconv.encodingExists(encoding)) throw Error('Неизвестная кодировка');
      if (p.path) {
        const existing = docs.find((x) => x.appId === p.appId && x.path === p.path);
        if (existing) return this.public(existing);
        const stat = await fs.stat(p.path);
        if (!stat.isFile() || stat.size > 32 * 1024 * 1024)
          throw Error('Файл должен быть не больше 32 МБ');
        const bytes = await fs.readFile(p.path);
        diskHash = hash(bytes);
        if (!p.encoding) {
          if (bytes[0] === 0xff && bytes[1] === 0xfe) encoding = 'utf16-le';
          else if (bytes[0] === 0xfe && bytes[1] === 0xff) encoding = 'utf16-be';
          else if (bytes.subarray(0, 8192).includes(0)) kind = 'binary';
        }
        if (/\.(png|jpe?g|webp|gif)$/i.test(p.path)) {
          kind = 'image';
          content = `data:image/${/\.jpe?g$/i.test(p.path) ? 'jpeg' : p.path.split('.').pop()};base64,${bytes.toString('base64')}`;
        } else if (kind === 'binary') content = bytes.toString('base64');
        else content = iconv.decode(bytes, encoding);
      }
      const next: Document = {
        id: randomUUID(),
        appId: p.appId,
        name: p.path ? basename(p.path) : p.name || 'Без названия',
        kind,
        content,
        dirty: !p.path,
        revision: 1,
        encoding,
        lineEnding: content.includes('\r\n') ? 'CRLF' : 'LF',
        external: !!p.path,
        path: p.path,
        diskHash,
        updatedAt: new Date().toISOString(),
        history: [],
      };
      docs.push(next);
      await this.write(docs);
      return this.public(next);
    }
    if (!d) throw Error('Документ не найден');
    if (method === 'docs.get') return this.public(d);
    if (method === 'docs.close') {
      if (d.dirty && !p.discard)
        throw Error('Сначала сохраните документ или подтвердите закрытие без сохранения');
      await this.write(docs.filter((x) => x.id !== d.id));
      return { closed: true };
    }
    if (method === 'docs.draft') {
      if (p.revision !== undefined && p.revision !== d.revision)
        throw Error('Документ изменён в другом окне; откройте актуальную версию');
      if (typeof p.content !== 'string' || p.content.length > 44 * 1024 * 1024)
        throw Error('Документ превышает лимит');
      if (p.encoding && !iconv.encodingExists(p.encoding)) throw Error('Неизвестная кодировка');
      if (p.lineEnding && !['LF', 'CRLF'].includes(p.lineEnding))
        throw Error('Неизвестное окончание строки');
      d.history = [...(d.history || []), snapshot(d)].slice(-10);
      d.future = [];
      d.content = p.content;
      d.dirty = true;
      d.revision++;
      if (p.encoding) {
        if (!iconv.encodingExists(p.encoding)) throw Error('Неизвестная кодировка');
        d.encoding = p.encoding;
      }
      if (p.lineEnding) d.lineEnding = p.lineEnding;
    } else if (method === 'docs.revert') {
      if (!d.history?.length) throw Error('Нет сохранённой истории');
      d.future = [...(d.future || []), snapshot(d)].slice(-10);
      restore(d, d.history.pop()!);
      d.dirty = true;
      d.revision++;
    } else if (method === 'docs.redo') {
      if (!d.future?.length) throw Error('Нет правки для повтора');
      d.history = [...(d.history || []), snapshot(d)].slice(-10);
      restore(d, d.future.pop()!);
      d.dirty = true;
      d.revision++;
    } else if (method === 'docs.savePath') {
      const path = p.path || d.path;
      if (!path) throw Error('Выберите место сохранения');
      if (path === d.path) {
        const current = await fs.readFile(path).catch((e) => {
          if (e.code === 'ENOENT') return null;
          throw e;
        });
        if ((current ? hash(current) : undefined) !== d.diskHash && !p.force)
          throw Error(
            'Файл изменён другим приложением. Сохраните копию или явно подтвердите замену.',
          );
      }
      if (d.kind === 'image') {
        const mime = d.content.match(/^data:image\/(png|jpeg|gif|webp);base64,/i)?.[1];
        const ext = path.split('.').pop()?.toLowerCase();
        if (mime && !(mime === 'jpeg' ? ['jpg', 'jpeg'].includes(ext || '') : ext === mime))
          throw Error(
            `Изображение закодировано как ${mime.toUpperCase()}. Сохраните копию с расширением .${mime === 'jpeg' ? 'jpg' : mime}`,
          );
      }
      const bytes =
        d.kind === 'text'
          ? iconv.encode(
              d.content.replace(/\r\n|\r|\n/g, d.lineEnding === 'CRLF' ? '\r\n' : '\n'),
              d.encoding,
            )
          : Buffer.from(d.content.replace(/^data:[^;]+;base64,/, ''), 'base64');
      const temp = join(dirname(path), `.everything-${randomUUID()}.tmp`);
      try {
        const handle = await fs.open(temp, 'wx', 0o600);
        try {
          await handle.writeFile(bytes);
          await handle.sync();
        } finally {
          await handle.close();
        }
        await fs.rename(temp, path);
      } finally {
        await fs.unlink(temp).catch(() => {});
      }
      d.path = path;
      d.diskHash = hash(bytes);
      d.dirty = false;
      d.external = true;
      d.name = basename(path);
      d.revision++;
    } else if (method === 'docs.path') return d.path || null;
    else throw Error('Неизвестная операция документа');
    d.updatedAt = new Date().toISOString();
    await this.write(docs);
    return this.public(d);
  }
}
