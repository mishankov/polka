import { extensionDependencies } from '../extensions/dependencies';
import type { AppDefinition } from '../shared/types';

// Bundled guidance for the embedded agent, independent of the developer's local skills.
export const UI_UX_PROMPT = `
Проектирование интерфейса приложений:
- Применяй эти правила при создании и изменении экранов. Сначала определи задачу человека, исходные данные и признак успеха. Для небольшого изменения используй контекст; уточняй только то, что существенно меняет сценарий. Явные пожелания пользователя важнее общих рекомендаций.
- Строй самый короткий понятный путь к результату. Открывай полезный рабочий экран; не добавляй приветствие, дашборд, вкладки, обязательные поля или подтверждения без необходимости. На каждом этапе выделяй основное действие, остальные делай менее заметными.
- Подбирай представление по задаче: table для сравнения записей, board для этапов, calendar для дат, form для ввода. Используй готовые экраны и компоненты, когда они решают задачу; custom нужен для особого взаимодействия. Перед новым видом интерфейса изучи definition_schema, включая uiGuidance и примеры. Примеры адаптируй, не копируй их предметную область и дополнительные экраны без необходимости.
- Используй слова пользователя, понятные названия объектов и конкретные команды («Добавить покупку»). Сохраняй видимые подписи полей; placeholder не заменяет label. Группируй связанные поля, задавай разумные значения по умолчанию. Выбирай checkbox только при очевидном смысле выключенного состояния. Объясняй причину недоступного действия и как продолжить.
- У каждого действия должны быть реальный обработчик, видимый результат и путь восстановления. Продумай пустой список с первым действием, загрузку, отсутствие результатов поиска, ошибку с повтором и успех. Не показывай ошибку загрузки как отсутствие данных. Сохраняй введённое при сбое, предотвращай повторную отправку во время сохранения; очищай форму только после подтверждённого успеха. Не повторяй запись автоматически при неизвестном исходе. Предпочитай отменяемые действия, защищай от необратимых ошибок, соблюдай подтверждения платформы.
- Соблюдай существующую тему и компоненты @everything/ui и Mantine. Не фиксируй светлые цвета. Делай экран пригодным для узкого отдельного окна и большого рабочего пространства; используй ширину по смыслу, переноси длинный текст, ограничивай горизонтальную прокрутку областями, которым она нужна. Не дублируй навигацию и настройки оболочки внутри приложения.
- Используй семантические кнопки и формы, доступные названия, видимый фокус и логичный порядок клавиатурной навигации. Статус объясняй текстом, а не только цветом. Ошибки связывай с полем, важный результат сообщай через role=status или role=alert. После действия сохраняй понятное положение фокуса.
- Перед завершением проверь определение и код по основному сценарию: первое использование, повторное действие, ошибка и восстановление, 0/1/много записей, длинные названия, допустимые крайние значения, изменение данных. Учитывай ограничения выборки и предусмотренный SDK способ доступа к остальным записям. Для изменений изучи definition_prepare до активации. Проверка схемы и компиляция не доказывают удобство или работу интерфейса: у тебя нет инструмента просмотра экрана и нажатия кнопок, поэтому не утверждай, что визуально проверил интерфейс. Кратко сообщай только реально проверенное и существенные ограничения.
`;

