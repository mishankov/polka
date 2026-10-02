import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compileExtension, extensionDependencies } from '../src/extensions/host';
import { createBuiltinAdapters } from '../src/extensions/adapters';
import { validateDefinition } from '../src/core/schema';

test('curated component dependencies compile without resolving user imports from disk/network', async () => {
  const source = `import { Button } from '@mantine/core'; import { useSDK, RecordTable } from '@everything/ui'; import { z } from 'zod'; export default () => <Button>{z.string().parse('Ready')}</Button>`;
  const code = await compileExtension(source, 'component', {
    '@mantine/core': extensionDependencies['@mantine/core'],
    '@everything/ui': '1.0.0',
    zod: extensionDependencies.zod,
  });
  assert.match(code, /__extensionModules/);
  for (const name of [
    'node:fs',
    'electron',
    'https://cdn.example.com/module.js',
    '../../src/main/index.ts',
    '@mantine/core/internal',
    'lodash',
  ])
    await assert.rejects(
      compileExtension(`import x from '${name}';export default x`, 'component'),
      /запрещён/,
    );
  await assert.rejects(
    compileExtension(source, 'component', { '@mantine/core': '^9.0.0' }),
    /не входит/,
  );
  await assert.rejects(
    compileExtension("import {z} from 'zod'; export default x=>z.string().parse(x)", 'handler'),
    /запрещён/,
  );
  await assert.rejects(
    compileExtension("export default () => import('https://example.com/a.js')", 'component'),
    /запрещён/,
  );
});

test('schema enforces exact shipped versions before installing an extension', () => {
  const definition = {
    schemaVersion: 1,
    name: 'UI',
    entities: [],
    screens: [],
    actions: [],
    automations: [],
    permissions: [],
    extensions: [
      {
        id: 'screen',
        name: 'Screen',
        kind: 'component',
        source: 'export default ()=>null',
        dependencies: {
          '@everything/ui': '1.0.0',
          '@mantine/core': extensionDependencies['@mantine/core'],
        },
      },
    ],
  };
  assert.doesNotThrow(() => validateDefinition(definition));
  definition.extensions[0].dependencies['@mantine/core'] = '9.0.0';
  assert.throws(() => validateDefinition(definition), /не закреплена/);
});

test('trusted HTTP adapter validates origin/headers and supports bounded JSON APIs with mock transport', async () => {
  const grants: string[] = [];
  let sent: RequestInit | undefined;
  const { registry } = createBuiltinAdapters({
    ensurePermission: async (appId, p) => {
      assert.equal(appId, 'a');
      grants.push(p);
      if (p !== 'network:https://api.example.com') throw Error('denied');
    },
    fetch: (async (_url, init) => {
      sent = init;
      return new Response('{"id":42}', {
        status: 201,
        headers: { 'content-type': 'application/json' },
      });
    }) as typeof fetch,
  });
  const result: any = await registry.invoke('network.request', 'a', {
    url: 'https://api.example.com/items',
    method: 'POST',
    json: { name: 'hello' },
    responseType: 'json',
  });
  assert.equal(result.status, 201);
  assert.deepEqual(result.body, { id: 42 });
  assert.equal(sent?.method, 'POST');
  assert.equal(sent?.body, '{"name":"hello"}');
  assert.equal(sent?.redirect, 'error');
  assert.equal(sent?.credentials, 'omit');
  assert.equal(grants.length, 3);
  await assert.rejects(
    registry.invoke('network.request', 'a', { url: 'https://evil.example.com/' }),
    /denied/,
  );
  await assert.rejects(
    registry.invoke('network.request', 'a', { url: 'file:///etc/passwd' }),
    /HTTPS/,
  );
  await assert.rejects(
    registry.invoke('network.request', 'a', { url: 'https://user:secret@api.example.com/' }),
    /HTTPS/,
  );
  await assert.rejects(
    registry.invoke('network.request', 'a', {
      url: 'https://api.example.com/',
      headers: { Authorization: 'secret' },
    }),
    /платформой/,
  );
  await assert.rejects(
    registry.invoke('network.fetch', 'a', { url: 'https://api.example.com/', method: 'POST' }),
    /GET/,
  );
  const metadata = registry.catalog();
  assert.equal(metadata.length, 2);
  assert.equal(metadata[0].version, '1.0.0');
  assert.equal('execute' in metadata[0], false);
  assert.equal(metadata[0].cancellation, true);
});

test('HTTP adapter enforces response limit, revocation during request, and cancellation', async () => {
  const large = createBuiltinAdapters({
    ensurePermission: async () => {},
    fetch: (async () => new Response('x'.repeat(2 * 1024 * 1024 + 1))) as typeof fetch,
  });
  await assert.rejects(
    large.registry.invoke('network.fetch', 'a', { url: 'https://example.com' }),
    /2 МБ/,
  );
  let granted = true;
  const revoked = createBuiltinAdapters({
    ensurePermission: async () => {
      if (!granted) throw Error('revoked');
    },
    fetch: (async () => {
      granted = false;
      return new Response('private');
    }) as typeof fetch,
  });
  await assert.rejects(
    revoked.registry.invoke('network.fetch', 'a', { url: 'https://example.com' }),
    /revoked/,
  );
  let started!: () => void;
  const ready = new Promise<void>((resolve) => {
    started = resolve;
  });
  const abort = createBuiltinAdapters({
    ensurePermission: async () => {},
    fetch: ((_, init) =>
      new Promise((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => reject(Error('aborted')));
        started();
      })) as typeof fetch,
  });
  const pending = abort.registry.invoke('network.fetch', 'a', { url: 'https://example.com' });
  await ready;
  abort.abortApp('a');
  await assert.rejects(pending, /aborted/);
});

test('connection resolver receives only bound app and exact origin, secret never enters catalog/result', async () => {
  const { registry } = createBuiltinAdapters({
    ensurePermission: async () => {},
    readConnection: async (appId, id, origin) => {
      assert.deepEqual([appId, id, origin], ['owner', 'service', 'https://example.com']);
      return { bearer: 'private-key' };
    },
    fetch: (async (_, init) => {
      assert.equal(new Headers(init?.headers).get('authorization'), 'Bearer private-key');
      return new Response('ok');
    }) as typeof fetch,
  });
  const result = await registry.invoke('network.request', 'owner', {
    url: 'https://example.com',
    connectionId: 'service',
  });
  assert.equal(
    JSON.stringify({ result, catalog: registry.catalog() }).includes('private-key'),
    false,
  );
});
