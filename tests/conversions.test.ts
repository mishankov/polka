import test from 'node:test';
import assert from 'node:assert/strict';
import { calculate, type CalculationContext } from '../src/shared/calculator';
import { shelfSearch } from '../src/shared/shelf-search';

const now = new Date('2026-07-15T12:00:00Z');
function result(query: string, context: CalculationContext = { now }) {
  const calculation = calculate(query, context);
  assert.equal(calculation?.status, 'result', `${query}: ${JSON.stringify(calculation)}`);
  if (calculation?.status !== 'result') throw Error('Missing result');
  return calculation;
}
function error(query: string, message: RegExp) {
  const calculation = calculate(query, { now });
  assert.equal(calculation?.status, 'error', query);
  if (calculation?.status === 'error') assert.match(calculation.message, message, query);
}

test('unit conversions cover all dimensions, both languages, decimals and exact imperial definitions', () => {
  for (const [query, value] of [
    ['10 inches in cm', '25.4 cm'],
    ['10 дюймов в сантиметры', '25.4 cm'],
    ['1,5 км в м', '1500 m'],
    ['.5 m to mm', '500 mm'],
    ['2,5kg in g', '2500 g'],
    ['1 foot in inches', '12 in'],
    ['1 yard in ft', '3 ft'],
    ['1 mi in km', '1.609344 km'],
    ['1 lb in kg', '0.45359237 kg'],
    ['16 oz in lb', '1 lb'],
    ['1 metric ton in kg', '1000 kg'],
    ['1 тонна в кг', '1000 kg'],
    ['1 mg in g', '0.001 g'],
    ['90 min in hours', '1.5 h'],
    ['90 минут в часы', '1.5 h'],
    ['1 day in h', '24 h'],
    ['1 неделя в дни', '7 d'],
    ['1 second in ms', '1000 ms'],
    ['0 °C in °F', '32 °F'],
    ['32 F in C', '0 °C'],
    ['100 celsius to fahrenheit', '212 °F'],
    ['273,15 K в цельсия', '0 °C'],
    ['0 K in °F', '-459.67 °F'],
    ['-40 c in f', '-40 °F'],
    ['−40 C in F', '-40 °F'],
    ['-273.15 c in k', '0 K'],
    ['-459.67 f in k', '0 K'],
    ['-2 m in cm', '-200 cm'],
    ['-0 m in cm', '0 cm'],
    ['1e3 m in km', '1 km'],
    ['1e-20 c in c', '1e-20 °C'],
    ['  10 CM IN M  ', '0.1 m'],
    ['1 с в мин', '0.0166666666667 min'],
    ['0 с в °F', '32 °F'],
  ]) {
    const calculation = result(query);
    assert.equal(calculation.value, value, query);
    assert.equal(calculation.conversion, 'unit');
    assert.match(calculation.interpretation!, / → /);
  }
});

test('Russian unit queries accept grammatical case forms without guessing unknown words', () => {
  for (const [query, value] of [
    ['100 метров в сантиметрах', '10000 cm'],
    ['100 метров в сантиметра', '10000 cm'],
    ['100 сантиметров в метрах', '1 m'],
    ['1 км в миллиметрах', '1000000 mm'],
    ['1000 м в километрах', '1 km'],
    ['1 ft в дюймах', '12 in'],
    ['1 yd в футах', '3 ft'],
    ['3 ft в ярдах', '1 yd'],
    ['1609,344 м в милях', '1 mi'],
    ['1 г в миллиграммах', '1000 mg'],
    ['1 кг в граммах', '1000 g'],
    ['1000 г в килограммах', '1 kg'],
    ['1000 кг в тоннах', '1 t'],
    ['1 lb в унциях', '16 oz'],
    ['16 oz в фунтах', '1 lb'],
    ['1 с в миллисекундах', '1000 ms'],
    ['1 мин в секундах', '60 s'],
    ['1 ч в минутах', '60 min'],
    ['90 минут в часах', '1.5 h'],
    ['48 ч в днях', '2 d'],
    ['48 ч в сутках', '2 d'],
    ['14 дней в неделях', '2 wk'],
    ['0 °C в кельвинах', '273.15 K'],
    ['32 °F в градусах Цельсия', '0 °C'],
    ['0 градусов Цельсия в градусах Фаренгейта', '32 °F'],
    ['1 метром в сантиметрах', '100 cm'],
  ])
    assert.equal(result(query).value, value, query);
  error('100 метров в сантиметрологиях', /Неизвестная единица/);
  assert.equal(calculate('100 документов в папках'), undefined);
});

