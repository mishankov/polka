import type { Calculation } from './calculator';

type Unit = {
  symbol: string;
  dimension: 'length' | 'mass' | 'temperature' | 'duration';
  scale: number;
  offset: number;
  aliases: string[];
};

const units: Unit[] = [];
function unit(
  dimension: Unit['dimension'],
  symbol: string,
  scale: number,
  aliases: string,
  offset = 0,
) {
  units.push({ dimension, symbol, scale, offset, aliases: [symbol, ...aliases.split('|')] });
}

unit(
  'length',
  'mm',
  0.001,
  'millimeter|millimeters|millimetre|millimetres|мм|миллиметр|миллиметра|миллиметров|миллиметры',
);
unit(
  'length',
  'cm',
  0.01,
  'centimeter|centimeters|centimetre|centimetres|см|сантиметр|сантиметра|сантиметров|сантиметры',
);
unit('length', 'm', 1, 'meter|meters|metre|metres|м|метр|метра|метров|метры');
unit(
  'length',
  'km',
  1000,
  'kilometer|kilometers|kilometre|kilometres|км|километр|километра|километров|километры',
);
unit('length', 'in', 0.0254, 'inch|inches|дюйм|дюйма|дюймов|дюймы|"|″');
unit('length', 'ft', 0.3048, "foot|feet|фут|фута|футов|футы|'|′");
unit('length', 'yd', 0.9144, 'yard|yards|ярд|ярда|ярдов|ярды');
unit('length', 'mi', 1609.344, 'mile|miles|миля|мили|миль');
unit(
  'mass',
  'mg',
  0.000001,
  'milligram|milligrams|мг|миллиграмм|миллиграмма|миллиграммов|миллиграммы',
);
unit('mass', 'g', 0.001, 'gram|grams|г|грамм|грамма|граммов|граммы');
unit('mass', 'kg', 1, 'kilogram|kilograms|кг|килограмм|килограмма|килограммов|килограммы');
unit('mass', 't', 1000, 'tonne|tonnes|metric ton|metric tons|т|тонна|тонны|тонн');
unit('mass', 'oz', 0.028349523125, 'ounce|ounces|унция|унции|унций');
unit('mass', 'lb', 0.45359237, 'lbs|pound|pounds|фунт|фунта|фунтов|фунты');
unit('duration', 'ms', 0.001, 'millisecond|milliseconds|мс|миллисекунда|миллисекунды|миллисекунд');
unit('duration', 's', 1, 'sec|secs|second|seconds|с|сек|секунда|секунды|секунд');
unit('duration', 'min', 60, 'mins|minute|minutes|мин|минута|минуты|минут');
unit('duration', 'h', 3600, 'hr|hrs|hour|hours|ч|час|часа|часов|часы');
unit('duration', 'd', 86400, 'day|days|д|день|дня|дней|дни|сутки|суток');
unit('duration', 'wk', 604800, 'week|weeks|нед|неделя|недели|недель');
unit(
  'temperature',
  '°C',
  1,
  'c|°c|celsius|degree celsius|degrees celsius|цельсий|цельсия|°с|с',
  273.15,
);
unit(
  'temperature',
  '°F',
  5 / 9,
  'f|°f|fahrenheit|degree fahrenheit|degrees fahrenheit|фаренгейт|фаренгейта',
  273.15 - (32 * 5) / 9,
);
unit('temperature', 'K', 1, 'kelvin|kelvins|к|кельвин|кельвина|кельвинов');

const normalize = (name: string) =>
  name.trim().toLowerCase().replace(/\s+/g, ' ').replace(/\.$/, '');

// Enumerate real noun forms rather than stripping arbitrary suffixes from queries.
const russianCases = new Map<string, string[]>();
function noun(symbol: string, stem: string, endings: string) {
  russianCases.set(symbol, [
    ...(russianCases.get(symbol) || []),
    ...endings.split('|').map((ending) => stem + ending),
  ]);
}
const masculine = '|а|у|ом|е|ы|ов|ам|ами|ах';
for (const [symbol, stem] of [
  ['mm', 'миллиметр'],
  ['cm', 'сантиметр'],
  ['m', 'метр'],
  ['km', 'километр'],
  ['in', 'дюйм'],
  ['ft', 'фут'],
  ['yd', 'ярд'],
  ['mg', 'миллиграмм'],
  ['g', 'грамм'],
  ['kg', 'килограмм'],
  ['lb', 'фунт'],
  ['h', 'час'],
  ['K', 'кельвин'],
  ['°F', 'фаренгейт'],
])
  noun(symbol, stem, masculine);
const feminine = 'а|ы|е|у|ой|ою||ам|ами|ах';
for (const [symbol, stem] of [
  ['t', 'тонн'],
  ['ms', 'миллисекунд'],
  ['s', 'секунд'],
  ['min', 'минут'],
])
  noun(symbol, stem, feminine);
