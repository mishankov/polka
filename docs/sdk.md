# SDK платформы, API v1

Контракт определения — `src/shared/types.ts`, runtime-проверка — `src/core/schema.ts`; операции доверенной оболочки — `docs/core-rpc.md`. Идентификаторы сущностей/экранов/полей стабильны и состоят из латинских букв, цифр, `_`, `-`. Имена предназначены для отображения. Любое изменение определения проходит prepare → показ различий → activate. Новая запись между prepare и activate делает draft устаревшим.

## Декларативный экран

```json
{"id":"items","name":"Список","type":"table","entityId":"items"}
```

Доступны table, form, board, calendar, chart, text, image, converter, dashboard и custom. `theme` задаёт mode, primaryColor, density и radius. Обработчики, преобразования и автоматически выполняемые действия используют один executor; экран не должен самостоятельно менять БД.

## Обработчик

```ts
export default function(input: {title: string}) {
  return { operations: [{ method: 'records.upsert', params: {
    entityId: 'items', values: {title: input.title}
  }}], value: 'Запись подготовлена' };
}
```

Компиляция обрабатывает TS; итоговые данные всё равно проверяет runtime. Возвращаемые operations исполняются последовательно. `input` должен быть JSON; Promise, доступ к часам хоста, Node-модули и fetch внутри QuickJS не поддерживаются. Доступны scoped `records.list/upsert/delete`, `links.query`, `attachments.list/read`, `docs.list/get/create/draft/revert`, `transforms.run`, `clipboard.read/write`, `notifications.show`, `system.media`, `adapters.list`, `network.fetch/request`, `actions.run`, `jobs.list/cancel`. Обработчик не может вызвать settings, state, permissions.grant, secrets, произвольный файловый путь или изменение соседнего appId. Runtime повторно проверяет разрешения в доверенном коде.

## React-компонент

```tsx
import {useState} from 'react';
export default function Screen({sdk}) {
 const [text,setText] = useState('');
 return <button onClick={async()=>{
   const result = await sdk.call('records.list',{entityId:'items'});
   setText(`${result.total} записей`);
 }}>{text || 'Посчитать записи'}</button>;
}
```

`screen.config.extensionId` указывает компонент из definition.extensions. Экран исполняется в отдельном sandboxed renderer с SDK, привязанным к текущему appId в main. Node, Electron, произвольные импорты и прямая сеть недоступны. Зависший экран можно остановить/перезапустить; host автоматически уничтожает его при отсутствии heartbeat более 6,5 секунды, сохраняя работу оболочки.

Встроенный каталог содержит `react`/`react/jsx-runtime` 19.3.0, `react-dom/client` 19.3.0, `@mantine/core` 9.6.3, `@mantine/hooks` 9.6.3, `recharts` 3.10.1, `zod` 4.6.5 и `@everything/ui` 1.0.0. Точные версии dependencies проверяются до установки; диапазоны и неизвестные библиотеки отклоняются. Всё входит в сборку платформы, без CDN и npm install у получателя.

`@everything/ui` экспортирует `EntityForm`, `RecordTable`, `RelatedRecordSelect`, `Card`, `ActionButton`, `JobProgress`, `HistoryList`, `ErrorView`, `Board`, `CalendarView`, `useSDK`. Формы/таблицы/действия используют общий scoped SDK; схемы сущностей передаются props. Для компоновки используйте Mantine, для графиков — Recharts, для документов — стандартные text/image экраны. Общая уютная тема, радиусы, плотность и активный светлый/тёмный режим передаются автоматически, включая изменения во время работы. [Примеры, ограничения выборки и библиотек](extensions.md).

## Разрешения

`definition.permissions` объявляет запрос; `permissions.grant` в оболочке выдаёт согласие отдельно. Разрешения не переносятся пакетом. Поддерживаются background, clipboard.read, clipboard.write, notifications, system.media, `network:https://example.com`. Network API поддерживает `network.fetch` (GET) и `network.request` (GET/HEAD/POST/PUT/PATCH/DELETE, body/json, responseType text/json). Требуется точное разрешение HTTPS origin; редиректы запрещены, запрос ≤1 МиБ, ответ ≤2 МиБ, timeout 10 секунд, максимум 8 запросов одновременно. Отмена/отзыв прав прерывают запросы. Для Authorization используется connectionId текущего приложения с тем же origin; ключ хранится через macOS safeStorage и не выдаётся расширению. Файлы выбираются через native dialog в оболочке, затем используются как документы/вложения. Межприложенческие данные доступны через отдельно выданный link, проверяемый при каждом запросе.

## Добавление платформенной операции

Добавьте runtime-проверку аргументов, запись в capability catalog, единый executor и тесты границы доступа. Разрешённые привилегии проверяются в worker/main, а не только в UI. `AdapterRegistry` (`src/extensions/adapters.ts`) содержит машинные описания и проверяемые реализации trusted adapters; `adapters.list`/каталог агента описывают схемы, эффекты, права, повтор, отмену и лимиты. Новая регистрация требует кода доверенной поставки. Новый нативный адаптер обновляется только вместе с доверенной поставкой платформы; пакет `.everyapp` не принимает бинарники.
