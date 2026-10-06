import type { Calculation, CalculationContext } from './calculator';

type Zone = { id: string; label: string; offset?: number };
const cities = new Map<string, Zone>();
function city(id: string, label: string, names: string) {
  for (const name of names.split('|')) cities.set(name, { id, label });
}
city('Europe/Moscow', 'Москва', 'moscow|москва|москве|msk|мск');
city('Europe/London', 'Лондон', 'london|лондон|лондоне');
city('Europe/Paris', 'Париж', 'paris|париж|париже');
city('Europe/Berlin', 'Берлин', 'berlin|берлин|берлине');
city('Europe/Rome', 'Рим', 'rome|рим|риме');
city('Europe/Madrid', 'Мадрид', 'madrid|мадрид|мадриде');
city('Europe/Helsinki', 'Хельсинки', 'helsinki|хельсинки');
city('Europe/Istanbul', 'Стамбул', 'istanbul|стамбул|стамбуле');
city('Asia/Dubai', 'Дубай', 'dubai|дубай|дубае');
city('Asia/Tbilisi', 'Тбилиси', 'tbilisi|тбилиси');
city('Asia/Yerevan', 'Ереван', 'yerevan|ереван|ереване');
city('Asia/Yekaterinburg', 'Екатеринбург', 'yekaterinburg|екатеринбург|екатеринбурге');
city('Asia/Novosibirsk', 'Новосибирск', 'novosibirsk|новосибирск|новосибирске');
city('Asia/Vladivostok', 'Владивосток', 'vladivostok|владивосток|владивостоке');
city('America/New_York', 'Нью-Йорк', 'new york|new-york|nyc|нью-йорк|нью-йорке');
city('America/Los_Angeles', 'Лос-Анджелес', 'los angeles|los-angeles|лос-анджелес|лос-анджелесе');
city('America/Chicago', 'Чикаго', 'chicago|чикаго');
city('America/Toronto', 'Торонто', 'toronto|торонто');
city('America/Sao_Paulo', 'Сан-Паулу', 'sao paulo|são paulo|сан-паулу');
city('Asia/Tokyo', 'Токио', 'tokyo|токио');
city('Asia/Shanghai', 'Шанхай', 'shanghai|шанхай|шанхае');
city('Asia/Hong_Kong', 'Гонконг', 'hong kong|гонконг|гонконге');
city('Asia/Singapore', 'Сингапур', 'singapore|сингапур|сингапуре');
city('Asia/Kolkata', 'Калькутта', 'kolkata|калькутта|калькутте');
city('Australia/Sydney', 'Сидней', 'sydney|сидней|сиднее');
city('Pacific/Auckland', 'Окленд', 'auckland|окленд|окленде');

const formatters = new Map<string, Intl.DateTimeFormat>();
function formatter(zone: string) {
  let result = formatters.get(zone);
  if (!result) {
    result = new Intl.DateTimeFormat('en-GB', {
      timeZone: zone,
      calendar: 'iso8601',
      numberingSystem: 'latn',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
    });
    // Bound the cache even when users type many IANA identifiers.
    if (formatters.size >= 64) formatters.delete(formatters.keys().next().value!);
    formatters.set(zone, result);
  }
  return result;
}

