import assert from 'node:assert/strict';
import { test } from 'node:test';
import { clipboardWebUrl, transformClipboardText } from '../src/shared/clipboard-actions';

test('case changes support Cyrillic and Latin while preserving whitespace, punctuation and emoji', () => {
  const text = 'Привет, World!\nЁж 🦔 123';
  assert.equal(transformClipboardText(text, 'upperCase'), 'ПРИВЕТ, WORLD!\nЁЖ 🦔 123');
  assert.equal(transformClipboardText(text, 'lowerCase'), 'привет, world!\nёж 🦔 123');
  assert.equal(transformClipboardText('straße', 'upperCase'), 'STRASSE');
});

test('only a complete HTTP(S) URL without credentials can be opened', () => {
  assert.equal(
    clipboardWebUrl(' https://example.com/path?q=1#part\n'),
    'https://example.com/path?q=1#part',
  );
  assert.equal(clipboardWebUrl('HTTP://EXAMPLE.COM'), 'http://example.com/');
  assert.equal(clipboardWebUrl('https://пример.рф'), 'https://xn--e1afmkfd.xn--p1ai/');
  for (const value of [
    '',
    'example.com',
    '//example.com',
    'https:',
    'https://',
    'javascript:alert(1)',
    'file:///tmp/test',
    'mailto:test@example.com',
    'data:text/html,test',
    'Open https://example.com',
    'https://example.com https://other.example',
    'https://user:password@example.com',
    'https://user@example.com',
    'https://example.com/\npath',
    'https://example.com/\u0000path',
    'https://example.com\\path',
    'https://[invalid',
  ])
    assert.equal(clipboardWebUrl(value), undefined, value);
});
