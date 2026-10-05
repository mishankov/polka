import data from './emoji-data.json';

export interface Emoji {
  id: string;
  value: string;
  category: string;
  name: string;
  englishName: string;
  keywords: string;
  tones: string[];
}
export const EMOJI_CATEGORIES = [
  { id: 'all', label: 'Все эмодзи', symbol: '⌘' },
  { id: 'Smileys & Emotion', label: 'Смайлы и эмоции', symbol: '😀' },
  { id: 'People & Body', label: 'Люди и жесты', symbol: '👋' },
  { id: 'Animals & Nature', label: 'Животные и природа', symbol: '🌿' },
  { id: 'Food & Drink', label: 'Еда и напитки', symbol: '🍋' },
  { id: 'Travel & Places', label: 'Места и транспорт', symbol: '🚀' },
  { id: 'Activities', label: 'Занятия', symbol: '⚽' },
  { id: 'Objects', label: 'Предметы', symbol: '💡' },
  { id: 'Symbols', label: 'Символы', symbol: '❤️' },
  { id: 'Flags', label: 'Флаги', symbol: '🏳️' },
] as const;
export const EMOJI_TONES = [
  { value: 'default', label: '✋ Стандартный' },
  { value: '🏻', label: 'Очень светлый' },
  { value: '🏼', label: 'Светлый' },
  { value: '🏽', label: 'Средний' },
  { value: '🏾', label: 'Тёмный' },
  { value: '🏿', label: 'Очень тёмный' },
  { value: 'all', label: 'Все оттенки' },
];

// Informal aliases supplement CLDR names and keywords; they apply to tone variants too.
const aliases: Record<string, string> = {
  '😀': 'смайл смайлик улыбка smile happy',
  '😂': 'лол ржу смех lol laughing',
  '🤣': 'лол ржу смех lol rofl',
  '👍': 'лайк класс супер отлично like yes good',
  '👎': 'дизлайк dislike no bad',
  '🙏': 'спасибо пожалуйста благодарю thank thanks please',
  '❤️': 'красное сердце любовь люблю love heart',
  '🎉': 'ура праздник поздравляю party congratulations',
  '🔥': 'огонь круто fire lit',
  '😢': 'грустно грусть sad crying',
  '😭': 'грустно грусть sad crying',
};
export function normalizeEmojiSearch(value: string) {
  return value.normalize('NFKC').toLocaleLowerCase('ru').replaceAll('ё', 'е').trim();
}
type EmojiRow = [string, number, string, string, string, string];
export const EMOJIS: Emoji[] = (data.entries as EmojiRow[]).map(
  ([value, group, name, englishName, russianKeywords, englishKeywords]) => ({
    id: Array.from(value, (character) => character.codePointAt(0)!.toString(16)).join('-'),
    value,
    category: data.groups[group],
    name,
    englishName,
    keywords: normalizeEmojiSearch(
      `${name} ${englishName} ${russianKeywords} ${englishKeywords} ${aliases[value.replace(/[🏻-🏿]/gu, '')] || ''}`,
    ),
    tones: Array.from(value).filter((character) => /^[🏻-🏿]$/u.test(character)),
  }),
);
const byId = new Map(EMOJIS.map((emoji) => [emoji.id, emoji]));
export const emojiById = (id: string) => byId.get(id);

export function emojiResults(query: string, category = 'all', tone = 'default') {
  const normalized = normalizeEmojiSearch(query);
  const terms = normalized.split(/\s+/).filter(Boolean);
  const exactValue = EMOJIS.find((emoji) => emoji.value === query.trim());
  const matches = EMOJIS.filter((emoji) => {
    if (category !== 'all' && emoji.category !== category) return false;
    // A pasted emoji is searchable even when its tone differs from the current filter.
    if (!exactValue && tone !== 'all') {
      if (tone === 'default' ? emoji.tones.length : emoji.tones.some((value) => value !== tone))
        return false;
    }
    return terms.every((term) => emoji.keywords.includes(term) || emoji.value.includes(term));
  });
  if (!normalized) return matches;
  const score = (emoji: Emoji) =>
    emoji === exactValue
      ? 0
      : [emoji.name, emoji.englishName].some((name) => normalizeEmojiSearch(name) === normalized)
        ? 1
        : [emoji.name, emoji.englishName].some((name) =>
              normalizeEmojiSearch(name).startsWith(normalized),
            ) ||
            normalizeEmojiSearch(aliases[emoji.value.replace(/[🏻-🏿]/gu, '')] || '').includes(
              normalized,
            )
          ? 2
          : 3;
  return matches.sort((a, b) => score(a) - score(b));
}

/** Grid edges clamp to the last actual cell, including an incomplete final row. */
export function emojiGridIndex(index: number, key: string, count: number, columns: number) {
  const delta = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: columns, ArrowUp: -columns }[key];
  return key === 'Home'
    ? 0
    : key === 'End'
      ? Math.max(0, count - 1)
      : Math.max(0, Math.min(count - 1, index + (delta || 0)));
}
