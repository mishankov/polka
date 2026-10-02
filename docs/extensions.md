# Программируемые экраны и интеграции

Экран `custom` с `config.extensionId` загружает `kind: component` расширение. Исходник TSX экспортирует React-компонент по умолчанию. Props содержат `sdk`; компоненты платформы получают этот же SDK через `useSDK()`.

Custom screens fill the available app area below its tabs and actions, in both the workspace and separate windows. The viewport updates when the window or assistant panel resizes. `html`, `body`, and `#root` provide a full-height layout with no imposed padding: use `height: '100%'` or `100vh` for a full-height canvas, and add your own content padding. For a pinned toolbar and scrolling content, use a column flex layout with `flex: 1; min-height: 0; overflow: auto` on the scrolling region. Natural document scrolling remains available for long screens.

```tsx
import { Stack, Title } from '@mantine/core';
import { RecordTable, EntityForm, useSDK } from '@everything/ui';
export default function Screen() {
  const entity = { id: 'items', name: 'Заметки', fields: [
    { id: 'title', name: 'Название', type: 'text', required: true }
  ] };
  return <Stack><Title order={2}>Мои заметки</Title>
    <EntityForm entity={entity} /><RecordTable entity={entity} />
  </Stack>;
}
```

`RecordTable` поддерживает локальный поиск в выборке до 500 записей, кнопку выбора и `refresh` для повторного запроса после сохранения. `EntityForm` вызывает тот же `records.upsert`, что и стандартные экраны. Дополнительно доступны `RelatedRecordSelect`, `Card`, `ActionButton`, `JobProgress`, `HistoryList`, `ErrorView`, `Board`, `CalendarView`. `CalendarView` — список записей по датам; месячную сетку можно построить из Mantine. Графики доступны из Recharts, компоновка — из Mantine. SDK ограничен текущим экземпляром; таблица не получает доступ к чужим записям.

## Зафиксированные зависимости

| Импорт | Версия в definition.extensions[].dependencies |
|---|---|
| `react`, `react/jsx-runtime` | `react: 19.3.0` |
| `react-dom/client` | `react-dom: 19.3.0` |
| `@mantine/core` | `9.6.3` |
| `@mantine/hooks` | `9.6.3` |
| `recharts` | `3.10.1` |
| `zod` | `4.6.5` |
| `@everything/ui` | `1.0.0` |

React/JSX и общая библиотека всегда входят в поставку. В dependencies указываются точные версии, без диапазонов. Пакет с неизвестной/несовместимой версией отклоняется до активации. Другие пути импортов, файлы, node/electron и CDN запрещены. Темы, радиусы и плотность передаются из настроек; внутри экрана не требуется собственный MantineProvider.

`npm run build` сначала собирает приложение, затем `scripts/build-extension-runtime.ts` собирает библиотеки в `out/extensions`. Получателю не нужны исходники, npm install или интернет. Для нового trusted library разработчик платформы изменяет allowlist и runtime-entry, фиксирует версию package-lock и выпускает новую платформу. Обычный импорт `.everyapp` не расширяет этот каталог.

## Разрешённые интеграции

`adapters.list` возвращает версии, схемы, эффекты, разрешения, ошибки и лимиты trusted adapters. Поставляемые HTTP-адаптеры:

- `network.fetch`: совместимый GET с текстовым ответом.
- `network.request`: GET/HEAD/POST/PUT/PATCH/DELETE, `json` или `body`, безопасные пользовательские заголовки, `responseType: text|json`, необязательный `connectionId`.

```ts
await sdk.call('network.request', {
  url: 'https://api.example.com/items',
  method: 'POST',
  json: { title: 'Новая запись' },
  responseType: 'json',
  connectionId: 'my_service'
});
```

Нужно выданное разрешение `network:https://api.example.com`. Подключение с bearer-ключом принадлежит текущему приложению и точному HTTPS origin; сохранение ключа выполняет оболочка через macOS safeStorage. SDK не читает ключ и не задаёт Authorization/Cookie/Host. Нет ambient cookies; редиректы запрещены. Лимиты: 1 МиБ запрос, 2 МиБ ответ, 10 секунд, 8 одновременно. Проверка прав происходит перед запросом и после чтения ответа. Отзыв прав/остановка приложения отменяет активные запросы. Эффекты POST/PUT/PATCH/DELETE не откатываются отменой уже принятого сервером запроса; автоматического повтора нет.

Тот же адаптер вызывается действием с `type: network.request` и `config`, содержащим параметры. Поэтому экран, фоновые задания и агент используют одну проверку разрешений. Сеть непосредственно из renderer закрыта. Новые trusted native-адаптеры устанавливаются только обновлением платформы; произвольный shell, исполняемые файлы и native-модули из пакета приложения недоступны.

## Отказ и восстановление

UI исполняется в отдельном sandboxed renderer. Пустой/ошибочный экспорт показывает ошибку; кнопка «Перезапустить экран» пересоздаёт среду. «Остановить экран» уничтожает renderer, не данные приложения. Если UI зациклился, host уничтожает его после отсутствия heartbeat более 6,5 секунды. Оболочка остаётся доступна. Тема обновляется без сброса React-состояния; перезапуск сбрасывает несохранённое состояние компонента, поэтому долговременные данные нужно сохранять через SDK.

Фоновые обработчики по-прежнему выполняются в QuickJS: 32 МиБ, 3 секунды, максимум 32 effect-операции; импорт npm-библиотек там не доступен. Node, filesystem и прямой fetch отсутствуют. UI Chromium не имеет отдельной жёсткой квоты памяти; тяжёлые вычисления следует оформлять фоновым действием.
