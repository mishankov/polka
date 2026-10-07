export const DEFAULT_LAUNCHER_SHORTCUT = 'CommandOrControl+Shift+Space';
export interface LauncherPreferences {
  accelerator: string;
  registered: boolean;
  error?: string;
}
export interface MacLauncherApp {
  kind: 'mac';
  id: string;
  name: string;
  icon: string;
  description: string;
  searchTerms?: string[];
}
export interface BuiltinLauncherApp {
  kind: 'builtin';
  id: 'builtin:clipboard' | 'builtin:emoji' | 'builtin:snippets';
  name: string;
  icon: string;
  description: string;
  searchTerms: string[];
}
export const BUILTIN_APPS: BuiltinLauncherApp[] = [
  {
    kind: 'builtin',
    id: 'builtin:snippets',
    name: 'Сниппеты',
    icon: 'snippets',
    description: 'Адреса, реквизиты и готовые ответы — создать и вставить',
    searchTerms: ['snippet', 'snippets', 'сниппет', 'шаблоны', 'готовые ответы'],
  },
  {
    kind: 'builtin',
    id: 'builtin:clipboard',
    name: 'История буфера обмена',
    icon: 'clipboard',
    description: 'Скопированный текст и изображения',
    searchTerms: ['clipboard', 'history', 'буфер', 'копировать'],
  },
  {
    kind: 'builtin',
    id: 'builtin:emoji',
    name: 'Эмодзи',
    icon: 'emoji',
    description: 'Смайлы, жесты и символы — найти и вставить',
    searchTerms: ['emoji', 'emojis', 'эмоджи', 'смайлик', 'смайлики'],
  },
];
export type LauncherApp = MacLauncherApp | BuiltinLauncherApp;

export type LauncherUsageStats = Record<string, { count: number; lastLaunchedAt: number }>;

const normalize = (text: string) => text.normalize('NFKC').toLowerCase().replace(/ё/g, 'е');
const latinKeys = '`qwertyuiop[]asdfghjkl;\'zxcvbnm,.~{}:"<>';
const russianKeys = 'ёйцукенгшщзхъфывапролджэячсмитьбюёхъжэбю';
// Use physical keyboard positions, including punctuation on letter keys.
function switchLayout(query: string, from: string, to: string) {
  return [...query].map((char) => (from.includes(char) ? to[from.indexOf(char)] : char)).join('');
}
type SearchField = { text: string; words: string[]; initials: string };
const searchFields = new WeakMap<LauncherApp, { names: SearchField[]; metadata: string }>();
function fields(app: LauncherApp) {
  let value = searchFields.get(app);
  if (!value) {
    value = {
      names: [app.name, ...(app.searchTerms || [])].map((name) => {
        const words = normalize(name.replace(/([\p{Ll}\d])(\p{Lu})/gu, '$1 $2'))
          .split(/[^\p{L}\p{N}]+/u)
          .filter(Boolean);
        return {
          text: normalize(name),
          words,
          initials: words.length > 1 ? words.map((word) => word[0]).join('') : '',
        };
      }),
      metadata: normalize(app.description),
    };
    searchFields.set(app, value);
  }
  return value;
}