noun('mi', 'мил', 'я|и|е|ю|ей|ею|ь|ям|ями|ях');
noun('oz', 'унци', 'я|и|ю|ей|ею|й|ям|ями|ях');
noun('wk', 'недел', 'я|и|е|ю|ей|ею|ь|ям|ями|ях');
noun(
  'd',
  '',
  'день|дня|дню|днём|днем|дне|дни|дней|дням|днями|днях|сутки|суток|суткам|сутками|сутках',
);
noun('°C', 'цельси', 'й|я|ю|ем|и');
for (const [symbol, scale] of [
  ['°C', 'цельсия'],
  ['°F', 'фаренгейта'],
])
  noun(
    symbol,
    '',
    masculine
      .split('|')
      .map((ending) => `градус${ending} ${scale}`)
      .join('|'),
  );
const aliases = new Map<string, Unit[]>();
for (const item of units)
  for (const alias of new Set(
    [...item.aliases, ...(russianCases.get(item.symbol) || [])].map(normalize),
  ))
    aliases.set(alias, [...(aliases.get(alias) || []), item]);

// These names have incompatible common meanings; require an explicit alias.
const ambiguous = new Set(['ton', 'tons', 'тн', 'month', 'months', 'месяц', 'месяца', 'месяцев']);

export function convertUnits(expression: string): Calculation | undefined {
  // Bound numeric-regex backtracking for long pasted search queries.
  if (expression.length > 512)
    return /^[+−-]?(?:\d|[.,]\d)/.test(expression) && /\s(?:in|to|в)(?:\s|$)/i.test(expression)
      ? { status: 'error', expression, message: 'Слишком длинное выражение' }
      : undefined;
  const match =
    /^([+−-]?(?:\d+(?:[.,]\d*)?|[.,]\d+)(?:e[+-]?\d+)?)\s*(.+?)\s+(?:in|to|в)(?:\s+|$)(.*)$/i.exec(
      expression,
    );
  if (!match) return undefined;
  const [, rawValue, rawSource, rawTarget] = match;
  const sourceName = normalize(rawSource);
  const targetName = normalize(rawTarget);
  let source = aliases.get(sourceName);
  let target = aliases.get(targetName);
  if (!source && !target && !ambiguous.has(sourceName) && !ambiguous.has(targetName))
    return undefined;
  if (!targetName)
    return {
      status: 'incomplete',
      expression,
      message: 'Укажите единицу результата, например: 10 inches in cm',
    };
  // A shared alias such as Russian «с» can be resolved by the other unit's dimension.
  if (source && target) {
    const pairs = source.flatMap((from) =>
      target!.filter((to) => to.dimension === from.dimension).map((to) => [from, to]),
    );
    if (pairs.length === 1) {
      source = [pairs[0][0]];
      target = [pairs[0][1]];
    }
  }
  if (
    ambiguous.has(sourceName) ||
    ambiguous.has(targetName) ||
    (source && source.length > 1) ||
    (target && target.length > 1)
  )
    return {
      status: 'error',
      expression,
      message:
        'Неоднозначная единица. Уточните: m — метры, s — секунды, °C — температура, tonne — метрическая тонна. Месяцы не имеют постоянной длительности.',
    };
  if (!source || !target)
    return {
      status: 'error',
      expression,
      message: `Неизвестная единица: ${!source ? rawSource : rawTarget}. Поддерживаются длина, масса, температура и длительность.`,
    };
  const from = source[0];
  const to = target[0];
  if (from.dimension !== to.dimension)
    return {
      status: 'error',
      expression,
      message: 'Выберите единицы одной величины: например, длину в длину.',
    };
  const amount = Number(rawValue.replace(',', '.').replace('−', '-'));
  const absoluteZero = from.symbol === '°C' ? -273.15 : from.symbol === '°F' ? -459.67 : 0;
  // Convert like units directly to avoid losing tiny temperature differences to the offset.
  let base = amount * from.scale + from.offset;
  if (from.dimension === 'temperature' && amount < absoluteZero)
    return { status: 'error', expression, message: 'Температура ниже абсолютного нуля' };
  if (from.dimension === 'temperature' && base < 0) base = 0;
  const converted = from === to ? amount : (base - to.offset) / to.scale;
  if (!Number.isFinite(amount) || !Number.isFinite(converted))
    return { status: 'error', expression, message: 'Результат вне допустимого диапазона' };
  const value = String(Number(converted.toPrecision(12)));
  return {
    status: 'result',
    expression,
    value: `${value} ${to.symbol}`,
    conversion: 'unit',
    interpretation: `${String(amount)} ${from.symbol} → ${to.symbol}`,
  };
}
