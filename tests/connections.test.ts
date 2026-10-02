import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ConnectionCredentials } from '../src/main/connections';
function store() {
  const metadata = new Map<string, any>(),
    secrets = new Map<string, string>();
  const storage = {
    getMetadata: async (key: string) => metadata.get(key) || null,
    setMetadata: async (key: string, value: any) => {
      metadata.set(key, value);
    },
    readSecret: async (id: string) => secrets.get(id) || null,
    writeSecret: async (id: string, value: string) => {
      secrets.set(id, value);
    },
    removeSecret: async (id: string) => {
      secrets.delete(id);
    },
  };
  return { metadata, secrets, storage };
}
test('credential rotation cannot send a new-origin token to an old-origin request', async () => {
  const { metadata, secrets, storage } = store();
  const key = 'connection:app:service';
  metadata.set(key, { origin: 'https://old.example', configured: true });
  secrets.set(key, 'old-token');
  let entered!: () => void, release!: () => void;
  const started = new Promise<void>((resolve) => {
    entered = resolve;
  });
  const resumed = new Promise<void>((resolve) => {
    release = resolve;
  });
  const read = storage.readSecret;
  storage.readSecret = async (id) => {
    if (id === key) {
      entered();
      await resumed;
    }
    return read(id);
  };
  const credentials = new ConnectionCredentials(storage);
  const oldRequest = credentials.read('app', 'service', 'https://old.example').then(
    (value) => value.bearer,
    () => null,
  );
  await started;
  await credentials.save('app', 'service', 'https://new.example', 'new-token');
  release();
  assert.notEqual(await oldRequest, 'new-token');
  assert.equal(
    (await credentials.read('app', 'service', 'https://new.example')).bearer,
    'new-token',
  );
  await assert.rejects(credentials.read('app', 'service', 'https://old.example'), /адреса/);
  assert.notEqual(metadata.get(key).secretId, key);
  assert(!secrets.has(key));
});
test('unchanged legacy connection migrates, empty key cannot change origin, removal deletes referenced version', async () => {
  const { metadata, secrets, storage } = store();
  const key = 'connection:app:service';
  metadata.set(key, { origin: 'https://api.example', configured: true });
  secrets.set(key, 'legacy');
  const credentials = new ConnectionCredentials(storage);
  await credentials.save('app', 'service', 'https://api.example', '');
  const version = metadata.get(key).secretId;
  assert.equal(secrets.get(version), 'legacy');
  assert(!secrets.has(key));
  await assert.rejects(
    credentials.save('app', 'service', 'https://other.example', ''),
    /Введите ключ/,
  );
  await credentials.remove('app', 'service');
  assert.equal(metadata.get(key), null);
  assert(!secrets.has(version));
  await assert.rejects(credentials.read('app', 'service', 'https://api.example'), /адреса/);
});
test('failed metadata swap leaves old credentials and removes unpublished version', async () => {
  const { metadata, secrets, storage } = store();
  const key = 'connection:app:service';
  metadata.set(key, { origin: 'https://old.example', configured: true });
  secrets.set(key, 'old');
  storage.setMetadata = async () => {
    throw Error('database failure');
  };
  const credentials = new ConnectionCredentials(storage);
  await assert.rejects(
    credentials.save('app', 'service', 'https://new.example', 'new'),
    /database failure/,
  );
  assert.equal((await credentials.read('app', 'service', 'https://old.example')).bearer, 'old');
  assert.equal(secrets.size, 1);
});
test('metadata cannot point at secrets belonging to a different instance/provider', async () => {
  const { metadata, secrets, storage } = store();
  metadata.set('connection:app:service', {
    origin: 'https://api.example',
    configured: true,
    secretId: 'provider:openai:key',
  });
  secrets.set('provider:openai:key', 'private');
  await assert.rejects(
    new ConnectionCredentials(storage).read('app', 'service', 'https://api.example'),
    /Неверная ссылка/,
  );
});
