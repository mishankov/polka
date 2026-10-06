import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { ClipboardHistory, clipId } from '../src/main/clipboard-history';
import { ClipboardSync } from '../src/main/clipboard-sync';
const codec = {
  encode: (text: string) => Buffer.from(text),
  decode: (bytes: Buffer) => bytes.toString(),
};
async function setup() {
  const root = await mkdtemp(join(tmpdir(), 'clipboard-sync-'));
  let now = 1000000000;
  const make = async (name: string) => {
    const history = new ClipboardHistory(
      join(root, name),
      codec,
      () => {},
      () => now,
    );
    await history.initialize();
    return history;
  };
  return {
    root,
    make,
    advance: (days = 0) => {
      now += days * 86400000 + 1;
    },
    cleanup: () => rm(root, { recursive: true, force: true }),
  };
}
async function exchange(from: ClipboardHistory, to: ClipboardHistory) {
  for (const id of await to.mergeManifest(from.manifest())) {
    const item = from.transfer(id);
    if (item) await to.receive(item, 'Other Mac');
  }
}

test('full history merges, deduplicates, preserves original time and shares pins without feedback', async () => {
  const env = await setup();
  try {
    const a = await env.make('a'),
      b = await env.make('b');
    await a.add('text', 'First', 'First');
    env.advance();
    await b.add('text', 'Second', 'Second');
    const first = a.snapshot().clips[0];
    await exchange(a, b);
    await exchange(b, a);
    assert.deepEqual(
      a.snapshot().clips.map((clip) => clip.content),
      ['Second', 'First'],
    );
    assert.equal(
      b.snapshot().clips.find((clip) => clip.id === first.id)?.createdAt,
      first.createdAt,
    );
    assert.equal(
      b.snapshot().clips.find((clip) => clip.id === first.id)?.sourceDevice,
      'Other Mac',
    );
    await b.pin(first.id, true);
    await exchange(b, a);
    assert.equal(a.snapshot().clips[0].pinned, true);
    const before = a.manifest();
    await exchange(b, a);
    await exchange(a, b);
    assert.deepEqual(a.manifest(), before);
  } finally {
    await env.cleanup();
  }
});

test('offline deletions and their tombstones survive restart; deliberately copying again creates a new version', async () => {
  const env = await setup();
  try {
    const a = await env.make('a');
    let b = await env.make('b');
    await a.add('text', 'Delete me', 'Delete me');
    await exchange(a, b);
    const id = a.snapshot().clips[0].id;
    await b.remove(id);
    b = await env.make('b');
    await exchange(a, b);
    await exchange(b, a);
    assert.equal(a.snapshot().clips.length, 0);
    assert.equal(b.snapshot().clips.length, 0);
    await a.add('text', 'Delete me', 'Delete me');
    await exchange(a, b);
    assert.equal(b.snapshot().clips.length, 1);
  } finally {
    await env.cleanup();
  }
});

test('clear history reaches offline devices, includes pins and does not remove new copies after the clear was applied', async () => {
  const env = await setup();
  try {
    const a = await env.make('a'),
      b = await env.make('b'),
      c = await env.make('c');
    await a.add('text', 'Pinned', 'Pinned');
    await a.pin(a.snapshot().clips[0].id, true);
    await exchange(a, b);
    await exchange(a, c);
    await b.add('text', 'Offline', 'Offline');
    await a.clear();
    await exchange(a, b);
    await exchange(b, a);
    await exchange(b, c);
    assert.equal(a.snapshot().clips.length, 0);
    assert.equal(b.snapshot().clips.length, 0);
    assert.equal(c.snapshot().clips.length, 0);
    await c.add('text', 'Pinned', 'Pinned');
    await exchange(c, a);
    await exchange(a, b);
    assert.equal(b.snapshot().clips[0].content, 'Pinned');
    assert.equal(b.snapshot().clips[0].pinned, false);
  } finally {
    await env.cleanup();
  }
});

test('automatic expiry stays local; repeated sync does not resurrect it, but a new pin retrieves the retained remote copy', async () => {
  const env = await setup();
  try {
    const a = await env.make('a'),
      b = await env.make('b');
    await a.preferences({ retentionDays: 30 });
    await b.preferences({ retentionDays: 1 });
    await a.add('text', 'Long lived', 'Long lived');
    await exchange(a, b);
    env.advance(2);
    await b.prune();
    await exchange(a, b);
    assert.equal(b.snapshot().clips.length, 0);
    assert.equal(a.snapshot().clips.length, 1);
    await a.pin(a.snapshot().clips[0].id, true);
    await exchange(a, b);
    assert.equal(b.snapshot().clips[0].pinned, true);
  } finally {
    await env.cleanup();
  }
});