function resolveZone(name: string): Zone | string {
  name = name.replace(/−/g, '-');
  const normalized = name.toLowerCase().replace(/\s+/g, ' ');
  const named = cities.get(normalized);
  if (named) return named;
  const fixed = /^(?:utc|gmt)(?:([+-])(\d{1,2})(?::?(\d{2}))?(?::(\d{2}))?)?$/i.exec(name);
  if (fixed) {
    const hours = Number(fixed[2] || 0);
    const minutes = Number(fixed[3] || 0);
    const seconds = Number(fixed[4] || 0);
    if (
      hours > 14 ||
      minutes > 59 ||
      seconds > 59 ||
      (hours === 14 && (minutes !== 0 || seconds !== 0))
    )
      return 'Укажите смещение от UTC−14:00 до UTC+14:00';
    const offset = (fixed[1] === '-' ? -1 : 1) * (hours * 3600 + minutes * 60 + seconds) * 1000;
    const label = offsetLabel(offset);
    return { id: label, label, offset };
  }
  if (/^[a-zа-я]{2,5}$/i.test(name))
    return `Неоднозначный или неизвестный часовой пояс «${name}». Укажите город, например London, Europe/London или UTC+01:00.`;
  if (name.includes('/')) {
    try {
      const id = formatter(name).resolvedOptions().timeZone;
      return { id, label: name };
    } catch {
      // Unknown identifiers stay a visible error rather than using the device zone.
    }
  }
  return `Неизвестный часовой пояс «${name}». Укажите город, IANA-пояс или UTC±HH:MM.`;
}

function parts(instant: number, zone: Zone) {
  if (zone.offset !== undefined) {
    const date = new Date(instant + zone.offset);
    return [
      date.getUTCFullYear(),
      date.getUTCMonth() + 1,
      date.getUTCDate(),
      date.getUTCHours(),
      date.getUTCMinutes(),
      date.getUTCSeconds(),
    ];
  }
  const values = Object.fromEntries(
    formatter(zone.id)
      .formatToParts(instant)
      .map((part) => [part.type, part.value]),
  );
  return ['year', 'month', 'day', 'hour', 'minute', 'second'].map((key) => Number(values[key]));
}
const stamp = (values: number[]) =>
  Date.UTC(values[0], values[1] - 1, values[2], values[3] || 0, values[4] || 0, values[5] || 0);
const pad = (value: number) => String(value).padStart(2, '0');
const dateLabel = (values: number[]) =>
  `${String(values[0]).padStart(4, '0')}-${pad(values[1])}-${pad(values[2])}`;
const timeLabel = (values: number[]) =>
  `${pad(values[3])}:${pad(values[4])}${values[5] ? `:${pad(values[5])}` : ''}`;
function offsetLabel(offset: number) {
  const seconds = Math.round(Math.abs(offset) / 1000);
  const minutes = Math.floor(seconds / 60);
  return `UTC${offset < 0 ? '−' : '+'}${pad(Math.floor(minutes / 60))}:${pad(minutes % 60)}${seconds % 60 ? `:${pad(seconds % 60)}` : ''}`;
}

function parseDate(value: string): number[] | undefined {
  const iso = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  const russian = /^(\d{2})\.(\d{2})\.(\d{4})$/.exec(value);
  const values = iso
    ? iso.slice(1).map(Number)
    : russian
      ? russian.slice(1).reverse().map(Number)
      : undefined;
  if (!values || values[0] < 1900 || values[0] > 9999) return undefined;
  const date = new Date(stamp(values));
  return date.getUTCFullYear() === values[0] &&
    date.getUTCMonth() + 1 === values[1] &&
    date.getUTCDate() === values[2]
    ? values
    : undefined;
}

/** Resolve a wall time by testing nearby zone offsets, rejecting gaps and overlaps. */
function instants(wall: number[], zone: Zone): number[] {
  const wanted = stamp(wall);
  if (zone.offset !== undefined) return [wanted - zone.offset];
  const offsets = new Set<number>();
  // Covers large date-line shifts as well as 30-minute and one-hour DST transitions.
  for (let hour = -48; hour <= 48; hour += 6) {
    const instant = wanted + hour * 3600000;
    offsets.add(stamp(parts(instant, zone)) - instant);
  }
  return [...offsets]
    .map((offset) => wanted - offset)
    .filter((instant) => stamp(parts(instant, zone)) === wanted)
    .sort((a, b) => a - b);
}