test('unit errors explain incompatible, ambiguous, unsupported and out-of-range inputs', () => {
  error('10 kg in cm', /одной величины/);
  error('1 ton in kg', /Неоднозначная/);
  error('1 month in days', /постоянной длительности/);
  error('1 с в с', /Неоднозначная/);
  error('1 m in furlongs', /Неизвестная единица/);
  error('1 furlong in m', /Неизвестная единица/);
  error('-1 K in C', /абсолютного нуля/);
  error('-1e-11 K in K', /абсолютного нуля/);
  error('-274 C in F', /абсолютного нуля/);
  error('1e309 m in cm', /диапазона/);
  error('1e308 km in mm', /диапазона/);
  error(`1 m in ${'m'.repeat(600)}`, /длинное/);
  assert.equal(calculate('1'.repeat(10000)), undefined);
  const incomplete = calculate('10 inches in');
  assert.equal(incomplete?.status, 'incomplete');
  if (incomplete?.status === 'incomplete') assert.match(incomplete.message!, /единицу результата/);
});

test('time conversion uses summer and winter offsets for the requested date', () => {
  const summer = result('2026-07-15 18:00 Moscow in London');
  assert.equal(summer.value, '16:00 · 2026-07-15 · Лондон (UTC+01:00)');
  assert.match(summer.interpretation!, /2026-07-15 · 18:00 Москва → .*тот же день/);
  assert.doesNotMatch(summer.interpretation!, /сегодня/);
  assert.equal(
    result('2026-01-15 18:00 Moscow in London').value,
    '15:00 · 2026-01-15 · Лондон (UTC+00:00)',
  );
  assert.equal(
    result('18:00 Москва в Лондоне 15.01.2026').value,
    '15:00 · 2026-01-15 · Лондон (UTC+00:00)',
  );
  assert.equal(
    result('18:00 Europe/Moscow to Europe/London on 2026-07-15').value,
    '16:00 · 2026-07-15 · Europe/London (UTC+01:00)',
  );
  assert.equal(
    result('18:00 мск в UTC на 2026-07-15').value,
    '15:00 · 2026-07-15 · UTC+00:00 (UTC+00:00)',
  );
});

test('omitted dates mean today in the source zone, independent of device zone and copy time', () => {
  const context = { now: new Date('2026-01-01T01:00:00Z') };
  const calculation = result('18:00 New York in Tokyo', context);
  assert.equal(calculation.sourceDate, '2025-12-31');
  assert.equal(calculation.value, '08:00 · 2026-01-01 · Токио (UTC+09:00)');
  assert.match(calculation.interpretation!, /сегодня в исходном поясе/);
  assert.match(calculation.interpretation!, /\+1 дн/);
  assert.equal(
    result(calculation.expression, {
      now: new Date('2026-01-02T12:00:00Z'),
      sourceDate: calculation.sourceDate,
    }).value,
    calculation.value,
  );
  assert.equal(
    result('2026-07-15 18:00 Moscow in London', { sourceDate: '2026-01-15' }).sourceDate,
    '2026-07-15',
  );
});

test('time conversion supports fractional offsets and forward/backward date rollover', () => {
  assert.equal(
    result('1900-01-01 18:00 UTC in Europe/Moscow').value,
    '20:30:17 · 1900-01-01 · Europe/Moscow (UTC+02:30:17)',
  );
  assert.equal(
    result('1900-01-01 18:00 UTC+02:30:17 in UTC').value,
    '15:29:43 · 1900-01-01 · UTC+00:00 (UTC+00:00)',
  );
  assert.equal(
    result('2026-07-15 18:00 UTC in Asia/Kathmandu').value,
    '23:45 · 2026-07-15 · Asia/Kathmandu (UTC+05:45)',
  );
  assert.equal(
    result('2026-07-15 18:00 UTC in UTC+05:30').value,
    '23:30 · 2026-07-15 · UTC+05:30 (UTC+05:30)',
  );
  assert.equal(
    result('2026-07-15 18:00 UTC+0530 in UTC').value,
    '12:30 · 2026-07-15 · UTC+00:00 (UTC+00:00)',
  );
  const previous = result('2026-01-01 01:00 Tokyo in New York');
  assert.equal(previous.value, '11:00 · 2025-12-31 · Нью-Йорк (UTC−05:00)');
  assert.match(previous.interpretation!, /−1 дн/);
  const twoDays = result('2026-12-31 23:30 UTC-12 in UTC+14');
  assert.match(twoDays.value, /01:30 · 2027-01-02/);
  assert.match(twoDays.interpretation!, /\+2 дн/);
  assert.equal(
    result('2026-07-15 18:00 UTC−04:00 in UTC').value,
    '22:00 · 2026-07-15 · UTC+00:00 (UTC+00:00)',
  );
});

