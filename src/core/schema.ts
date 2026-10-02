import { z } from 'zod';
import { extensionDependencies } from '../extensions/dependencies';
import {
  THEME_COLORS,
  THEME_RADII,
  type AppDefinition,
  type EntityDefinition,
} from '../shared/types';
const id = z
  .string()
  .regex(
    /^[a-zA-Z][a-zA-Z0-9_-]{0,99}$/,
    'Идентификатор должен состоять из латинских букв, цифр, _ и -',
  );
const field = z
  .object({
    id,
    name: z.string().min(1).max(200),
    type: z.enum(['text', 'number', 'boolean', 'date', 'select', 'relation', 'attachment', 'json']),
    required: z.boolean().optional(),
    unique: z.boolean().optional(),
    options: z.array(z.string()).max(1000).optional(),
    targetEntity: id.optional(),
    default: z.unknown().optional(),
  })
  .strict();
export const definitionSchema = z
  .object({
    schemaVersion: z.literal(1),
    name: z.string().min(1).max(200),
    description: z.string().max(10000).optional(),
    icon: z.string().max(100).optional(),
    entities: z
      .array(
        z
          .object({ id, name: z.string().min(1).max(200), fields: z.array(field).max(100) })
          .strict(),
      )
      .max(100),
    screens: z
      .array(
        z
          .object({
            id,
            name: z.string().min(1).max(200),
            type: z.enum([
              'table',
              'form',
              'board',
              'calendar',
              'chart',
              'text',
              'image',
              'converter',
              'dashboard',
              'custom',
            ]),
            entityId: id.optional(),
            config: z.record(z.string(), z.unknown()).optional(),
          })
          .strict(),
      )
      .max(100),
    actions: z
      .array(
        z
          .object({
            id,
            name: z.string().min(1).max(200),
            type: z.string().min(1).max(100),
            config: z.record(z.string(), z.unknown()).optional(),
            permission: z.string().optional(),
          })
          .strict(),
      )
      .max(100),
    automations: z
      .array(
        z
          .object({
            id,
            name: z.string().min(1).max(200),
            trigger: z.enum(['interval', 'clipboard', 'schedule', 'event']),
            actionId: id,
            enabled: z.boolean().optional(),
            intervalMs: z.number().int().min(1000).optional(),
            config: z.record(z.string(), z.unknown()).optional(),
          })
          .strict(),
      )
      .max(100),
    extensions: z
      .array(
        z
          .object({
            id,
            name: z.string().min(1).max(200),
            kind: z.enum(['component', 'handler']),
            source: z.string().max(1_000_000),
            dependencies: z.record(z.string(), z.string()).optional(),
          })
          .strict(),
      )
      .max(30),
    permissions: z.array(z.string().min(1).max(200)).max(100),
    theme: z
      .object({
        mode: z.enum(['light', 'dark', 'auto']).optional(),
        primaryColor: z.enum(THEME_COLORS).optional(),
        density: z.enum(['compact', 'comfortable']).optional(),
        radius: z.enum(THEME_RADII).optional(),
      })
      .strict()
      .optional(),
    connections: z.array(z.object({ id, name: z.string(), kind: z.string() }).strict()).optional(),
  })
  .strict();
