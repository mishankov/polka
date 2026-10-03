import { useEffect, useState } from 'react';
import {
  Accordion,
  Alert,
  Badge,
  Button,
  Checkbox,
  Code,
  Divider,
  Group,
  Modal,
  MultiSelect,
  Paper,
  Progress,
  Select,
  Stack,
  Switch,
  Tabs,
  Text,
  TextInput,
  Textarea,
  Title,
} from '@mantine/core';
import CodeMirror from '@uiw/react-codemirror';
import { json } from '@codemirror/lang-json';
import { IconPlus, IconTrash } from '@tabler/icons-react';
import type { AppDefinition, AppInstance } from '../../shared/types';
import { api, AnyRecord, perform, report } from './api';
import Connections from './Connections';
import WindowPreferences from './WindowPreferences';
export const emptyDefinition = (name: string): AppDefinition => ({
  schemaVersion: 1,
  name,
  entities: [],
  screens: [],
  actions: [],
  automations: [],
  extensions: [],
  permissions: [],
});
export function CreateApp({
  opened,
  onClose,
  onCreated,
}: {
  opened: boolean;
  onClose: () => void;
  onCreated: (app: AppInstance) => void;
}) {
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [busy, setBusy] = useState(false);
  return (
    <Modal opened={opened} onClose={onClose} title="Новое приложение" centered>
      <Stack>
        <Text c="dimmed" size="sm">
          Начните с пустого приложения. Экраны, данные и поведение можно добавить самостоятельно или
          с помощником.
        </Text>
        <TextInput
          label="Название"
          placeholder="Например, проекты мастерской"
          value={name}
          onChange={(e) => setName(e.target.value)}
          data-autofocus
        />
        <Textarea
          label="Для чего это приложение"
          value={description}
          onChange={(e) => setDescription(e.target.value)}
        />
        <Button
          loading={busy}
          disabled={!name.trim()}
          onClick={async () => {
            setBusy(true);
            const a = await perform(() => api('apps.create', { name: name.trim(), description }));
            setBusy(false);
            if (a) {
              setName('');
              setDescription('');
              onCreated(a);
              onClose();
            }
          }}
        >
          Создать приложение
        </Button>
      </Stack>
    </Modal>
  );
}
export function DefinitionEditor({
  app,
  opened,
  onClose,
  onChanged,
}: {
  app: AppInstance;
  opened: boolean;
  onClose: () => void;
  onChanged: () => void;
}) {
  const [definition, setDefinition] = useState<AppDefinition>(app.definition);
  const [source, setSource] = useState('');
  const [mode, setMode] = useState<string | null>('visual');
  const [preview, setPreview] = useState<any>();
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    setDefinition(structuredClone(app.definition));
    setSource(JSON.stringify(app.definition, null, 2));
    setPreview(undefined);
  }, [app.id, app.version, opened]);
  async function prepare() {
    setBusy(true);
    const d = mode === 'code' ? JSON.parse(source) : definition;
    const p = await perform(() => api('definitions.prepare', { appId: app.id, definition: d }));
    setPreview(p);
    setBusy(false);
  }
  return (
    <Modal
      size="xl"
      opened={opened}
      onClose={onClose}
      title={`Устройство приложения · ${app.name}`}
    >
      <Tabs
        value={mode}
        onChange={(v) => {
          if (v === 'code') setSource(JSON.stringify(definition, null, 2));
          if (v === 'visual') {
            try {
              setDefinition(JSON.parse(source));
            } catch {
              report(new Error('Исправьте JSON перед переходом к редактору'));
              return;
            }
          }
          setMode(v);
          setPreview(undefined);
        }}
      >
        <Tabs.List mb="lg">
          <Tabs.Tab value="visual">Экраны и данные</Tabs.Tab>
          <Tabs.Tab value="code">Определение JSON</Tabs.Tab>
        </Tabs.List>
        <Tabs.Panel value="visual">
          <Stack>
            <Group grow>
              <TextInput
                label="Название определения"
                value={definition.name}
                onChange={(e) => setDefinition({ ...definition, name: e.target.value })}
              />
              <Select
                label="Акцентный цвет"
                value={definition.theme?.primaryColor || 'teal'}
                data={['teal', 'blue', 'indigo', 'violet', 'pink', 'orange', 'green']}
                onChange={(v) =>
                  setDefinition({
                    ...definition,
                    theme: { ...definition.theme, primaryColor: v || 'teal' },
                  })
                }
              />
            </Group>
            <Group grow>
              <Select
                label="Плотность"
                value={definition.theme?.density || 'comfortable'}
                data={[
                  { value: 'comfortable', label: 'Обычная' },
                  { value: 'compact', label: 'Компактная' },
                ]}
                onChange={(v) =>
                  setDefinition({
                    ...definition,
                    theme: { ...definition.theme, density: v as any },
                  })
                }
              />
              <Select
                label="Тема приложения"
                value={definition.theme?.mode || 'auto'}
                data={[
                  { value: 'auto', label: 'Общая тема' },
                  { value: 'light', label: 'Светлая' },
                  { value: 'dark', label: 'Тёмная' },
                ]}
                onChange={(v) =>
                  setDefinition({ ...definition, theme: { ...definition.theme, mode: v as any } })
                }
              />
            </Group>
            <Divider label="Структура данных" />
            {definition.entities.map((entity, i) => (
              <Paper key={entity.id} withBorder p="md">
                <Stack gap="sm">
                  <TextInput
                    label="Сущность"
                    value={entity.name}
                    onChange={(e) =>
                      setDefinition({
                        ...definition,
                        entities: definition.entities.map((x, n) =>
                          n === i ? { ...x, name: e.target.value } : x,
                        ),
                      })
                    }
                  />
                  {entity.fields.map((field, j) => (
                    <Group key={field.id} grow align="end">
                      <TextInput
                        label="Поле"
                        value={field.name}
                        onChange={(e) => {
                          const d = structuredClone(definition);
                          d.entities[i].fields[j].name = e.target.value;
                          setDefinition(d);
                        }}
                      />
                      <Select
                        label="Тип"
                        value={field.type}
                        data={[
                          { value: 'text', label: 'Текст' },
                          { value: 'number', label: 'Число' },
                          { value: 'boolean', label: 'Флажок' },
                          { value: 'date', label: 'Дата' },
                          { value: 'select', label: 'Список' },
                          { value: 'relation', label: 'Связь' },
                          { value: 'json', label: 'JSON' },
                        ]}
                        onChange={(v) => {
                          const d = structuredClone(definition);
                          d.entities[i].fields[j].type = v as any;
                          setDefinition(d);
                        }}
                      />
                      {field.type === 'select' && (
                        <TextInput
                          label="Варианты через запятую"
                          value={field.options?.join(', ') || ''}
                          onChange={(e) => {
                            const d = structuredClone(definition);
                            d.entities[i].fields[j].options = e.target.value
                              .split(',')
                              .map((x) => x.trim());
                            setDefinition(d);
                          }}
                        />
                      )}
                      {field.type === 'relation' && (
                        <Select
                          label="Связанная сущность"
                          value={field.targetEntity}
                          data={definition.entities.map((x) => ({ value: x.id, label: x.name }))}
                          onChange={(v) => {
                            const d = structuredClone(definition);
                            d.entities[i].fields[j].targetEntity = v || undefined;
                            setDefinition(d);
                          }}
                        />
                      )}
                      <Checkbox
                        label="Обязательное"
                        checked={field.required || false}
                        onChange={(e) => {
                          const d = structuredClone(definition);
                          d.entities[i].fields[j].required = e.currentTarget.checked;
                          setDefinition(d);
                        }}
                      />
                    </Group>
                  ))}
                  <Button
                    variant="subtle"
                    size="xs"
                    onClick={() => {
                      const d = structuredClone(definition);
                      d.entities[i].fields.push({
                        id: 'item_' + crypto.randomUUID().replaceAll('-', ''),
                        name: 'Новое поле',
                        type: 'text',
                      });
                      setDefinition(d);
                    }}
                  >
                    Добавить поле
                  </Button>
                </Stack>
              </Paper>
            ))}
            <Button
              variant="light"
              onClick={() =>
                setDefinition({
                  ...definition,
                  entities: [
                    ...definition.entities,
                    {
                      id: 'item_' + crypto.randomUUID().replaceAll('-', ''),
                      name: 'Новая сущность',
                      fields: [],
                    },
                  ],
                })
              }
            >
              Добавить сущность
            </Button>
            <Divider label="Экраны" />
            {definition.screens.map((screen, i) => (
              <Group key={screen.id} grow align="end">
                <TextInput
                  label="Название экрана"
                  value={screen.name}
                  onChange={(e) => {
                    const d = structuredClone(definition);
                    d.screens[i].name = e.target.value;
                    setDefinition(d);
                  }}
                />
                <Select
                  label="Вид"
                  value={screen.type}
                  data={[
                    { value: 'table', label: 'Таблица' },
                    { value: 'form', label: 'Форма' },
                    { value: 'board', label: 'Доска' },
                    { value: 'calendar', label: 'Календарь' },
                    { value: 'chart', label: 'График' },
                    { value: 'text', label: 'Текстовый редактор' },
                    { value: 'image', label: 'Растровый редактор' },
                    { value: 'converter', label: 'JSON, XML, YAML, Base64 и hex' },
                    { value: 'dashboard', label: 'Обзор' },
                  ]}
                  onChange={(v) => {
                    const d = structuredClone(definition);
                    d.screens[i].type = v as any;
                    setDefinition(d);
                  }}
                />
                <Select
                  label="Данные"
                  clearable
                  value={screen.entityId || null}
                  data={definition.entities.map((e) => ({ value: e.id, label: e.name }))}
                  onChange={(v) => {
                    const d = structuredClone(definition);
                    d.screens[i].entityId = v || undefined;
                    setDefinition(d);
                  }}
                />
              </Group>
            ))}
            <Button
              variant="light"
              onClick={() =>
                setDefinition({
                  ...definition,
                  screens: [
                    ...definition.screens,
                    {
                      id: 'item_' + crypto.randomUUID().replaceAll('-', ''),
                      name: 'Новый экран',
                      type: 'table',
                      entityId: definition.entities[0]?.id,
                    },
                  ],
                })
              }
            >
              Добавить экран
            </Button>
          </Stack>
        </Tabs.Panel>
        <Tabs.Panel value="code">
          <Text size="sm" c="dimmed" mb="sm">
            Дополнительные действия, автоматизации и расширения доступны в определении. Изменения
            сначала проверяются на существующих данных.
          </Text>
          <CodeMirror value={source} onChange={setSource} extensions={[json()]} height="430px" />
        </Tabs.Panel>
      </Tabs>
      {preview ? (
        <Alert color="teal" title="Изменения проверены" mt="lg">
          <Text size="sm">
            {Array.isArray(preview.changes)
              ? preview.changes.join('\n')
              : JSON.stringify(preview.changes)}
          </Text>
          {preview.warnings?.map((w: string) => (
            <Text key={w} c="orange" size="sm">
              {w}
            </Text>
          ))}
          <Button
            mt="md"
            onClick={async () => {
              const result = await perform(
                () => api('definitions.activate', { draftId: preview.draftId }),
                'Новая версия включена',
              );
              if (result) {
                onChanged();
                onClose();
              }
            }}
          >
            Применить новую версию
          </Button>
        </Alert>
      ) : (
        <Group justify="flex-end" mt="lg">
          <Button
            loading={busy}
            onClick={() =>
              prepare().catch((e) => {
                report(e);
                setBusy(false);
              })
            }
          >
            Проверить изменения
          </Button>
        </Group>
      )}
    </Modal>
  );
}
export function PackageProgress({ taskId }: { taskId?: string }) {
  const [task, setTask] = useState<any>();
  useEffect(() => {
    setTask(undefined);
    if (taskId)
      api('packages.taskStatus', { taskId })
        .then(setTask)
        .catch(() => {});
    return window.platform.onEvent((event) => {
      if (event.type === 'package.task' && (taskId ? event.id === taskId : event.kind === 'import'))
        setTask(event);
    });
  }, [taskId]);
  if (
    !task ||
    task.status === 'completed' ||
    (!taskId && ['cancelled', 'failed'].includes(task.status))
  )
    return null;
  const content = (
    <Stack gap="xs" role="status" aria-live="polite">
      <Text size="sm">
        {task.phase}
        {task.total > 0 ? ` · ${Math.round((task.completed / task.total) * 100)}%` : ''}
      </Text>
      <Progress
        value={task.total ? (task.completed / task.total) * 100 : 0}
        animated={task.status === 'running'}
      />
      {task.status === 'running' && (
        <Button
          variant="subtle"
          onClick={() => perform(() => api('packages.taskCancel', { taskId: task.id }))}
        >
          Отменить обработку
        </Button>
      )}
      {task.error && (
        <Text c="red" size="sm">
          {task.error}
        </Text>
      )}
    </Stack>
  );
  return taskId ? (
    content
  ) : (
    <Modal
      opened
      onClose={() => {}}
      withCloseButton={false}
      closeOnEscape={false}
      closeOnClickOutside={false}
      title="Открытие приложения"
      centered
    >
      {content}
    </Modal>
  );
}
export function ImportDialog({
  preview,
  onClose,
  onImported,
}: {
  preview: any;
  onClose: () => void;
  onImported: (app: AppInstance) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [installed, setInstalled] = useState<any>();
  const [accessOpen, setAccessOpen] = useState(false);
  useEffect(() => {
    setInstalled(undefined);
    setAccessOpen(false);
  }, [preview?.previewId]);
  const finish = () => {
    if (installed) onImported(installed.app);
    onClose();
  };
  if (installed)
    return (
      <>
        <Modal
          opened={!!preview && !accessOpen}
          onClose={finish}
          title="Приложение установлено"
          centered
        >
          <Stack>
            <Title order={3}>{installed.app.name}</Title>
            <Text size="sm">
              Перенесено записей:{' '}
              {installed.report?.records ?? installed.report?.recordsPreserved ?? 0}; документов:{' '}
              {installed.report?.documents || 0}; вложений: {installed.report?.attachments || 0}.
            </Text>
            {installed.report?.demoRecords > 0 && (
              <Text size="sm">
                Демонстрационных записей в пакете: {installed.report.demoRecords}. Они хранятся
                отдельно от ваших данных при следующем экспорте.
              </Text>
            )}
            <Alert title="Перед первым запуском">
              Разрешения не перенесены. Проверьте доступ и подключения; автоматизации выключены и
              включаются отдельно во «Входящих».
            </Alert>
            {installed.app.definition.permissions.length > 0 && (
              <Text size="sm">
                Запрашиваемые права: {installed.app.definition.permissions.join(', ')}.
              </Text>
            )}
            {(installed.report?.reconnect || []).map((connection: any, index: number) => (
              <Paper key={index} withBorder p="sm">
                <Text fw={500} size="sm">
                  {connection.name || connection.entityId || connection.id}
                </Text>
                <Text size="sm" c="dimmed">
                  {connection.kind === 'application'
                    ? 'В разделе «Доступ» выберите установленное приложение и нужную сущность, затем нажмите «Подключить чтение данных».'
                    : connection.kind === 'file' || connection.kind === 'folder'
                      ? 'Откройте приложение и заново выберите файл или папку на этом Mac.'
                      : 'Откройте настройки этого подключения в приложении и укажите данные своей учётной записи. Секреты отправителя не переносятся.'}
                </Text>
              </Paper>
            ))}
            <Button variant="default" onClick={() => setAccessOpen(true)}>
              Настроить доступ и связи
            </Button>
            <Button onClick={finish}>Открыть приложение</Button>
          </Stack>
        </Modal>
        <AppDetails
          app={installed.app}
          opened={accessOpen}
          initialTab="permissions"
          onClose={() => setAccessOpen(false)}
          onChanged={() => {}}
        />
      </>
    );

  return (
    <Modal
      opened={!!preview}
      onClose={onClose}
      title={preview?.updating ? 'Обновить приложение из файла' : 'Открыть приложение из файла'}
      centered
    >
      <Stack>
        <Title order={3}>{preview?.definition?.name || preview?.manifest?.name}</Title>
        <Text size="sm">
          {preview?.updating
            ? 'Определение будет обновлено. Ваши данные и совместимые персональные изменения сохранятся.'
            : 'Файл проверен. Приложение будет установлено как независимая копия.'}
        </Text>
        <Group>
          <Badge>{preview?.recordCount || 0} личных записей</Badge>
          {preview?.demoRecordCount > 0 && (
            <Badge>{preview.demoRecordCount} демонстрационных</Badge>
          )}
          <Badge>
            {Array.isArray(preview?.attachments)
              ? preview.attachments.length
              : preview?.attachments || 0}{' '}
            вложений
          </Badge>
        </Group>
        {preview?.requiredPermissions?.length > 0 && (
          <Alert color="orange" title="Потребуются разрешения">
            <Text size="sm">{preview.requiredPermissions.join(', ')}</Text>
            <Text size="xs" mt="xs">
              Разрешения не переносятся. Вы сможете выдать их после установки.
            </Text>
          </Alert>
        )}
        {preview?.warnings?.map((w: string) => (
          <Alert key={w} color="yellow">
            {w}
          </Alert>
        ))}
        <Group justify="flex-end">
          <Button variant="default" onClick={onClose}>
            Отмена
          </Button>
          <Button
            loading={busy}
            onClick={async () => {
              setBusy(true);
              const r = await perform(
                () =>
                  api(preview.updating ? 'packages.updateCommit' : 'packages.importCommit', {
                    previewId: preview.previewId,
                  }),
                'Приложение импортировано',
              );
              setBusy(false);
              if (r) {
                setInstalled(r.app ? r : { app: r, report: {} });
              }
            }}
          >
            {preview?.updating ? 'Обновить приложение' : 'Установить копию'}
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}
export function ExportDialog({
  app,
  opened,
  onClose,
}: {
  app: AppInstance;
  opened: boolean;
  onClose: () => void;
}) {
  const [mode, setMode] = useState('template');
  const [includeDemo, setIncludeDemo] = useState(false);
  const [demoSource, setDemoSource] = useState('[]');
  const [demoSaved, setDemoSaved] = useState(true);
  const [taskId, setTaskId] = useState<string>();
  const [entities, setEntities] = useState<string[]>(app.definition.entities.map((e) => e.id));
  const [documents, setDocuments] = useState<any[]>([]);
  const [documentIds, setDocumentIds] = useState<string[]>([]);
  const [attachments, setAttachments] = useState<any[]>([]);
  const [attachmentIds, setAttachmentIds] = useState<string[]>([]);
  const [preview, setPreview] = useState<any>();
  const [busy, setBusy] = useState(false);
  const selection = {
    appId: app.id,
    mode,
    includeDemo,
    entityIds: entities,
    documentIds: mode === 'data' ? documentIds : [],
    attachmentIds: mode === 'data' ? attachmentIds : [],
  };
  useEffect(() => {
    if (opened) {
      api('packages.demoGet', { appId: app.id })
        .then((data) => {
          setDemoSource(
            JSON.stringify(
              data.map(({ id, entityId, values }: any) => ({ id, entityId, values })),
              null,
              2,
            ),
          );
          setDemoSaved(true);
        })
        .catch(report);
      api('docs.list', { appId: app.id }).then(setDocuments).catch(report);
      api('attachments.list', { appId: app.id }).then(setAttachments).catch(report);
    }
  }, [opened]);
  useEffect(() => {
    if (opened) api('packages.preview', selection).then(setPreview).catch(report);
  }, [opened, mode, entities, documentIds, attachmentIds, includeDemo, demoSaved]);
  return (
    <Modal
      opened={opened}
      closeOnClickOutside={!busy}
      closeOnEscape={!busy}
      withCloseButton={!busy}
      onClose={onClose}
      title={`Экспорт · ${app.name}`}
      centered
    >
      <Stack>
        <Select
          label="Что включить в файл"
          value={mode}
          data={[
            { value: 'template', label: 'Только приложение — без личных данных' },
            { value: 'data', label: 'Приложение с выбранными данными' },
          ]}
          onChange={(v) => setMode(v || 'template')}
        />
        {mode === 'data' && (
          <>
            <MultiSelect
              label="Данные сущностей"
              value={entities}
              data={app.definition.entities.map((e) => ({ value: e.id, label: e.name }))}
              onChange={setEntities}
            />
            <MultiSelect
              label="Документы"
              placeholder={documents.length ? 'Выберите документы' : 'Документов пока нет'}
              value={documentIds}
              data={documents.map((d) => ({ value: d.id, label: d.name }))}
              onChange={setDocumentIds}
            />
            <MultiSelect
              label="Дополнительные вложения"
              description="Вложения выбранных записей включаются автоматически."
              value={attachmentIds}
              data={attachments.map((d) => ({ value: d.id, label: d.name }))}
              onChange={setAttachmentIds}
            />
          </>
        )}
        <Checkbox
          checked={includeDemo}
          onChange={(event) => setIncludeDemo(event.currentTarget.checked)}
          label="Добавить отдельные демонстрационные данные"
          disabled={busy}
        />
        {includeDemo && (
          <Accordion variant="contained">
            <Accordion.Item value="demo">
              <Accordion.Control>Демонстрационные записи</Accordion.Control>
              <Accordion.Panel>
                <Stack gap="sm">
                  <Text size="sm">
                    Введите вымышленные примеры. Личные записи сюда не копируются. Формат: массив
                    объектов с id, entityId и values. Вложения из личного хранилища запрещены.
                  </Text>
                  <CodeMirror
                    aria-label="Демонстрационные данные"
                    value={demoSource}
                    onChange={(value) => {
                      setDemoSource(value);
                      setDemoSaved(false);
                    }}
                    extensions={[json()]}
                    height="180px"
                    editable={!busy}
                  />
                  <Button
                    variant="default"
                    disabled={busy || demoSaved}
                    onClick={async () => {
                      const result = await perform(() =>
                        api('packages.demoSave', {
                          appId: app.id,
                          records: JSON.parse(demoSource),
                        }),
                      );
                      if (result) setDemoSaved(true);
                    }}
                  >
                    Проверить и сохранить примеры
                  </Button>
                </Stack>
              </Accordion.Panel>
            </Accordion.Item>
          </Accordion>
        )}
        <Alert color="gray">
          Ключи, системные разрешения и внешние пути не передаются. Получатель подключит их на своём
          Mac.
        </Alert>
        {preview && (
          <>
            <Text size="sm">
              Состав файла: {preview.recordCount || 0} личных записей ·{' '}
              {preview.demoRecordCount || 0} демонстрационных · {preview.attachments?.length || 0}{' '}
              вложений · {preview.documents?.length || 0} документов
            </Text>
            {preview.requiredPermissions?.length > 0 && (
              <Text size="xs" c="dimmed">
                Разрешения: {preview.requiredPermissions.join(', ')}
              </Text>
            )}
            {preview.warnings?.map((w: string) => (
              <Text c="orange" size="sm" key={w}>
                {w}
              </Text>
            ))}
          </>
        )}
        <PackageProgress taskId={taskId} />
        <Button
          disabled={includeDemo && !demoSaved}
          loading={busy}
          onClick={async () => {
            setBusy(true);
            const id = crypto.randomUUID();
            setTaskId(id);
            const r = await perform(() => api('packages.saveExport', { ...selection, taskId: id }));
            setBusy(false);
            if (r) onClose();
          }}
        >
          Сохранить файл приложения…
        </Button>
      </Stack>
    </Modal>
  );
}
export function AppDetails({
  app,
  initialTab = 'general',
  opened,
  onClose,
  onChanged,
}: {
  app: AppInstance;
  opened: boolean;
  onClose: () => void;
  onChanged: () => void;
  initialTab?: string;
}) {
  const [permissions, setPermissions] = useState<any[]>([]);
  const [history, setHistory] = useState<any[]>([]);
  const [snapshots, setSnapshots] = useState<any[]>([]);
  const [name, setName] = useState(app.name);
  const [icon, setIcon] = useState(app.icon);
  const [links, setLinks] = useState<any[]>([]);
  const [apps, setApps] = useState<AppInstance[]>([]);
  const [target, setTarget] = useState<string | null>(null);
  const [entity, setEntity] = useState<string | null>(null);
  const [reportData, setReportData] = useState<any>();
  const [transfer, setTransfer] = useState<'split' | 'merge'>('split');
  const [selected, setSelected] = useState<string[]>([]);
  const [transferName, setTransferName] = useState('');
  const refresh = () => {
    api('permissions.list', { appId: app.id }).then(setPermissions).catch(report);
    api('definitions.history', { appId: app.id }).then(setHistory).catch(report);
    api('snapshots.list', { appId: app.id }).then(setSnapshots).catch(report);
    api('links.list', { appId: app.id }).then(setLinks).catch(report);
    api('apps.list').then(setApps).catch(report);
  };
  useEffect(() => {
    if (opened) refresh();
  }, [opened, app.id]);
  const other = apps.find((a) => a.id === target);
  return (
    <Modal opened={opened} onClose={onClose} size="lg" title={`Приложение · ${app.name}`}>
      <Tabs defaultValue={initialTab}>
        <Tabs.List mb="lg">
          <Tabs.Tab value="general">Основное</Tabs.Tab>
          <Tabs.Tab value="permissions">Доступ</Tabs.Tab>
          <Tabs.Tab value="history">Восстановление</Tabs.Tab>
          <Tabs.Tab value="transfer">Перенос</Tabs.Tab>
        </Tabs.List>
        <Tabs.Panel value="general">
          <Stack>
            {app.description && (
              <Text size="sm" c="dimmed">
                {app.description}
              </Text>
            )}
            <Group>
              <TextInput
                label="Значок"
                w={90}
                value={icon}
                onChange={(e) => setIcon(e.target.value)}
              />
              <TextInput
                style={{ flex: 1 }}
                label="Название"
                value={name}
                onChange={(e) => setName(e.target.value)}
              />
            </Group>
            <Button
              onClick={() =>
                perform(
                  () => api('apps.updateMeta', { appId: app.id, name, icon }),
                  'Название сохранено',
                ).then(onChanged)
              }
            >
              Сохранить
            </Button>
            <Text size="xs" c="dimmed">
              Версия {app.version} · Исходная версия {app.sourceVersion}
            </Text>
            <Divider />
            {opened && <WindowPreferences appId={app.id} />}
            <Divider />
            <Group>
              <Button
                variant="default"
                onClick={() =>
                  perform(
                    () => api('apps.duplicate', { appId: app.id, withData: true }),
                    'Независимая копия создана',
                  ).then(onChanged)
                }
              >
                Дублировать с данными
              </Button>
              <Button
                variant="default"
                onClick={() =>
                  perform(() =>
                    api('apps.updateMeta', {
                      appId: app.id,
                      status: app.status === 'archived' ? 'stopped' : 'archived',
                    }),
                  ).then(() => {
                    onChanged();
                    onClose();
                  })
                }
              >
                {app.status === 'archived' ? 'Вернуть из архива' : 'Архивировать'}
              </Button>
            </Group>
            <Button
              color="red"
              variant="light"
              onClick={async () => {
                const deps = await perform(() => api('apps.delete', { appId: app.id }));
                if (
                  deps &&
                  window.confirm(
                    `Удалить «${app.name}» и все его данные? Связи: ${JSON.stringify(deps)}.`,
                  )
                ) {
                  await perform(() => api('apps.delete', { appId: app.id, confirm: true }));
                  onChanged();
                  onClose();
                }
              }}
            >
              Удалить приложение и данные…
            </Button>
          </Stack>
        </Tabs.Panel>
        <Tabs.Panel value="permissions">
          <Stack>
            <Text c="dimmed" size="sm">
              Права выдаются только этому экземпляру. Системные разрешения macOS настраиваются
              отдельно.
            </Text>
            {Array.from(
              new Set([...app.definition.permissions, ...permissions.map((p) => p.permission)]),
            ).map((p) => (
              <Switch
                key={p}
                label={p === 'system.media' ? 'Активность камеры и микрофона' : p}
                description={
                  p === 'system.media'
                    ? 'Проверять, используются ли устройства. Без записи звука и видео.'
                    : undefined
                }
                checked={permissions.some((x) => x.permission === p)}
                onChange={(e) =>
                  perform(() =>
                    api(e.currentTarget.checked ? 'permissions.grant' : 'permissions.revoke', {
                      appId: app.id,
                      permission: p,
                    }),
                  ).then(refresh)
                }
              />
            ))}
            {!app.definition.permissions.length && !permissions.length && (
              <Text size="sm">Приложение не запрашивает дополнительных прав.</Text>
            )}
            <Divider label="Подключение данных другого приложения" />
            <Select
              label="Источник данных"
              value={target}
              onChange={(v) => {
                setTarget(v);
                setEntity(null);
              }}
              data={apps
                .filter((a) => a.id !== app.id)
                .map((a) => ({ value: a.id, label: a.name }))}
            />
            <Select
              label="Доступная сущность"
              value={entity}
              onChange={setEntity}
              data={other?.definition.entities.map((e) => ({ value: e.id, label: e.name })) || []}
            />
            <Button
              disabled={!entity || !target}
              onClick={() =>
                perform(
                  () =>
                    api('links.grant', {
                      sourceAppId: app.id,
                      targetAppId: target,
                      entityId: entity,
                    }),
                  'Подключение создано',
                ).then(refresh)
              }
            >
              Подключить чтение данных
            </Button>
            {links.map((l) => (
              <Group key={l.id} justify="space-between">
                <Text size="sm">
                  {l.entityId} · {l.targetAppId}
                </Text>
                <Button
                  size="xs"
                  variant="subtle"
                  color="red"
                  onClick={() => perform(() => api('links.revoke', { id: l.id })).then(refresh)}
                >
                  Отозвать
                </Button>
              </Group>
            ))}
            <Divider label="Учётные записи и подключения" />
            <Connections appId={app.id} />
          </Stack>
        </Tabs.Panel>
        <Tabs.Panel value="history">
          <Stack>
            <Button
              variant="light"
              onClick={() =>
                perform(
                  () =>
                    api('snapshots.create', {
                      appId: app.id,
                      label: 'Ручная точка восстановления',
                    }),
                  'Точка восстановления создана',
                ).then(refresh)
              }
            >
              Создать точку восстановления
            </Button>
            {snapshots.map((s) => (
              <Paper key={s.id} withBorder p="sm">
                <Group justify="space-between">
                  <div>
                    <Text size="sm">{s.label || 'Снимок приложения'}</Text>
                    <Text size="xs" c="dimmed">
                      {new Date(s.createdAt).toLocaleString('ru')}
                    </Text>
                  </div>
                  <Button
                    size="xs"
                    color="orange"
                    variant="light"
                    onClick={async () => {
                      if (
                        window.confirm(
                          'Восстановить данные из этой точки? Текущие данные будут заменены, перед восстановлением будет создан защитный снимок.',
                        )
                      ) {
                        await perform(() =>
                          api('snapshots.restore', {
                            appId: app.id,
                            snapshotId: s.id,
                            confirm: true,
                          }),
                        );
                        refresh();
                        onChanged();
                      }
                    }}
                  >
                    Восстановить…
                  </Button>
                </Group>
              </Paper>
            ))}
            <Divider label="Версии определения" />
            {history.map((v) => (
              <Group key={v.version} justify="space-between">
                <Text size="sm">
                  Версия {v.version} · {new Date(v.createdAt).toLocaleString('ru')}
                </Text>
                <Button
                  size="xs"
                  variant="subtle"
                  onClick={async () => {
                    const draft = await perform(() =>
                      api('definitions.prepare', { appId: app.id, definition: v.definition }),
                    );
                    if (
                      draft &&
                      window.confirm(
                        'Вернуть это определение? Совместимость текущих данных проверена.',
                      )
                    ) {
                      await perform(() => api('definitions.activate', { draftId: draft.draftId }));
                      refresh();
                      onChanged();
                    }
                  }}
                >
                  Вернуть определение
                </Button>
              </Group>
            ))}
          </Stack>
        </Tabs.Panel>
        <Tabs.Panel value="transfer">
          <Stack>
            <Text size="sm" c="dimmed">
              Выделение и объединение создают независимую копию. Исходные приложения сохраняются.
            </Text>
            <Select
              label="Операция"
              value={transfer}
              data={[
                { value: 'split', label: 'Выделить часть приложения' },
                { value: 'merge', label: 'Объединить с другими приложениями' },
              ]}
              onChange={(v) => {
                setTransfer(v as any);
                setSelected([]);
                setReportData(undefined);
              }}
            />
            <MultiSelect
              label={transfer === 'split' ? 'Сущности' : 'Приложения'}
              value={selected}
              onChange={setSelected}
              data={
                transfer === 'split'
                  ? app.definition.entities.map((e) => ({ value: e.id, label: e.name }))
                  : apps.filter((a) => a.id !== app.id).map((a) => ({ value: a.id, label: a.name }))
              }
            />
            <TextInput
              label="Название нового приложения"
              value={transferName}
              onChange={(e) => setTransferName(e.target.value)}
            />
            <Button
              disabled={!selected.length || !transferName}
              onClick={() =>
                perform(() =>
                  api(
                    `apps.${transfer}Preview`,
                    transfer === 'split'
                      ? { appId: app.id, entityIds: selected, name: transferName }
                      : { appIds: [app.id, ...selected], name: transferName },
                  ),
                ).then(setReportData)
              }
            >
              Проверить перенос
            </Button>
            {reportData && (
              <Alert title="Предварительный результат">
                <Text>{reportData.recordCount} записей</Text>
                {reportData.warnings?.map((w: string) => (
                  <Text key={w} size="sm">
                    {w}
                  </Text>
                ))}
                <Button
                  mt="sm"
                  onClick={() =>
                    perform(
                      () => api(`apps.${transfer}Commit`, { previewId: reportData.previewId }),
                      'Новое приложение создано',
                    ).then(() => {
                      onChanged();
                      onClose();
                    })
                  }
                >
                  Создать независимую копию
                </Button>
              </Alert>
            )}
          </Stack>
        </Tabs.Panel>
      </Tabs>
    </Modal>
  );
}
