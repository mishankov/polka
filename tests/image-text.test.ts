import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { existsSync } from 'node:fs';
import { ClipboardHistory } from '../src/main/clipboard-history';
import { ImageTextIndexer, recognizeImageText, IMAGE_TEXT_VERSION } from '../src/main/image-text';
import { clipboardResults } from '../src/shared/clipboard';
import { clipboardSnippet, shelfSearch } from '../src/shared/shelf-search';

const codec = {
  encode: (text: string) => Buffer.from(text),
  decode: (bytes: Buffer) => bytes.toString(),
};
async function until(check: () => boolean) {
  const deadline = Date.now() + 5000;
  while (!check()) {
    assert(Date.now() < deadline, 'Indexing did not finish');
    await delay(10);
  }
}
async function fixture(run: (history: ClipboardHistory, path: string) => Promise<void>) {
  const root = await mkdtemp(join(tmpdir(), 'polka-ocr-'));
  try {
    const path = join(root, 'history.enc');
    const history = new ClipboardHistory(path, codec, () => {});
    await history.initialize();
    await run(history, path);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test('bounded background indexing leaves capture/search available, caches repeats and restart; config changes reindex', async () => {
  await fixture(async (history, path) => {
    let calls = 0;
    let active = 0;
    let maxActive = 0;
    let release!: () => void;
    const gate = new Promise<void>((done) => {
      release = done;
    });
    const indexer = new ImageTextIndexer(
      history,
      async () => {
        calls++;
        maxActive = Math.max(maxActive, ++active);
        await gate;
        active--;
        return { text: 'Aurora Доставка подтверждена', languages: ['ru-RU', 'en-US'] };
      },
      'v1',
    );
    try {
      await history.add('image', 'first', 'thumbnail');
      await history.add('image', 'second', 'thumbnail');
      indexer.changed();
      await until(() => calls === 1);
      await history.add('text', 'Capture remains available', 'Capture remains available');
      assert.equal(clipboardResults(history.snapshot().clips, 'capture').length, 1);
      await history.add('image', 'first', 'thumbnail');
      release();
      await until(() => history.imageTextImages().every((c) => c.ocr?.status === 'ready'));
      assert.equal(calls, 2);
      assert.equal(maxActive, 1);
      await history.add('image', 'first', 'thumbnail');
      indexer.changed();
      await delay(200);
      assert.equal(calls, 2);
      assert.equal(clipboardResults(history.snapshot().clips, 'aurora доставка').length, 2);
      assert.equal(shelfSearch([], history.snapshot().clips, 'доставка').results.length, 2);
      assert.match(clipboardSnippet(history.snapshot().clips[0], 'доставка'), /Доставка/);
      const restored = new ClipboardHistory(path, codec, () => {});
      await restored.initialize();
      assert.equal(restored.imageTextImages()[0].ocr?.version, 'v1');
      const v2 = new ImageTextIndexer(
        restored,
        async () => ({ text: '', languages: ['en-US'] }),
        'v2',
      );
      v2.changed();
      await until(() => restored.imageTextImages().every((c) => c.ocr?.version === 'v2'));
      assert.equal(restored.imageTextImages()[0].ocr?.status, 'empty');
      v2.stop();
    } finally {
      indexer.stop();
    }
  });
});

test('failure is distinct from no-text, retained across restart, and explicitly retryable', async () => {
  await fixture(async (history, path) => {
    await history.add('image', 'failed', 'thumbnail');
    let fail = true;
    const indexer = new ImageTextIndexer(
      history,
      async () => {
        if (fail) throw Error('private native diagnostic');
        return { text: '', languages: ['en-US'] };
      },
      'v1',
    );
    try {
      indexer.changed();
      await until(() => history.imageTextImages()[0].ocr?.status === 'failed');
      assert(!JSON.stringify(history.snapshot()).includes('private native'));
      const restored = new ClipboardHistory(path, codec, () => {});
      await restored.initialize();
      assert.equal(restored.imageTextImages()[0].ocr?.status, 'failed');
      fail = false;
      await history.retryImageText(history.imageTextImages()[0].id);
      indexer.changed();
      await until(() => history.imageTextImages()[0].ocr?.status === 'empty');
    } finally {
      indexer.stop();
    }
  });
});

for (const removal of ['remove', 'clear', 'remote-clear', 'expire'] as const)
  test(`${removal} during recognition cannot restore an image or attach results to a new incarnation`, async () => {
    await fixture(async (history) => {
      await history.add('image', 'same pixels', 'thumbnail');
      const clip = history.imageTextImages()[0];
      if (removal === 'remove') await history.remove(clip.id);
      if (removal === 'clear') await history.clear();
      if (removal === 'remote-clear') {
        const manifest = history.manifest();
        await history.mergeManifest({
          ...manifest,
          clear: { counter: Date.now() + 10000, device: history.deviceId },
        });
      }
      if (removal === 'expire') await history.preferences({ retentionDays: 1 });
      if (removal === 'expire') {
        // Force the clock beyond retention without replacing the store.
        (history as any).now = () => Date.now() + 2 * 86400000;
        await history.prune();
      }
      await history.saveImageText(clip.id, clip.incarnation, {
        version: 'v1',
        status: 'ready',
        text: 'late',
        languages: [],
      });
      assert.equal(history.snapshot().clips.length, 0);
      await history.add('image', 'same pixels', 'thumbnail');
      await history.saveImageText(clip.id, clip.incarnation, {
        version: 'v1',
        status: 'ready',
        text: 'late',
        languages: [],
      });
      assert.equal(history.imageTextImages()[0].ocr, undefined);
    });
  });

test('sync v1 transfers omit local OCR and incoming images are independently indexed', async () => {
  await fixture(async (source) => {
    await source.add(
      'image',
      (await readFile('tests/fixtures/image-text/english.png')).toString('base64'),
      'data:image/png;base64,AAAA',
    );
    const clip = source.imageTextImages()[0];
    await source.saveImageText(clip.id, clip.incarnation, {
      version: 'v1',
      status: 'ready',
      text: 'local only',
      languages: [],
    });
    const transfer = source.transfer(clip.id)!;
    assert(!('ocr' in transfer.clip));
    await fixture(async (target) => {
      await target.mergeManifest(source.manifest());
      await target.receive(
        { ...transfer, clip: { ...transfer.clip, ocr: { invalid: true } } },
        'Other Mac',
      );
      assert.equal(target.imageTextImages()[0].ocr, undefined);
      const indexer = new ImageTextIndexer(
        target,
        async () => ({ text: 'recognized here', languages: ['en-US'] }),
        'v1',
      );
      try {
        indexer.changed();
        await until(() => target.imageTextImages()[0].ocr?.text === 'recognized here');
      } finally {
        indexer.stop();
      }
    });
  });
});

test(
  'Vision recognizes English, Russian and mixed full-resolution fixtures and distinguishes blank/invalid images',
  {
    skip:
      process.platform !== 'darwin' || !existsSync('build/image-text')
        ? 'Build native helper on macOS first'
        : false,
    timeout: 60000,
  },
  async () => {
    for (const [name, words] of [
      ['english', ['Aurora', 'Delivery']],
      ['russian', ['Север', 'Доставка']],
      ['mixed', ['Aurora', 'Север', 'Delivery', 'Доставка']],
      ['empty', []],
    ] as const) {
      const content = (await readFile(`tests/fixtures/image-text/${name}.png`)).toString('base64');
      const result = await recognizeImageText(
        resolve('build/image-text'),
        content,
        new AbortController().signal,
      );
      assert(result.languages.includes('ru-RU'));
      assert(result.languages.includes('en-US'));
      const clip = {
        id: name,
        kind: 'image' as const,
        content,
        preview: '',
        createdAt: 0,
        pinned: false,
        ocr: {
          ...result,
          version: IMAGE_TEXT_VERSION,
          status: result.text ? ('ready' as const) : ('empty' as const),
        },
      };
      for (const word of words)
        assert.equal(clipboardResults([clip], word).length, 1, `${name}: ${word}; ${result.text}`);
      if (name === 'empty') assert.equal(result.text, '');
    }
    await assert.rejects(
      recognizeImageText(
        resolve('build/image-text'),
        Buffer.from('invalid').toString('base64'),
        new AbortController().signal,
      ),
    );
  },
);

test('removing a running job aborts it, shutdown waits for the worker, and late completion is discarded', async () => {
  await fixture(async (history) => {
    let signal: AbortSignal | undefined;
    let finish!: () => void;
    const indexer = new ImageTextIndexer(history, async (_, jobSignal) => {
      signal = jobSignal;
      await new Promise<void>((done) => {
        finish = done;
      });
      return { text: 'late private result', languages: [] };
    });
    await history.add('image', 'running', 'thumbnail');
    indexer.changed();
    await until(() => !!signal);
    await history.clear();
    indexer.changed();
    assert.equal(signal!.aborted, true);
    let stopped = false;
    const stopping = indexer.stop().then(() => {
      stopped = true;
    });
    await delay(10);
    assert.equal(stopped, false);
    finish();
    await stopping;
    assert.equal(history.snapshot().clips.length, 0);
  });
});

test('unavailable helpers and pre-cancelled requests fail without leaking a worker', async () => {
  await assert.rejects(
    recognizeImageText('/nonexistent/polka-image-text', '', new AbortController().signal),
  );
  if (process.platform === 'darwin' && existsSync('build/image-text')) {
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(recognizeImageText(resolve('build/image-text'), '', controller.signal));
  }
});
