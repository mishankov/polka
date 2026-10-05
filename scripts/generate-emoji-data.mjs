// Run explicitly to update the bundled catalog; application startup never downloads data.
import { mkdir, writeFile } from 'node:fs/promises';

const unicodeVersion = '16.0';
const cldrVersion = 'release-48';
const sources = {
  emoji: `https://www.unicode.org/Public/emoji/${unicodeVersion}/emoji-test.txt`,
  ...Object.fromEntries(
    ['ru', 'en'].flatMap((locale) =>
      ['annotations', 'annotationsDerived'].map((directory) => [
        `${locale}/${directory}`,
        `https://raw.githubusercontent.com/unicode-org/cldr/${cldrVersion}/common/${directory}/${locale}.xml`,
      ]),
    ),
  ),
};
const fetched = await Promise.all(
  Object.entries(sources).map(async ([key, url]) => {
    const response = await fetch(url);
    if (!response.ok) throw Error(`${url}: ${response.status}`);
    return [key, await response.text()];
  }),
);
const files = Object.fromEntries(fetched);
const decode = (text) =>
  text.replace(/&(#x[\da-f]+|#\d+|amp|lt|gt|quot|apos);/gi, (_, entity) => {
    if (entity.startsWith('#'))
      return String.fromCodePoint(
        entity[1] === 'x' ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10),
      );
    return { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }[entity];
  });
const annotationKey = (text) => text.replaceAll('\ufe0f', '');
function annotations(locale) {
  const result = new Map();
  for (const directory of ['annotations', 'annotationsDerived']) {
    for (const match of files[`${locale}/${directory}`].matchAll(
      /<annotation\s+cp="([^"]+)"([^>]*)>([\s\S]*?)<\/annotation>/g,
    )) {
      const key = annotationKey(decode(match[1]));
      const item = result.get(key) || {};
      item[match[2].includes('type="tts"') ? 'name' : 'keywords'] = decode(match[3]).trim();
      result.set(key, item);
    }
  }
  return result;
}
const ru = annotations('ru');
const en = annotations('en');
const groups = [];
const entries = [];
let group = -1;
for (const line of files.emoji.split('\n')) {
  if (line.startsWith('# group: ')) {
    groups.push(line.slice(9));
    group++;
  }
  const match = line.match(/^([\dA-F ]+)\s*; fully-qualified\s*# \S+ E[\d.]+ (.+)$/);
  if (!match) continue;
  const emoji = String.fromCodePoint(
    ...match[1]
      .trim()
      .split(/\s+/)
      .map((hex) => parseInt(hex, 16)),
  );
  const key = annotationKey(emoji);
  const russian = ru.get(key);
  const english = en.get(key);
  if (!russian?.name || !english?.name) throw Error(`Missing localized name: ${emoji}`);
  entries.push([
    emoji,
    group,
    russian.name,
    english.name,
    russian.keywords || '',
    english.keywords || '',
  ]);
}
const output = new URL('../src/shared/emoji-data.json', import.meta.url);
await mkdir(new URL('../src/shared/', import.meta.url), { recursive: true });
await writeFile(
  output,
  JSON.stringify({ unicodeVersion, cldrVersion, sources, groups }, null, 2).slice(0, -2) +
    ',\n  "entries": [\n' +
    entries.map((entry) => '    ' + JSON.stringify(entry)).join(',\n') +
    '\n  ]\n}\n',
);
console.log(`Bundled ${entries.length} emoji (${unicodeVersion}, ${cldrVersion}).`);
