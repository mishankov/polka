import { randomUUID } from 'node:crypto';
import { z } from 'zod';
interface Metadata {
  origin: string;
  configured: true;
  secretId?: string;
}
interface Storage {
  getMetadata: (key: string) => Promise<Metadata | null>;
  setMetadata: (key: string, value: Metadata | null) => Promise<unknown>;
  readSecret: (id: string) => Promise<string | null>;
  writeSecret: (id: string, value: string) => Promise<unknown>;
  removeSecret: (id: string) => Promise<unknown>;
}
/** Immutable credential versions keep origin validation and secret reads consistent during rotation. */
export class ConnectionCredentials {
  private mutations = new Map<string, Promise<unknown>>();
  constructor(private storage: Storage) {}
  private key(appId: string, connectionId: string) {
    return `connection:${appId}:${connectionId}`;
  }
  private secretId(key: string, metadata: Metadata) {
    // Earlier installations used an unversioned key. New saves never overwrite that key.
    if (!metadata.secretId) return key;
    if (
      !metadata.secretId.startsWith(key + ':') ||
      !/^[0-9a-f-]{36}$/.test(metadata.secretId.slice(key.length + 1))
    )
      throw Error('Неверная ссылка на ключ подключения');
    return metadata.secretId;
  }
  private mutate<T>(key: string, action: () => Promise<T>): Promise<T> {
    const pending = (this.mutations.get(key) || Promise.resolve()).catch(() => {}).then(action);
    this.mutations.set(key, pending);
    void pending
      .finally(() => {
        if (this.mutations.get(key) === pending) this.mutations.delete(key);
      })
      .catch(() => {});
    return pending;
  }
  async read(appId: string, connectionId: string, origin: string) {
    const key = this.key(appId, connectionId),
      meta = await this.storage.getMetadata(key);
    if (!meta?.configured || meta.origin !== origin)
      throw Error('Настройте подключение для этого адреса');
    const bearer = await this.storage.readSecret(this.secretId(key, meta));
    if (!bearer) throw Error('Ключ подключения не задан');
    return { bearer };
  }
  save(appId: string, connectionId: string, origin: unknown, token: unknown) {
    const key = this.key(appId, connectionId);
    const url = new URL(z.string().max(4096).parse(origin));
    if (
      url.protocol !== 'https:' ||
      url.username ||
      url.password ||
      url.pathname !== '/' ||
      url.search ||
      url.hash
    )
      throw Error('Укажите HTTPS origin без пути, параметров или пароля');
    const secret = z
      .string()
      .max(16000)
      .parse(token || '');
    return this.mutate(key, async () => {
      const previous = await this.storage.getMetadata(key);
      if (!secret && (!previous?.configured || previous.origin !== url.origin))
        throw Error('Введите ключ для нового адреса');
      // Even migration with an unchanged token gets a new immutable version.
      const value =
        secret || (previous && (await this.storage.readSecret(this.secretId(key, previous))));
      if (!value) throw Error('Ключ подключения не задан');
      const secretId = `${key}:${randomUUID()}`;
      await this.storage.writeSecret(secretId, value);
      try {
        await this.storage.setMetadata(key, { origin: url.origin, configured: true, secretId });
      } catch (error) {
        await this.storage.removeSecret(secretId).catch(() => {});
        throw error;
      }
      if (previous) await this.storage.removeSecret(this.secretId(key, previous)).catch(() => {});
      return true;
    });
  }
  remove(appId: string, connectionId: string) {
    const key = this.key(appId, connectionId);
    return this.mutate(key, async () => {
      const previous = await this.storage.getMetadata(key);
      // Unpublish first; subsequent readers cannot acquire this connection.
      await this.storage.setMetadata(key, null);
      if (previous) await this.storage.removeSecret(this.secretId(key, previous));
      return true;
    });
  }
}