export function convertTimeZones(
  expression: string,
  context: CalculationContext,
): Calculation | undefined {
  // Accept a date before the time or after the destination; omit it for today in the source zone.
  const datePattern = '(?:\\d{4}-\\d{2}-\\d{2}|\\d{2}\\.\\d{2}\\.\\d{4})';
  const match = new RegExp(
    `^(?:(${datePattern})\\s+)?(\\d{1,2}):(\\d{2})\\s+(.+?)\\s+(?:in|to|в)(?:\\s+|$)(.*)$`,
    'i',
  ).exec(expression);
  if (!match) return undefined;
  if (expression.length > 512)
    return { status: 'error', expression, message: 'Слишком длинное выражение' };
  const [, prefixDate, rawHour, rawMinute, rawSource, rawDestination] = match;
  const incomplete = (message: string): Calculation => ({
    status: 'incomplete',
    expression,
    message,
  });
  const error = (message: string): Calculation => ({ status: 'error', expression, message });
  if (!rawDestination.trim())
    return incomplete('Укажите часовой пояс результата, например: 18:00 Moscow in London');
  const suffix = new RegExp(`\\s+(?:(?:on|на)\\s+)?(${datePattern})$`, 'i').exec(rawDestination);
  const destination = (suffix ? rawDestination.slice(0, suffix.index) : rawDestination).trim();
  if (prefixDate && suffix)
    return error('Укажите дату один раз: перед временем или в конце запроса');
  if (!destination) return incomplete('Укажите часовой пояс результата');
  const source = resolveZone(rawSource.trim());
  const target = resolveZone(destination);
  if (typeof source === 'string') return error(source);
  if (typeof target === 'string') return error(target);
  const hour = Number(rawHour);
  const minute = Number(rawMinute);
  if (hour > 23 || minute > 59) return error('Укажите время от 00:00 до 23:59');
  const explicitDate = prefixDate || suffix?.[1];
  const requestedDate = explicitDate || context.sourceDate;
  let date: number[];
  if (requestedDate) {
    const parsed = parseDate(requestedDate);
    if (!parsed)
      return error('Укажите существующую дату с 1900 по 9999 год: YYYY-MM-DD или DD.MM.YYYY');
    date = parsed;
  } else {
    const now = context.now || new Date();
    if (!Number.isFinite(now.getTime())) return error('Не удалось определить сегодняшнюю дату');
    date = parts(now.getTime(), source).slice(0, 3);
    if (date[0] < 1900 || date[0] > 9999)
      return error('Дата вне поддерживаемого диапазона: 1900–9999');
  }
  const wall = [...date, hour, minute, 0];
  const matches = instants(wall, source);
  if (!matches.length)
    return error('Такого местного времени нет из-за перевода часов. Выберите другое время.');
  if (matches.length > 1) {
    const offsets = matches.map((instant) => offsetLabel(stamp(wall) - instant)).join(' или ');
    return error(
      `Это местное время встречается дважды из-за перевода часов. Вместо ${source.label} укажите ${offsets}.`,
    );
  }
  const instant = matches[0];
  const converted = parts(instant, target);
  if (converted[0] < 1900 || converted[0] > 9999)
    return error('Дата результата вне поддерживаемого диапазона: 1900–9999');
  const days = Math.round((stamp(converted.slice(0, 3)) - stamp(date)) / 86400000);
  const dayOffset = days ? ` · ${days > 0 ? '+' : '−'}${Math.abs(days)} дн.` : ' · тот же день';
  const sourceDate = dateLabel(date);
  const targetOffset = target.offset ?? stamp(converted) - instant;
  return {
    status: 'result',
    expression,
    conversion: 'time-zone',
    sourceDate,
    value: `${timeLabel(converted)} · ${dateLabel(converted)} · ${target.label} (${offsetLabel(targetOffset)})`,
    displayValue: `${timeLabel(converted)} ${target.label}`,
    interpretation: `${sourceDate}${explicitDate ? '' : ' (сегодня в исходном поясе)'} · ${pad(hour)}:${pad(minute)} ${source.label} → ${dateLabel(converted)} ${target.label} (${offsetLabel(targetOffset)})${dayOffset}`,
  };
}