test('concurrent pins converge, images transfer, forged content and remote preview URLs are rejected', async () => {
  const env = await setup();
  try {
    const a = await env.make('a'),
      b = await env.make('b');
    const image =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=';
    await a.add('image', image, `data:image/png;base64,${image}`);
    await exchange(a, b);
    assert.equal(b.snapshot().clips[0].content, image);
    const id = a.snapshot().clips[0].id;
    await a.pin(id, true);
    await b.pin(id, false);
    await exchange(a, b);
    await exchange(b, a);
    assert.equal(a.snapshot().clips[0].pinned, b.snapshot().clips[0].pinned);
    const transfer = a.transfer(id)!;
    await assert.rejects(
      b.receive({ ...transfer, clip: { ...transfer.clip, content: 'forged' } }, 'Other'),
    );
    await assert.rejects(
      b.receive(
        { ...transfer, clip: { ...transfer.clip, preview: 'https://example.com/tracker' } },
        'Other',
      ),
    );
    await assert.rejects(b.mergeManifest({ version: 200 }));
  } finally {
    await env.cleanup();
  }
});

test('TLS peers pair once, transfer both histories, reconnect, revoke trust and reject incorrect certificate pins', async () => {
  const env = await setup();
  const services: ClipboardSync[] = [];
  try {
    const a = await env.make('a'),
      b = await env.make('b');
    await a.add('text', 'Before pairing A', 'Before pairing A');
    await b.add('text', 'Before pairing B', 'Before pairing B');
    const make = async (history: ClipboardHistory, name: string) => {
      const service = new ClipboardSync({
        path: join(env.root, `${name}.sync`),
        codec,
        history,
        name,
        discovery: false,
        changed() {},
      });
      services.push(service);
      await service.initialize();
      await service.setEnabled(true);
      return service;
    };
    const sa = await make(a, 'Mac A'),
      sb = await make(b, 'Mac B');
    const deviceId = a.deviceId;
    sa.discover(b.deviceId, 'Mac B', '127.0.0.1', sb.port);
    sb.discover(a.deviceId, 'Mac A', '127.0.0.1', sa.port);
    sa.invite();
    const code = sa.state().invitation!.code;
    await sb.pair(code);
    assert.equal(sa.state().invitation, undefined);
    assert.equal(a.snapshot().clips.length, 2);
    assert.equal(b.snapshot().clips.length, 2);
    await assert.rejects(sb.pair(code));
    await sb.setEnabled(false);
    await a.add('text', 'While disconnected', 'While disconnected');
    await sb.setEnabled(true);
    sa.discover(b.deviceId, 'Mac B', '127.0.0.1', sb.port);
    sb.discover(a.deviceId, 'Mac A', '127.0.0.1', sa.port);
    await sb.syncNow();
    // A discovery callback may already have started the exchange.
    for (let attempt = 0; attempt < 50 && b.snapshot().clips.length !== 3; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 20));
      await sb.syncNow();
    }
    assert.equal(b.snapshot().clips.length, 3);
    const reloaded = await env.make('a');
    assert.equal(reloaded.deviceId, deviceId);
    await sa.forget(b.deviceId);
    await b.add('text', 'Revoked', 'Revoked');
    await sb.syncNow();
    assert(!a.snapshot().clips.some((clip) => clip.content === 'Revoked'));
    assert.equal(sb.state().peers[0].status, 'offline');
    sa.invite();
    const invitation = JSON.parse(Buffer.from(sa.state().invitation!.code, 'base64url').toString());
    invitation.fingerprint = Array(32).fill('00').join(':');
    await assert.rejects(
      sb.pair(Buffer.from(JSON.stringify(invitation)).toString('base64url')),
      /Сертификат/,
    );
    assert(
      sa.state().invitation,
      'bad certificate pin must fail before the invitation is consumed',
    );
    assert(
      JSON.parse(await readFile(join(env.root, 'Mac A.sync'), 'utf8')).cert.includes(
        'BEGIN CERTIFICATE',
      ),
    );
  } finally {
    for (const service of services) await service.stop();
    await env.cleanup();
  }
});

for (const stage of ['decrypt', 'encrypt'] as const) {
  test(`sync ${stage} failure retains its cause and file while local history remains writable`, async () => {
    const env = await setup();
    const history = await env.make('local');
    const path = join(env.root, 'sync');
    const bytes = Buffer.from(JSON.stringify({ enabled: false, key: '', cert: '', peers: [] }));
    const original = Object.assign(new Error('sync key unavailable'), { code: 'ENOENT' });
    const sync = new ClipboardSync({
      path,
      history,
      changed: () => {},
      discovery: false,
      codec: {
        encode: (value) => {
          if (stage === 'encrypt') throw original;
          return codec.encode(value);
        },
        decode: (value) => {
          if (stage === 'decrypt') throw original;
          return codec.decode(value);
        },
      },
    });
    try {
      await writeFile(path, bytes);
      if (stage === 'decrypt') await assert.rejects(sync.initialize(), { cause: original });
      else {
        await sync.initialize();
        await assert.rejects(sync.setEnabled(true), { cause: original });
      }
      assert.equal(sync.storage.failureReason, original);
      assert.equal(sync.state().storage.diagnostic?.stage, stage);
      assert.equal(sync.state().status, 'failed');
      assert.equal(sync.state().enabled, false);
      await assert.rejects(sync.setEnabled(false), { cause: original });
      await sync.syncNow();
      await history.add('text', 'Local still works', 'Local still works');
      assert.equal(history.storage.state().status, 'ready');
      assert.equal(history.snapshot().clips.length, 1);
      await sync.stop();
      assert.deepEqual(await readFile(path), bytes);
    } finally {
      await sync.stop();
      await env.cleanup();
    }
  });
}