const quickEntrySource = `import {useEffect, useRef, useState} from 'react';
import {Button, Group, Stack, Text, TextInput, Title} from '@mantine/core';
import {ErrorView, useSDK} from '@everything/ui';

export default function ShoppingList() {
  const sdk = useSDK();
  const input = useRef(null), saving = useRef(false);
  const [title, setTitle] = useState(''), [fieldError, setFieldError] = useState('');
  const [busy, setBusy] = useState(false), [saveError, setSaveError] = useState(null);
  const [notice, setNotice] = useState('');
  const [page, setPage] = useState(0), [refresh, setRefresh] = useState(0);
  const [result, setResult] = useState({records: [], total: 0});
  const [loading, setLoading] = useState(true), [loadError, setLoadError] = useState(null);
  const limit = 20;
  useEffect(() => {
    let live = true;
    setLoading(true);
    setLoadError(null);
    sdk.call('records.list', {entityId: 'items', limit, offset: page * limit})
      .then((next) => {
        if (!live) return;
        if (page > 0 && page * limit >= next.total) {
          setPage(Math.max(0, Math.ceil(next.total / limit) - 1));
        } else setResult(next);
      })
      .catch(() => { if (live) setLoadError('Не удалось загрузить покупки. Попробуйте ещё раз.'); })
      .finally(() => { if (live) setLoading(false); });
    return () => { live = false; };
  }, [sdk, page, refresh]);

  async function add(event) {
    event.preventDefault();
    if (saving.current) return;
    if (!title.trim()) {
      setFieldError('Введите название покупки');
      input.current?.focus();
      return;
    }
    saving.current = true;
    setBusy(true);
    setSaveError(null);
    setNotice('');
    try {
      await sdk.call('records.upsert', {entityId: 'items', values: {title: title.trim()}});
      setTitle('');
      setNotice('Покупка добавлена');
      setPage(0);
      setRefresh((value) => value + 1);
    } catch {
      setSaveError('Не удалось подтвердить сохранение. Введённое название сохранено. Обновите список перед повторной отправкой, чтобы избежать дубликата.');
    } finally {
      saving.current = false;
      setBusy(false);
      input.current?.focus();
    }
  }

  return <Stack p="md" style={{minWidth: 0}}>
    <Title order={2}>Покупки</Title>
    <form onSubmit={add} noValidate>
      <Stack gap="sm">
        <TextInput ref={input} label="Что купить" required maxLength={200}
          value={title} readOnly={busy} error={fieldError}
          onChange={(event) => {setTitle(event.currentTarget.value); setFieldError(''); setNotice('');}} />
        <ErrorView error={saveError} />
        <Button type="submit" loading={busy}>Добавить покупку</Button>
      </Stack>
    </form>
    <Text role="status">{notice}</Text>
    <Group justify="space-between">
      <Title order={3}>Список покупок</Title>
      <Button variant="subtle" loading={loading} onClick={() => setRefresh((value) => value + 1)}>Обновить список</Button>
    </Group>
    {loading ? <Text role="status">Загружаем покупки…</Text> : loadError ?
      <Stack><ErrorView error={loadError} /><Button variant="default" onClick={() => setRefresh((value) => value + 1)}>Повторить загрузку</Button></Stack> :
      result.total === 0 ? <Text>Список пуст. Добавьте первую покупку в форме выше.</Text> :
      <Stack>
        <ul style={{margin: 0, paddingInlineStart: '1.5rem'}}>
          {result.records.map((record) => <li key={record.id} style={{overflowWrap: 'anywhere'}}>{record.values.title}</li>)}
        </ul>
        <Text size="sm" c="dimmed">Всего покупок: {result.total}</Text>
        {result.total > limit && <Group aria-label="Страницы списка">
          <Button variant="default" disabled={page === 0} onClick={() => setPage((value) => value - 1)}>Назад</Button>
          <Text>Страница {page + 1} из {Math.ceil(result.total / limit)}</Text>
          <Button variant="default" disabled={(page + 1) * limit >= result.total} onClick={() => setPage((value) => value + 1)}>Далее</Button>
        </Group>}
      </Stack>}
  </Stack>;
}`;

const quickEntry: AppDefinition = {
  schemaVersion: 1,
  name: 'Покупки',
  entities: [
    {
      id: 'items',
      name: 'Покупки',
      fields: [{ id: 'title', name: 'Что купить', type: 'text', required: true }],
    },
  ],
  screens: [
    { id: 'shopping', name: 'Покупки', type: 'custom', config: { extensionId: 'shopping' } },
  ],
  extensions: [
    {
      id: 'shopping',
      name: 'Быстрое добавление покупок',
      kind: 'component',
      source: quickEntrySource,
      dependencies: Object.fromEntries(
        ['react', '@mantine/core', '@everything/ui'].map((name) => [
          name,
          extensionDependencies[name],
        ]),
      ),
    },
  ],
  actions: [],
  automations: [],
  permissions: [],
};

const taskBoard: AppDefinition = {
  schemaVersion: 1,
  name: 'Задачи',
  entities: [
    {
      id: 'tasks',
      name: 'Задачи',
      fields: [
        { id: 'title', name: 'Задача', type: 'text', required: true },
        {
          id: 'status',
          name: 'Этап',
          type: 'select',
          options: ['Планы', 'В работе', 'Готово'],
          default: 'Планы',
          required: true,
        },
      ],
    },
  ],
  screens: [
    {
      id: 'board',
      name: 'Задачи по этапам',
      type: 'board',
      entityId: 'tasks',
      config: { groupBy: 'status' },
    },
  ],
  extensions: [],
  actions: [],
  automations: [],
  permissions: [],
};

export const uiGuidance = {
  usage:
    'Это примеры взаимодействия, а не обязательные шаблоны приложений. Выбирайте минимальное решение по сценарию пользователя. Не добавляйте демонстрационные записи в рабочие данные без запроса.',
  platform:
    'Custom-экран уже обёрнут в MantineProvider с темой приложения и SDKContext. Используйте useSDK() из @everything/ui или prop sdk; повторный провайдер темы не нужен. Используйте свойства компонентов и переменные Mantine для цвета и отступов. Не импортируйте библиотеки вне sdk.dependencies.',
  examples: [
    {
      id: 'task-board',
      scenario: 'Человек хочет видеть задачи по этапам и менять их статус.',
      decisions:
        'Один готовый board с существующим select-полем; первая колонка выбрана по умолчанию. Без отдельного дашборда, расширения и ненужных обязательных сроков.',
      definition: taskBoard,
    },
    {
      id: 'quick-entry-list',
      scenario: 'Человек быстро добавляет покупки одну за другой и просматривает список.',
      decisions:
        'Custom оправдан вводом без открытия диалога и возвратом фокуса для следующей покупки. Общий пример формы и списка: проверка пустого ввода, блокировка повторной отправки, сохранение текста при сбое, отдельные ошибки чтения и записи, повтор загрузки, пустое состояние и страницы по 20 записей. Для обычного редактирования таблицы выбирайте готовый table.',
      definition: quickEntry,
    },
  ],
};