export function validateDefinition(input: unknown): AppDefinition {
  const parsed = definitionSchema.safeParse(input);
  if (!parsed.success)
    throw new Error(
      'Некорректное определение: ' +
        parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; '),
    );
  const d = parsed.data as AppDefinition;
  for (const group of [
    d.entities,
    d.screens,
    d.actions,
    d.automations,
    d.extensions,
    ...d.entities.map((e) => e.fields),
  ])
    if (new Set(group.map((x) => x.id)).size !== group.length)
      throw new Error('Идентификаторы внутри раздела не должны повторяться');
  for (const e of d.entities)
    for (const f of e.fields) {
      if (f.type === 'relation' && !d.entities.some((x) => x.id === f.targetEntity))
        throw new Error(`Не найдена сущность связи ${e.id}.${f.id}`);
      if (f.type === 'select' && !f.options?.length)
        throw new Error(`У поля ${f.id} отсутствуют варианты`);
    }
  const validateExtensionReference = (
    owner: string,
    extensionId: unknown,
    kind: 'component' | 'handler',
  ) => {
    const candidates = d.extensions.filter((extension) => extension.kind === kind);
    const hint = candidates.length
      ? ` Доступные ${kind}: ${candidates.map((extension) => extension.id).join(', ')}.`
      : ` Сначала добавьте расширение с kind: "${kind}" в extensions.`;
    if (typeof extensionId !== 'string' || !extensionId.trim())
      throw new Error(`${owner}: укажите config.extensionId расширения ${kind}.${hint}`);
    if (!candidates.some((extension) => extension.id === extensionId))
      throw new Error(
        `${owner}: config.extensionId "${extensionId}" должен ссылаться на существующее расширение ${kind}.${hint}`,
      );
  };
  for (const s of d.screens) {
    if (s.entityId && !d.entities.some((e) => e.id === s.entityId))
      throw new Error(`Экран ${s.id} ссылается на отсутствующую сущность`);
    if (s.type === 'custom')
      validateExtensionReference(`Экран ${s.id}`, s.config?.extensionId, 'component');
  }
  for (const a of d.actions)
    if (a.type === 'extension')
      validateExtensionReference(`Действие ${a.id}`, a.config?.extensionId, 'handler');
  for (const a of d.automations)
    if (!d.actions.some((x) => x.id === a.actionId))
      throw new Error(`Автоматизация ${a.id} ссылается на отсутствующее действие`);
  // Only bundled dependencies may be used; no recipient-side installs or network code.
  for (const extension of d.extensions)
    for (const [name, version] of Object.entries(extension.dependencies || {}))
      if (extensionDependencies[name] !== version)
        throw new Error(
          `Зависимость ${name}@${version} не закреплена или не поддерживается локальной средой`,
        );
  return d;
}
export function validateValues(entity: EntityDefinition, input: unknown): Record<string, unknown> {
  if (!input || typeof input !== 'object' || Array.isArray(input))
    throw new Error('Поля записи должны быть объектом');
  const values = { ...(input as Record<string, unknown>) };
  for (const key of Object.keys(values))
    if (!entity.fields.some((f) => f.id === key)) throw new Error(`Неизвестное поле ${key}`);
  for (const f of entity.fields) {
    if (values[f.id] === undefined && f.default !== undefined) values[f.id] = f.default;
    const v = values[f.id];
    if (v === null || v === undefined || v === '') {
      if (f.required) throw new Error(`Заполните поле «${f.name}»`);
      continue;
    }
    const valid =
      f.type === 'number'
        ? typeof v === 'number' && Number.isFinite(v)
        : f.type === 'boolean'
          ? typeof v === 'boolean'
          : f.type === 'json'
            ? true
            : typeof v === 'string';
    if (!valid) throw new Error(`Неверный тип поля «${f.name}»`);
    if (f.type === 'select' && !f.options?.includes(v as string))
      throw new Error(`Неизвестный вариант поля «${f.name}»`);
    if (
      f.type === 'date' &&
      (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}(T.*)?$/.test(v) || Number.isNaN(Date.parse(v)))
    )
      throw new Error(`Неверная дата в поле «${f.name}»`);
  }
  if (Buffer.byteLength(JSON.stringify(values)) > 1_000_000)
    throw new Error('Запись превышает 1 МБ');
  return values;
}
export function emptyDefinition(name: string): AppDefinition {
  return {
    schemaVersion: 1,
    name,
    entities: [],
    screens: [],
    actions: [],
    automations: [],
    extensions: [],
    permissions: [],
  };
}
