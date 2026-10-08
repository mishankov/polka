import test from 'node:test';
import assert from 'node:assert/strict';
import { calculate } from '../../src/shared/calculator';
import { shelfSearch, clipboardSnippet } from '../../src/shared/shelf-search';
import { BUILTIN_APPS, type LauncherApp } from '../../src/shared/launcher';
import type { ClipboardClip } from '../../src/shared/clipboard';

test('calculator handles precedence, signs, powers, decimal separators and percentages', () => {
  for (const [expression, value] of [
    ['1250 * 3', '3750'],
    ['(450 + 180) / 2', '315'],
    ['2 + 3 * 4', '14'],
    ['-2^2', '-4'],
    ['(-2)^2', '4'],
    ['2^3^2', '512'],
    ['2^-3', '0.125'],
    ['1,5 + 2.5', '4'],
    ['0.1 + 0.2', '0.3'],
    ['3 × 4 − 2', '10'],
    ['12 ÷ 3', '4'],
    ['2x3', '6'],
    ['15% of 240', '36'],
    ['15% от 240', '36'],
    ['240 * 15%', '36'],
    ['100 + 10%', '100.1'],
    ['1e3 / 2', '500'],
    ['= 42', '42'],
    ['1 - 1', '0'],
    ['(-0)', '0'],
  ]) {
    assert.deepEqual(calculate(expression), { status: 'result', expression, value });
  }
});

test('calculator waits for unfinished expressions and rejects invalid or unsafe inputs', () => {
  for (const query of ['12 +', '(2 + 3', '2 ^', '10 * -'])
    assert.equal(calculate(query)?.status, 'incomplete', query);
  for (const query of [
    '1/0',
    '0/0',
    '2^^3',
    '1 2 + 3',
    '2(3+4)',
    '2%%',
    '10^1000',
    '(-1)^0.5',
    '1+'.repeat(300),
  ])
    assert.equal(calculate(query)?.status, 'error', query);
  for (const query of [
    '',
    'Safari',
    '1Password',
    '42',
    'https://example.com',
    'process.exit()',
    '2+alert(1)',
  ])
    assert.equal(calculate(query), undefined, query);
});

function clip(id: string, content: string, createdAt = 0, pinned = false): ClipboardClip {
  return { id, kind: 'text', content, preview: content.slice(0, 30), createdAt, pinned };
}

test('search keeps apps first, limits clipboard matches and preserves the full-history query', () => {
  const app: LauncherApp = {
    kind: 'mac',
    id: 'mac:notes',
    name: 'Notes',
    description: '',
    icon: '',
  };
  const clips = [
    clip('old', 'notes one'),
    clip('new', 'NOTES two', 10),
    clip('pin', 'notes three', 1, true),
    clip('last', 'notes four', 2),
    clip('other', 'unrelated'),
  ];
  assert.deepEqual(
    shelfSearch([app], clips, 'notes').results.map((result) => result.id),
    ['app:mac:notes', 'clip:pin', 'clip:new', 'clip:last', 'more-clips'],
  );
  assert.deepEqual(shelfSearch([app], clips, 'notes').results.at(-1), {
    id: 'more-clips',
    kind: 'more-clips',
    count: 4,
    query: 'notes',
  });
  assert.equal(shelfSearch([app], clips, '   ').results.length, 1);
  assert.equal(shelfSearch([app], clips, 'unmatched').results.length, 0);
  assert.equal(shelfSearch(BUILTIN_APPS, clips, 'буфер').results[0].kind, 'app');
  assert.equal(shelfSearch([], [clip('math', '2+2')], '2+2').results[0].kind, 'calculation');
  assert.equal(shelfSearch([], [], '1+').results.length, 0);
});

test('clipboard matches include Russian, images and snippets beyond the saved preview', () => {
  const long = clip('long', `${'Начало '.repeat(100)}Нужный текст в конце`);
  const image: ClipboardClip = {
    id: 'image',
    kind: 'image',
    content: '',
    preview: 'data:image/png;base64,',
    pinned: false,
    createdAt: 1,
  };
  const results = shelfSearch([], [long, image], 'НУЖНЫЙ текст').results;
  assert.equal(results[0].id, 'clip:long');
  assert.match(clipboardSnippet(long, 'НУЖНЫЙ текст'), /Нужный текст/);
  assert(clipboardSnippet(long, 'НУЖНЫЙ текст').length <= 162);
  assert.equal(shelfSearch([], [long, image], 'изображение').results[0].id, 'clip:image');
});

test('shelf searches snippet names and content independently and opens overflow in the correct app', () => {
  const clips = [clip('history', 'Sample history')];
  const snippets = Array.from({ length: 4 }, (_, i) => ({
    ...clip(`snippet-${i}`, 'Reusable sample text', i),
    name: `Address ${i}`,
    snippet: true,
  }));
  assert.deepEqual(
    shelfSearch([], clips, 'address sample', {}, {}, snippets).results.map((result) => result.id),
    ['clip:snippet-3', 'clip:snippet-2', 'clip:snippet-1', 'more-snippets'],
  );
  assert.deepEqual(shelfSearch([], clips, 'address sample', {}, {}, snippets).results.at(-1), {
    id: 'more-snippets',
    kind: 'more-snippets',
    count: 4,
    query: 'address sample',
  });
  assert.equal(shelfSearch([], clips, 'address').results.length, 0);
  assert.equal(shelfSearch([], clips, 'sample', {}, {}, snippets).results[0].id, 'clip:history');
});

test('app ranking preserves calculation priority and leaves clipboard matching literal', () => {
  const apps: LauncherApp[] = ['Calculator', 'Calendar'].map((name) => ({
    kind: 'mac',
    id: `mac:${name}`,
    name,
    icon: '',
    description: '',
    searchTerms: name === 'Calculator' ? ['2+2'] : [],
  }));
  const usage = { 'mac:Calendar': { count: 100, lastLaunchedAt: 10 } };
  const clips = [clip('literal', 'cal'), clip('layout', 'сфд')];
  assert.deepEqual(
    shelfSearch(apps, clips, 'cal', usage).results.map((result) => result.id),
    ['app:mac:Calendar', 'app:mac:Calculator', 'clip:literal'],
  );
  assert.deepEqual(
    shelfSearch(apps, clips, 'сфд', usage).results.map((result) => result.id),
    ['app:mac:Calendar', 'app:mac:Calculator', 'clip:layout'],
  );
  assert.equal(shelfSearch(apps, clips, '2+2', usage).results[0].kind, 'calculation');
});
