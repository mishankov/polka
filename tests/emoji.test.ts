import test from 'node:test';
import assert from 'node:assert/strict';
import {
  EMOJIS,
  EMOJI_CATEGORIES,
  emojiById,
  emojiGridIndex,
  emojiResults,
} from '../src/shared/emoji';

test('the bundled catalog keeps complete Unicode sequences and localized names', () => {
  assert.equal(EMOJIS.length, 3781);
  assert.equal(new Set(EMOJIS.map((emoji) => emoji.id)).size, EMOJIS.length);
  const segmenter = new Intl.Segmenter('en', { granularity: 'grapheme' });
  for (const emoji of EMOJIS) {
    assert(emoji.name && emoji.englishName, emoji.id);
    assert(
      EMOJI_CATEGORIES.some((category) => category.id === emoji.category),
      emoji.category,
    );
    assert.equal([...segmenter.segment(emoji.value)].length, 1, emoji.value);
    assert.equal(emojiById(emoji.id)?.value, emoji.value);
  }
  for (const value of ['❤️', '👩🏽‍💻', '👨‍👩‍👧‍👦', '🇷🇺', '1️⃣', '🏳️‍🌈']) {
    const match = emojiResults(value)[0];
    assert.equal(match?.value, value, value);
  }
  assert.equal(emojiById('made-up-id'), undefined);
});

test('search matches Russian and English keywords, informal aliases, case and ё', () => {
  for (const [query, value] of [
    ['улыбка', '😀'],
    ['HEART', '❤️'],
    ['ЛАЙК', '👍'],
    ['спасибо', '🙏'],
    ['lol', '😂'],
    ['красное сердце', '❤️'],
  ])
    assert(
      emojiResults(query).some((emoji) => emoji.value === value),
      query,
    );
  assert.deepEqual(
    emojiResults('ёлка').map((emoji) => emoji.id),
    emojiResults('елка').map((emoji) => emoji.id),
  );
  assert.equal(emojiResults('zz-no-emoji-zz').length, 0);
  assert.equal(emojiResults('красное сердце')[0].value, '❤️');
});

test('categories and skin tones filter without losing standalone or mixed-tone emoji', () => {
  const people = emojiResults('', 'People & Body');
  assert(people.length > 0);
  assert(people.every((emoji) => emoji.category === 'People & Body' && !emoji.tones.length));
  const toned = emojiResults('лайк', 'all', '🏽');
  assert(toned.some((emoji) => emoji.value === '👍🏽'));
  assert(!toned.some((emoji) => emoji.value === '👍🏻'));
  assert(emojiResults('', 'all', 'all').some((emoji) => new Set(emoji.tones).size > 1));
  assert(emojiResults('❤️', 'all', '🏽').some((emoji) => emoji.value === '❤️'));
  assert.equal(emojiResults('👩🏽‍💻')[0].value, '👩🏽‍💻');
});

test('grid navigation respects columns and clamps at incomplete rows and empty results', () => {
  assert.equal(emojiGridIndex(0, 'ArrowRight', 23, 10), 1);
  assert.equal(emojiGridIndex(1, 'ArrowDown', 23, 10), 11);
  assert.equal(emojiGridIndex(18, 'ArrowDown', 23, 10), 22);
  assert.equal(emojiGridIndex(22, 'ArrowUp', 23, 10), 12);
  assert.equal(emojiGridIndex(0, 'ArrowLeft', 23, 10), 0);
  assert.equal(emojiGridIndex(15, 'Home', 23, 10), 0);
  assert.equal(emojiGridIndex(2, 'End', 23, 10), 22);
  assert.equal(emojiGridIndex(0, 'ArrowDown', 0, 10), 0);
});