test('DST gaps and repeated local times are rejected, including non-hour and date-line transitions', () => {
  error('2026-03-08 02:30 New York in UTC', /Такого местного времени нет/);
  error('2026-11-01 01:30 New York in UTC', /дважды.*UTC−04:00.*UTC−05:00/);
  error('2026-03-29 01:30 London in UTC', /Такого местного времени нет/);
  error('2026-10-25 01:30 London in UTC', /дважды/);
  error('2026-10-04 02:15 Australia/Lord_Howe in UTC', /Такого местного времени нет/);
  error('2026-04-05 01:45 Australia/Lord_Howe in UTC', /дважды/);
  error('2011-12-30 12:00 Pacific/Apia in UTC', /Такого местного времени нет/);
  assert.match(result('2026-03-08 01:59 New York in UTC').value, /^06:59/);
  assert.match(result('2026-03-08 03:00 New York in UTC').value, /^07:00/);
  assert.match(result('2026-11-01 01:30 UTC-04:00 in UTC').value, /^05:30/);
  assert.match(result('2026-11-01 01:30 UTC-05:00 in UTC').value, /^06:30/);
});

test('invalid clocks, dates, zones and ambiguous abbreviations have clear errors', () => {
  error('2026-02-29 18:00 Moscow in London', /существующую дату/);
  error('2026-04-31 18:00 Moscow in London', /существующую дату/);
  error('1899-12-31 18:00 Moscow in London', /1900/);
  assert.match(result('2024-02-29 18:00 UTC in UTC').value, /2024-02-29/);
  error('24:00 Moscow in London', /00:00 до 23:59/);
  error('18:60 Moscow in London', /00:00 до 23:59/);
  error('18:00 CST in London', /Неоднозначный/);
  error('18:00 Moscow in IST', /Неоднозначный/);
  error('18:00 Springfield in London', /Неизвестный/);
  error('18:00 Europe/Nowhere in London', /Неизвестный/);
  error('18:00 UTC+15 in London', /смещение/);
  error('18:00 UTC+14:01 in London', /смещение/);
  error('18:00 UTC-05:60 in London', /смещение/);
  error('2026-01-15 18:00 Moscow in London 2026-01-16', /дату один раз/);
  assert.equal(calculate('18:00 Moscow in')?.status, 'incomplete');
  assert.equal(calculate('18:00 Moscow in London', { sourceDate: '2026-02-30' })?.status, 'error');
  assert.equal(calculate('18:00 Moscow in London', { now: new Date(NaN) })?.status, 'error');
});

test('conversions rank first while literal app and clipboard search and arithmetic remain available', () => {
  const query = '10 inches in cm';
  const app = { kind: 'mac' as const, id: 'mac:converter', name: query, icon: '', description: '' };
  const clip = {
    id: 'clip',
    kind: 'text' as const,
    content: query,
    preview: query,
    createdAt: 0,
    pinned: false,
  };
  const search = shelfSearch([app], [clip], query);
  assert.deepEqual(
    search.results.map((row) => row.kind),
    ['calculation', 'app', 'clip'],
  );
  assert.deepEqual(shelfSearch([app], [clip], '1 m in kg').results, []);
  assert.equal(
    shelfSearch([], [], '18:00 Moscow in London', {}, { now }).calculation?.status,
    'result',
  );
  for (const query of [
    'Safari',
    '1Password',
    '42',
    '10 notes in Safari',
    'meet in London',
    'https://example.com',
    '18:00 meeting notes',
  ])
    assert.equal(calculate(query), undefined, query);
  assert.equal(result('0.1 + 0.2').value, '0.3');
  assert.equal(calculate('12 +')?.status, 'incomplete');
});
