import { XMLParser, XMLBuilder, XMLValidator } from 'fast-xml-parser';
import iconv from 'iconv-lite';
import { isPngImage, transformImage } from './imageTransforms';
import { decodeBase64 as base64 } from './base64';
export const transforms = [
  ['base64.encode', 'Текст → Base64', 'text', 'text'],
  ['base64.decode', 'Base64 → текст', 'text', 'text'],
  ['hex.encode', 'Текст → hex', 'text', 'text'],
  ['hex.decode', 'Hex → текст', 'text', 'text'],
  ['bytes.hex', 'Байты → hex', 'bytes', 'text'],
  ['hex.bytes', 'Hex → байты', 'text', 'bytes'],
  ['json.parse', 'Разобрать JSON', 'text', 'data'],
  ['json.stringify', 'Данные → JSON', 'data', 'text'],
  ['xml.parse', 'Разобрать XML', 'text', 'data'],
  ['bytes.base64', 'Байты → Base64', 'bytes', 'text'],
  ['base64.bytes', 'Base64 → байты', 'text', 'bytes'],
  ['url.encode', 'URL: кодировать', 'text', 'text'],
  ['url.decode', 'URL: декодировать', 'text', 'text'],
  ['json.format', 'Форматировать JSON', 'text', 'text'],
  ['json.validate', 'Проверить JSON', 'text', 'data'],
  ['xml.format', 'Форматировать XML', 'text', 'text'],
  ['xml.validate', 'Проверить XML', 'text', 'data'],
  ['xml.json', 'XML → JSON', 'text', 'text'],
  ['json.xml', 'JSON → XML', 'text', 'text'],
  ['text.encoding', 'Преобразовать кодировку', 'bytes', 'bytes'],
  ['text.lines', 'Изменить окончания строк', 'text', 'text'],
  ['image.decodePng', 'Байты PNG → изображение', 'bytes', 'image'],
  ['image.encodePng', 'Изображение → байты PNG', 'image', 'bytes'],
  ['image.crop', 'Изображение: обрезать', 'image', 'image'],
  ['image.resize', 'Изображение: изменить размер', 'image', 'image'],
  ['image.rotate', 'Изображение: повернуть', 'image', 'image'],
  ['image.flip', 'Изображение: отразить', 'image', 'image'],
].map(([id, name, input, output]) => ({
  id,
  name,
  input,
  output,
  ...(id.startsWith('image.')
    ? {
        warning:
          'Только статический PNG до 8 бит, без чересстрочной развёртки: до 8192 пикселей по стороне, 16 мегапикселей и 12 МБ. Выход — RGBA 8 бит; метаданные и цветовые профили не сохраняются. Изменение размера использует ближайший пиксель.',
      }
    : {}),
  ...(id === 'xml.json' || id === 'json.xml'
    ? {
        warning:
          'Атрибуты: @_, текст: #text. Повторяющиеся элементы становятся массивами; комментарии, смешанный текст и порядок могут измениться. Обратимость не гарантируется.',
      }
    : {}),
}));