/** Bounded optimal-string-alignment distance, counting adjacent transpositions as one typo. */
function typoDistance(query: string, word: string, limit: number) {
  if (Math.abs(query.length - word.length) > limit) return limit + 1;
  let previous = Array.from({ length: word.length + 1 }, (_, i) => i);
  let beforePrevious = previous;
  for (let i = 1; i <= query.length; i++) {
    const row = new Array<number>(word.length + 1).fill(limit + 1);
    row[0] = i;
    let minimum = row[0];
    for (let j = Math.max(1, i - limit); j <= Math.min(word.length, i + limit); j++) {
      row[j] = Math.min(
        row[j - 1] + 1,
        previous[j] + 1,
        previous[j - 1] + Number(query[i - 1] !== word[j - 1]),
      );
      if (i > 1 && j > 1 && query[i - 1] === word[j - 2] && query[i - 2] === word[j - 1])
        row[j] = Math.min(row[j], beforePrevious[j - 2] + 1);
      minimum = Math.min(minimum, row[j]);
    }
    if (minimum > limit) return limit + 1;
    beforePrevious = previous;
    previous = row;
  }
  return previous[word.length];
}
type Match = { tier: number; distance: number; corrected: number };
function compareMatch(a: Match, b: Match) {
  return a.tier - b.tier || a.distance - b.distance || a.corrected - b.corrected;
}
function match(app: LauncherApp, query: string, corrected: number): Match | undefined {
  const { names, metadata } = fields(app);
  if (names.some((field) => field.text === query)) return { tier: 0, distance: 0, corrected };
  if (names.some((field) => field.text.startsWith(query)))
    return { tier: 1, distance: 0, corrected };
  const terms = query.split(/\s+/);
  let tier = 0;
  let distance = 0;
  for (const term of terms) {
    if (names.some((field) => field.words.some((word) => word.startsWith(term)))) {
      tier = Math.max(tier, 2);
    } else if (names.some((field) => field.text.includes(term))) {
      tier = Math.max(tier, 3);
    } else if (metadata.includes(term)) {
      tier = Math.max(tier, 4);
    } else if (term.length >= 2 && names.some((field) => field.initials.startsWith(term))) {
      tier = Math.max(tier, 5);
    } else {
      // Short queries are too ambiguous for fuzzy matching. Bound work for pasted text.
      if (term.length < 3 || term.length > 64 || terms.length > 16 || !/^[\p{L}]+$/u.test(term))
        return;
      const limit = term.length < 6 ? 1 : 2;
      let best = limit + 1;
      for (const field of names) {
        for (const word of field.words) {
          // Also tolerate a typo in an unfinished app name (e.g. "safra").
          for (
            let length = Math.max(3, term.length - limit);
            length <= Math.min(word.length, term.length + limit);
            length++
          ) {
            best = Math.min(best, typoDistance(term, word.slice(0, length), limit));
            if (best === 0) break;
          }
        }
      }
      if (best > limit) return;
      tier = 6;
      distance += best;
    }
  }
  return { tier, distance, corrected };
}

export function launcherApps(
  apps: LauncherApp[],
  query: string,
  usage: LauncherUsageStats = {},
): LauncherApp[] {
  const input = query.trim().toLowerCase().replace(/\s+/g, ' ');
  const variants = [normalize(input)];
  if (/[а-яё]/.test(input)) variants.push(normalize(switchLayout(input, russianKeys, latinKeys)));
  if (/[a-z]/.test(input)) variants.push(normalize(switchLayout(input, latinKeys, russianKeys)));
  const unique = [...new Set(variants)];
  return apps
    .flatMap((app) => {
      if (!input) return [{ app, match: { tier: 0, distance: 0, corrected: 0 } }];
      let best: Match | undefined;
      unique.forEach((variant, index) => {
        const candidate = match(app, variant, Number(index > 0));
        if (candidate && (!best || compareMatch(candidate, best) < 0)) best = candidate;
      });
      return best ? [{ app, match: best }] : [];
    })
    .sort(
      (a, b) =>
        (!input ? Number(b.app.kind === 'builtin') - Number(a.app.kind === 'builtin') : 0) ||
        compareMatch(a.match, b.match) ||
        (usage[b.app.id]?.count || 0) - (usage[a.app.id]?.count || 0) ||
        (usage[b.app.id]?.lastLaunchedAt || 0) - (usage[a.app.id]?.lastLaunchedAt || 0) ||
        a.app.name.localeCompare(b.app.name, 'ru') ||
        a.app.id.localeCompare(b.app.id),
    )
    .map(({ app }) => app);
}

export function shortcutLabel(accelerator: string) {
  return accelerator
    .replace('CommandOrControl', navigator.platform.includes('Mac') ? '⌘' : 'Ctrl')
    .replace('Shift', '⇧')
    .replace('Alt', '⌥')
    .replace('Control', 'Ctrl')
    .replace('Space', 'Пробел')
    .split('+')
    .join(' ');
}
