import { XMLParser, XMLBuilder, XMLValidator } from 'fast-xml-parser';
import { parseDocument, stringify } from 'yaml';
export const MAX_TRANSFORM_INPUT = 1024 * 1024;
const MAX_OUTPUT = 2 * 1024 * 1024;
const conversionWarning =
  'XML: атрибуты имеют префикс @_, текст — #text. При переводе в JSON порядок, комментарии и смешанный текст могут измениться.';
export const transforms = [
  ['json.format', 'Форматировать JSON', 'text', 'text', 'json', 'json'],
  ['json.validate', 'Проверить JSON', 'text', 'data', 'json', 'json'],
  ['json.parse', 'JSON → данные', 'text', 'data', 'json', 'json'],
  ['json.stringify', 'Данные → JSON', 'data', 'text', 'json', 'json'],
  ['xml.format', 'Форматировать XML', 'text', 'text', 'xml', 'xml'],
  ['xml.validate', 'Проверить XML', 'text', 'data', 'xml', 'json'],
  ['xml.parse', 'XML → данные', 'text', 'data', 'xml', 'json'],
  ['xml.json', 'XML → JSON', 'text', 'text', 'xml', 'json'],
  ['json.xml', 'JSON → XML', 'text', 'text', 'json', 'xml'],
  ['yaml.format', 'Форматировать YAML', 'text', 'text', 'yaml', 'yaml'],
  ['yaml.validate', 'Проверить YAML', 'text', 'data', 'yaml', 'json'],
  ['yaml.parse', 'YAML → данные', 'text', 'data', 'yaml', 'json'],
  ['yaml.stringify', 'Данные → YAML', 'data', 'text', 'json', 'yaml'],
  ['yaml.json', 'YAML → JSON', 'text', 'text', 'yaml', 'json'],
  ['json.yaml', 'JSON → YAML', 'text', 'text', 'json', 'yaml'],
  ['base64.encode', 'Текст → Base64', 'text', 'text', 'text', 'base64'],
  ['base64.decode', 'Base64 → текст', 'text', 'text', 'base64', 'text'],
  ['bytes.base64', 'Байты → Base64', 'bytes', 'text', 'json', 'base64'],
  ['base64.bytes', 'Base64 → байты', 'text', 'bytes', 'base64', 'json'],
  ['hex.encode', 'Текст → hex', 'text', 'text', 'text', 'hex'],
  ['hex.decode', 'Hex → текст', 'text', 'text', 'hex', 'text'],
  ['bytes.hex', 'Байты → hex', 'bytes', 'text', 'json', 'hex'],
  ['hex.bytes', 'Hex → байты', 'text', 'bytes', 'hex', 'json'],
].map(([id, name, input, output, inputLanguage, outputLanguage]) => ({
  id,
  name,
  input,
  output,
  inputLanguage,
  outputLanguage,
  warning: ['xml.parse', 'xml.json', 'json.xml'].includes(id)
    ? conversionWarning
    : id === 'yaml.json'
      ? 'Комментарии, стиль YAML и связи между якорями не переносятся в JSON.'
      : undefined,
}));
function jsonData(
  value: unknown,
  ancestors = new Set<unknown>(),
  budget = { nodes: 0 },
  depth = 0,
): void {
  if (++budget.nodes > 100000 || depth > 100) throw Error('Слишком сложная структура данных');
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return;
  if (typeof value === 'number' && Number.isFinite(value)) return;
  if (typeof value !== 'object' || !value || ancestors.has(value))
    throw Error('Нужны данные JSON без циклических ссылок и нечисловых значений NaN/Infinity');
  ancestors.add(value);
  for (const child of Object.values(value)) jsonData(child, ancestors, budget, depth + 1);
  ancestors.delete(value);
}
function xml(text: string, preserveOrder = false) {
  if (/<!\s*(DOCTYPE|ENTITY)/i.test(text)) throw Error('DTD и внешние сущности XML запрещены');
  const valid = XMLValidator.validate(text);
  if (valid !== true) throw Error(`XML: строка ${valid.err.line}: ${valid.err.msg}`);
  return new XMLParser({
    ignoreAttributes: false,
    preserveOrder,
    processEntities: true,
    parseTagValue: false,
    parseAttributeValue: false,
    trimValues: false,
    commentPropName: '#comment',
  }).parse(text);
}
function yaml(text: string) {
  const doc = parseDocument(text, {
    version: '1.2',
    schema: 'core',
    stringKeys: true,
    uniqueKeys: true,
  });
  if (doc.errors.length || doc.warnings.length)
    throw Error(`YAML: ${(doc.errors[0] || doc.warnings[0]).message}`);
  const data = doc.toJS({ maxAliasCount: 100 });
  jsonData(data);
  return { doc, data };
}
function decode(text: string, encoding: 'hex' | 'base64') {
  if (encoding === 'hex') {
    if (text.length % 2 || /[^0-9a-fA-F]/.test(text))
      throw Error('Hex должен содержать пары цифр 0–9, A–F');
  } else {
    const padding = text.endsWith('==') ? 2 : text.endsWith('=') ? 1 : 0;
    if (text.length % 4 || /[^A-Za-z0-9+/]/.test(text.slice(0, text.length - padding)))
      throw Error('Некорректный Base64');
  }
  return Buffer.from(text, encoding);
}
export function runTransform(operation: string, input: unknown) {
  const spec = transforms.find((t) => t.id === operation);
  if (!spec) throw Error('Неизвестная операция формата');
  jsonData(input);
  if (Buffer.byteLength(JSON.stringify(input)) > MAX_TRANSFORM_INPUT)
    throw Error('Ввод превышает 1 МиБ');
  if (spec.input === 'text' && typeof input !== 'string') throw Error('Ожидается текст');
  if (
    spec.input === 'bytes' &&
    (!Array.isArray(input) || input.some((v) => !Number.isInteger(v) || v < 0 || v > 255))
  )
    throw Error('Ожидается массив байтов от 0 до 255');
  const text = typeof input === 'string' ? input : '';
  let output: unknown;
  switch (operation) {
    case 'json.parse':
      output = JSON.parse(text);
      break;
    case 'json.format':
      output = JSON.stringify(JSON.parse(text), null, 2);
      break;
    case 'json.validate':
      JSON.parse(text);
      output = { valid: true };
      break;
    case 'json.stringify':
      output = JSON.stringify(input, null, 2);
      break;
    case 'xml.validate':
      xml(text);
      output = { valid: true };
      break;
    case 'xml.parse':
      output = xml(text);
      break;
    case 'xml.json':
      output = JSON.stringify(xml(text), null, 2);
      break;
    case 'xml.format':
      output = new XMLBuilder({
        ignoreAttributes: false,
        preserveOrder: true,
        commentPropName: '#comment',
        format: true,
      }).build(xml(text, true));
      break;
    case 'json.xml': {
      const data = JSON.parse(text);
      if (!data || Array.isArray(data) || typeof data !== 'object')
        throw Error('Для XML нужен объект JSON с корневым элементом');
      output = new XMLBuilder({
        ignoreAttributes: false,
        commentPropName: '#comment',
        format: false,
      }).build(data);
      xml(String(output));
      break;
    }
    case 'yaml.parse':
      output = yaml(text).data;
      break;
    case 'yaml.validate':
      yaml(text);
      output = { valid: true };
      break;
    case 'yaml.format':
      output = yaml(text).doc.toString();
      break;
    case 'yaml.stringify':
      output = stringify(input);
      break;
    case 'yaml.json':
      output = JSON.stringify(yaml(text).data, null, 2);
      break;
    case 'json.yaml':
      output = stringify(JSON.parse(text));
      break;
    case 'base64.encode':
      output = Buffer.from(text, 'utf8').toString('base64');
      break;
    case 'hex.encode':
      output = Buffer.from(text, 'utf8').toString('hex');
      break;
    case 'bytes.base64':
      output = Buffer.from(input as number[]).toString('base64');
      break;
    case 'bytes.hex':
      output = Buffer.from(input as number[]).toString('hex');
      break;
    case 'base64.bytes':
      output = [...decode(text, 'base64')];
      break;
    case 'hex.bytes':
      output = [...decode(text, 'hex')];
      break;
    case 'base64.decode':
    case 'hex.decode':
      try {
        output = new TextDecoder('utf-8', { fatal: true }).decode(
          decode(text, operation === 'hex.decode' ? 'hex' : 'base64'),
        );
      } catch (error) {
        if (error instanceof TypeError)
          throw Error('Байты не являются текстом UTF-8. Выберите декодирование в байты.');
        throw error;
      }
      break;
  }
  jsonData(output);
  if (Buffer.byteLength(JSON.stringify(output)) > MAX_OUTPUT)
    throw Error('Результат превышает 2 МиБ');
  return { output, warnings: spec.warning ? [spec.warning] : [] };
}