function xml(s: string) {
  if (/<!\s*(DOCTYPE|ENTITY)/i.test(s)) throw Error('DTD и внешние сущности XML запрещены');
  const ok = XMLValidator.validate(s);
  if (ok !== true) throw Error(`XML: строка ${ok.err.line}: ${ok.err.msg}`);
  return new XMLParser({
    ignoreAttributes: false,
    processEntities: false,
    preserveOrder: false,
  }).parse(s);
}
export function runTransform(operation: string, input: unknown, options: Record<string, any> = {}) {
  if (JSON.stringify(input)?.length > 16 * 1024 * 1024)
    throw Error('Максимальный размер преобразования — 16 МБ');
  const definition = transforms.find((t) => t.id === operation);
  if (!definition) throw Error('Преобразование не зарегистрировано');
  if (definition.input === 'text' && typeof input !== 'string') throw Error('Ожидается текст');
  if (
    definition.input === 'bytes' &&
    (!Array.isArray(input) || input.some((x) => !Number.isInteger(x) || x < 0 || x > 255))
  )
    throw Error('Ожидается массив байтов');
  if (definition.input === 'image' && !isPngImage(input)) throw Error('Ожидается изображение PNG');
  const s = typeof input === 'string' ? input : '';
  let output: unknown;
  switch (operation) {
    case 'base64.encode':
      output = Buffer.from(s, 'utf8').toString('base64');
      break;
    case 'base64.decode':
      output = new TextDecoder('utf-8', { fatal: true }).decode(base64(s));
      break;
    case 'bytes.base64':
      if (!Array.isArray(input) || input.some((x) => !Number.isInteger(x) || x < 0 || x > 255))
        throw Error('Ожидается массив байтов');
      output = Buffer.from(input).toString('base64');
      break;
    case 'base64.bytes':
      output = [...base64(s)];
      break;
    case 'hex.encode':
      output = Buffer.from(s).toString('hex');
      break;
    case 'bytes.hex':
      output = Buffer.from(input as number[]).toString('hex');
      break;
    case 'hex.bytes':
      if (!/^(?:[0-9a-fA-F]{2})*$/.test(s)) throw Error('Hex должен содержать пары цифр');
      output = [...Buffer.from(s, 'hex')];
      break;
    case 'json.parse':
      output = JSON.parse(s);
      break;
    case 'json.stringify':
      output = JSON.stringify(input, null, 2);
      break;
    case 'xml.parse':
      output = xml(s);
      break;
    case 'hex.decode':
      if (!/^(?:[0-9a-fA-F]{2})*$/.test(s)) throw Error('Hex должен содержать пары цифр');
      output = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.from(s, 'hex'));
      break;
    case 'url.encode':
      output = encodeURIComponent(s);
      break;
    case 'url.decode':
      output = decodeURIComponent(s);
      break;
    case 'json.format':
      output = JSON.stringify(JSON.parse(s), null, 2);
      break;
    case 'json.validate':
      JSON.parse(s);
      output = { valid: true };
      break;
    case 'xml.validate':
      xml(s);
      output = { valid: true };
      break;
    case 'xml.format':
      output = new XMLBuilder({
        format: true,
        ignoreAttributes: false,
        processEntities: false,
      }).build(xml(s));
      break;
    case 'xml.json':
      output = JSON.stringify(xml(s), null, 2);
      break;
    case 'json.xml':
      output = new XMLBuilder({
        format: true,
        ignoreAttributes: false,
        processEntities: false,
      }).build(JSON.parse(s));
      break;
    case 'text.lines':
      output = s.replace(/\r\n|\r|\n/g, options.lineEnding === 'CRLF' ? '\r\n' : '\n');
      break;
    case 'text.encoding': {
      const from = options.from || 'utf8',
        to = options.to || 'utf8';
      if (!iconv.encodingExists(from) || !iconv.encodingExists(to))
        throw Error('Неизвестная кодировка');
      const bytes = Array.isArray(input) ? Buffer.from(input) : base64(s);
      output = [...iconv.encode(iconv.decode(bytes, from), to)];
      break;
    }
    default:
      if (operation.startsWith('image.')) {
        output = transformImage(operation, input, options);
        break;
      }
      throw Error('Преобразование не зарегистрировано');
  }
  return {
    output,
    warnings: transforms.find((t) => t.id === operation)?.warning
      ? [transforms.find((t) => t.id === operation)!.warning]
      : [],
  };
}
export function runPipeline(
  steps: { operation: string; options?: Record<string, any> }[],
  input: unknown,
  signal?: AbortSignal,
) {
  let value = input;
  const warnings: string[] = [];
  if (steps.length > 64) throw Error('Не более 64 шагов');
  validatePipeline(steps);
  for (const step of steps) {
    signal?.throwIfAborted();
    const result = runTransform(step.operation, value, step.options);
    value = result.output;
    warnings.push(...(result.warnings as string[]));
  }
  return { output: value, warnings };
}

export interface TransformStep {
  operation: string;
  options?: Record<string, any>;
}
export function validatePipeline(steps: TransformStep[]) {
  if (!Array.isArray(steps) || !steps.length || steps.length > 64)
    throw Error('Выберите от 1 до 64 шагов');
  let previous: string | undefined;
  for (const [index, step] of steps.entries()) {
    const operation = transforms.find((t) => t.id === step.operation);
    if (!operation) throw Error(`Шаг ${index + 1}: преобразование не зарегистрировано`);
    if (previous && previous !== operation.input)
      throw Error(
        `Шаг ${index + 1}: ожидается ${operation.input}, предыдущий шаг возвращает ${previous}`,
      );
    previous = operation.output;
  }
}
