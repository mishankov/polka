import { workspaceTheme, workspaceVariables } from './theme';
import { useEffect, useState } from 'react';
import {
  ActionIcon,
  Alert,
  Badge,
  Button,
  Checkbox,
  Group,
  MantineProvider,
  Modal,
  NumberInput,
  Pagination,
  Paper,
  Select,
  Stack,
  Table,
  Tabs,
  Text,
  TextInput,
  Textarea,
  Title,
  Tooltip,
} from '@mantine/core';
import {
  IconArrowDown,
  IconArrowUp,
  IconCalendar,
  IconDots,
  IconEdit,
  IconPlus,
  IconSearch,
  IconTrash,
} from '@tabler/icons-react';
import {
  BarChart,
  Bar,
  CartesianGrid,
  XAxis,
  YAxis,
  Tooltip as ChartTooltip,
  ResponsiveContainer,
} from 'recharts';
import type {
  AppInstance,
  EntityDefinition,
  FieldDefinition,
  DataRecord,
  ScreenDefinition,
} from '../../shared/types';
import { api, AnyRecord, perform, report, useStorageValue } from './api';
import Documents, { Converter } from './Documents';
import { CustomExtension } from './CustomExtension';
function display(value: unknown) {
  if (value === null || value === undefined) return '—';
  if (typeof value === 'boolean') return value ? 'Да' : 'Нет';
  return typeof value === 'object' ? JSON.stringify(value) : String(value);
}
function Field({
  field,
  value,
  onChange,
  appId,
}: {
  field: FieldDefinition;
  value: any;
  onChange: (v: any) => void;
  appId: string;
}) {
  const [related, setRelated] = useState<{ value: string; label: string }[]>([]);
  const [relationSearch, setRelationSearch] = useState('');
  useEffect(() => {
    if (field.type === 'relation' && field.targetEntity)
      api('records.list', {
        appId,
        entityId: field.targetEntity,
        search: relationSearch,
        limit: 200,
      })
        .then((r: any) =>
          setRelated(
            r.records.map((x: any) => ({
              value: x.id,
              label: String(Object.values(x.values)[0] || x.id),
            })),
          ),
        )
        .catch(report);
  }, [field.id, relationSearch]);
  const common = { label: field.name, required: field.required };
  if (field.type === 'boolean')
    return (
      <Checkbox {...common} checked={!!value} onChange={(e) => onChange(e.currentTarget.checked)} />
    );
  if (field.type === 'number')
    return (
      <NumberInput
        {...common}
        value={value ?? ''}
        onChange={(v) => onChange(v === '' ? undefined : Number(v))}
      />
    );
  if (field.type === 'select' || field.type === 'relation')
    return (
      <Select
        {...common}
        searchable
        clearable
        data={field.type === 'select' ? field.options || [] : related}
        onSearchChange={field.type === 'relation' ? setRelationSearch : undefined}
        value={value || null}
        onChange={onChange}
      />
    );
  if (field.type === 'json')
    return (
      <Textarea
        {...common}
        autosize
        minRows={3}
        value={typeof value === 'object' ? JSON.stringify(value, null, 2) : value || ''}
        onChange={(e) => onChange(e.target.value)}
      />
    );
  return (
    <TextInput
      {...common}
      type={field.type === 'date' ? 'date' : 'text'}
      value={value ?? ''}
      onChange={(e) => onChange(e.target.value)}
    />
  );
}
function EntityView({ app, screen }: { app: AppInstance; screen: ScreenDefinition }) {
  const entity =
    app.definition.entities.find((e) => e.id === screen.entityId) || app.definition.entities[0];
  const prefKey = `table:${app.id}:${screen.id}`;
  const [records, setRecords] = useState<DataRecord[]>([]);
  const [total, setTotal] = useState(0);
  const [search, setSearch] = useState('');
  const [page, setPage] = useState(1);
  const [sort, setSort] = useState<{ field: string; direction: 'asc' | 'desc' } | undefined>(() =>
    useStorageValue(prefKey + ':sort', undefined),
  );
  const [widths, setWidths] = useState<Record<string, number>>(() =>
    useStorageValue(prefKey + ':widths', {}),
  );
  useEffect(() => {
    localStorage.setItem(prefKey + ':sort', JSON.stringify(sort || null));
  }, [sort]);
  const [editing, setEditing] = useState<DataRecord | 'new' | null>(null);
  const [values, setValues] = useState<AnyRecord>({});
  const [saving, setSaving] = useState(false);
  const [month, setMonth] = useState(new Date().toISOString().slice(0, 7));
  const [loading, setLoading] = useState(true);
  const refresh = () => {
    if (!entity) return;
    setLoading(true);
    api('records.list', {
      appId: app.id,
      entityId: entity.id,
      search,
      sort,
      offset: (page - 1) * 25,
      limit: screen.type === 'table' ? 25 : 500,
    })
      .then((r: any) => {
        setRecords(r.records);
        setTotal(r.total);
      })
      .catch(report)
      .finally(() => setLoading(false));
  };
  useEffect(() => {
    const timer = setTimeout(refresh, 180);
    return () => clearTimeout(timer);
  }, [app.id, entity?.id, search, page, sort, app.revision]);
  function edit(record: DataRecord | 'new') {
    setEditing(record);
    setValues(
      record === 'new'
        ? Object.fromEntries(
            (entity?.fields || []).map((f) => [
              f.id,
              f.default ?? (f.type === 'boolean' ? false : ''),
            ]),
          )
        : { ...record.values },
    );
  }
  async function save() {
    if (!entity) return;
    setSaving(true);
    try {
      const parsed = { ...values };
      for (const f of entity.fields) {
        if (f.type === 'json' && typeof parsed[f.id] === 'string' && parsed[f.id])
          parsed[f.id] = JSON.parse(parsed[f.id]);
        if (parsed[f.id] === '' && !f.required) delete parsed[f.id];
      }
      await api('records.upsert', {
        appId: app.id,
        entityId: entity.id,
        id: editing !== 'new' && editing ? editing.id : undefined,
        values: parsed,
      });
      setEditing(null);
      refresh();
    } catch (e) {
      report(e);
    }
    setSaving(false);
  }
  async function remove(r: DataRecord) {
    if (!window.confirm('Удалить эту запись? Это действие нельзя отменить.')) return;
    await perform(() => api('records.delete', { appId: app.id, entityId: entity!.id, id: r.id }));
    refresh();
  }
  if (!entity)
    return (
      <Alert title="Добавьте структуру данных">
        Попросите помощника добавить сущность и поля для этого экрана или откройте редактор
        определения в меню приложения.
      </Alert>
    );
  const fieldName = entity.fields[0];
  const groupField =
    entity.fields.find((f) => f.id === screen.config?.groupBy) ||
    entity.fields.find((f) => f.type === 'select');
  const dateField =
    entity.fields.find((f) => f.id === screen.config?.dateField) ||
    entity.fields.find((f) => f.type === 'date');
  const form = (
    <Stack>
      {entity.fields.map((f) => (
        <Field
          key={f.id}
          field={f}
          value={values[f.id]}
          appId={app.id}
          onChange={(v) => setValues({ ...values, [f.id]: v })}
        />
      ))}
      <Group justify="flex-end">
        <Button variant="default" onClick={() => setEditing(null)}>
          Отмена
        </Button>
        <Button loading={saving} onClick={save}>
          Сохранить запись
        </Button>
      </Group>
    </Stack>
  );
  return (
    <Stack>
      <Group justify="space-between">
        <TextInput
          leftSection={<IconSearch size={16} />}
          placeholder="Найти в записях"
          aria-label="Найти в записях"
          value={search}
          onChange={(e) => {
            setSearch(e.target.value);
            setPage(1);
          }}
        />
        <Group>
          <Text c="dimmed" size="sm">
            {total} записей
          </Text>
          <Button leftSection={<IconPlus size={16} />} onClick={() => edit('new')}>
            Добавить запись
          </Button>
        </Group>
      </Group>
      {screen.type === 'form' ? (
        <Paper withBorder p="xl">
          <Title order={3} mb="lg">
            Новая запись · {entity.name}
          </Title>
          {editing === 'new' ? form : <Button onClick={() => edit('new')}>Заполнить форму</Button>}
        </Paper>
      ) : screen.type === 'board' ? (
        <div className="board">
          {(groupField?.options || ['Все записи']).map((option) => (
            <Paper
              key={option}
              withBorder
              p="md"
              className="board-column"
              onDragOver={(e) => e.preventDefault()}
              onDrop={async (e) => {
                const id = e.dataTransfer.getData('record');
                const row = records.find((r) => r.id === id);
                if (row && groupField) {
                  await perform(() =>
                    api('records.upsert', {
                      appId: app.id,
                      entityId: entity.id,
                      id,
                      values: { ...row.values, [groupField.id]: option },
                    }),
                  );
                  refresh();
                }
              }}
            >
              <Group justify="space-between" mb="md">
                <Text fw={600}>{option}</Text>
                <Badge variant="light">
                  {records.filter((r) => !groupField || r.values[groupField.id] === option).length}
                </Badge>
              </Group>
              <Stack gap="sm">
                {records
                  .filter((r) => !groupField || r.values[groupField.id] === option)
                  .map((r) => (
                    <Paper
                      key={r.id}
                      p="sm"
                      withBorder
                      draggable
                      onDragStart={(e) => e.dataTransfer.setData('record', r.id)}
                      onClick={() => edit(r)}
                      className="board-card"
                      tabIndex={0}
                      onKeyDown={(e) => e.key === 'Enter' && edit(r)}
                    >
                      <Text fw={500}>{display(r.values[fieldName?.id])}</Text>
                      {entity.fields.slice(1, 3).map((f) => (
                        <Text size="xs" c="dimmed" key={f.id}>
                          {f.name}: {display(r.values[f.id])}
                        </Text>
                      ))}
                    </Paper>
                  ))}
              </Stack>
            </Paper>
          ))}
        </div>
      ) : screen.type === 'calendar' ? (
        <>
          <TextInput
            type="month"
            w={220}
            aria-label="Месяц календаря"
            value={month}
            onChange={(e) => setMonth(e.target.value)}
          />
          {!dateField ? (
            <Alert>Добавьте поле даты, чтобы записи появились в календаре.</Alert>
          ) : (
            <div className="calendar">
              {Array.from(
                {
                  length: new Date(
                    Number(month.slice(0, 4)),
                    Number(month.slice(5, 7)),
                    0,
                  ).getDate(),
                },
                (_, i) => {
                  const date = `${month}-${String(i + 1).padStart(2, '0')}`;
                  return (
                    <Paper key={date} withBorder p="xs" className="calendar-day">
                      <Text size="xs" c="dimmed">
                        {i + 1}
                      </Text>
                      {records
                        .filter((r) => String(r.values[dateField.id] || '').startsWith(date))
                        .map((r) => (
                          <Button
                            key={r.id}
                            fullWidth
                            size="compact-xs"
                            mt={4}
                            variant="light"
                            onClick={() => edit(r)}
                          >
                            {display(r.values[fieldName?.id])}
                          </Button>
                        ))}
                    </Paper>
                  );
                },
              )}
            </div>
          )}
        </>
      ) : screen.type === 'chart' ? (
        <Paper withBorder p="lg">
          <ResponsiveContainer width="100%" height={350}>
            <BarChart data={records.map((r) => r.values)}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey={String(screen.config?.xField || fieldName?.id)} />
              <YAxis />
              <ChartTooltip />
              <Bar
                dataKey={String(
                  screen.config?.yField ||
                    entity.fields.find((f) => f.type === 'number')?.id ||
                    fieldName?.id,
                )}
                fill="var(--mantine-primary-color-filled)"
                radius={[5, 5, 0, 0]}
              />
            </BarChart>
          </ResponsiveContainer>
        </Paper>
      ) : (
        <Paper withBorder className="table-container">
          <Table.ScrollContainer minWidth={500}>
            <Table highlightOnHover verticalSpacing="sm">
              <Table.Thead>
                <Table.Tr>
                  {entity.fields.map((f) => (
                    <Table.Th
                      key={f.id}
                      style={{ width: widths[f.id] || 160, minWidth: widths[f.id] || 160 }}
                    >
                      <div
                        style={{
                          width: widths[f.id] || 150,
                          minWidth: 90,
                          resize: 'horizontal',
                          overflow: 'auto',
                        }}
                        onMouseUp={(e) => {
                          const next = {
                            ...widths,
                            [f.id]: Math.round(e.currentTarget.getBoundingClientRect().width),
                          };
                          setWidths(next);
                          localStorage.setItem(prefKey + ':widths', JSON.stringify(next));
                        }}
                      >
                        <Button
                          size="compact-xs"
                          variant="transparent"
                          color="gray"
                          onClick={() =>
                            setSort({
                              field: f.id,
                              direction:
                                sort?.field === f.id && sort.direction === 'asc' ? 'desc' : 'asc',
                            })
                          }
                        >
                          {f.name}
                          {sort?.field === f.id &&
                            (sort.direction === 'asc' ? (
                              <IconArrowUp size={12} />
                            ) : (
                              <IconArrowDown size={12} />
                            ))}
                        </Button>
                      </div>
                    </Table.Th>
                  ))}
                  <Table.Th w={85} />
                </Table.Tr>
              </Table.Thead>
              <Table.Tbody>
                {records.map((r) => (
                  <Table.Tr key={r.id}>
                    {entity.fields.map((f) => (
                      <Table.Td key={f.id}>
                        <Text size="sm" lineClamp={2}>
                          {f.type === 'select' ? (
                            <Badge variant="light">{display(r.values[f.id])}</Badge>
                          ) : (
                            display(r.values[f.id])
                          )}
                        </Text>
                      </Table.Td>
                    ))}
                    <Table.Td>
                      <Group gap={4} wrap="nowrap">
                        <ActionIcon
                          aria-label="Изменить запись"
                          variant="subtle"
                          onClick={() => edit(r)}
                        >
                          <IconEdit size={16} />
                        </ActionIcon>
                        <ActionIcon
                          aria-label="Удалить запись"
                          color="red"
                          variant="subtle"
                          onClick={() => remove(r)}
                        >
                          <IconTrash size={16} />
                        </ActionIcon>
                      </Group>
                    </Table.Td>
                  </Table.Tr>
                ))}
              </Table.Tbody>
            </Table>
          </Table.ScrollContainer>
          {!records.length && (
            <div className="empty-state">
              <Text fw={500}>
                {loading ? 'Загружаем записи…' : search ? 'Ничего не найдено' : 'Пока нет записей'}
              </Text>
              <Text size="sm" c="dimmed">
                {search
                  ? 'Попробуйте другой запрос.'
                  : 'Добавьте первую запись, чтобы начать работу.'}
              </Text>
            </div>
          )}
        </Paper>
      )}
      {screen.type === 'table' && total > 25 && (
        <Pagination total={Math.ceil(total / 25)} value={page} onChange={setPage} />
      )}
      <Modal
        opened={editing !== null && !(screen.type === 'form' && editing === 'new')}
        onClose={() => setEditing(null)}
        title={editing === 'new' ? 'Новая запись' : 'Изменить запись'}
        centered
      >
        {form}
      </Modal>
    </Stack>
  );
}
export default function Runtime({
  app,
  screenId,
  onScreenChange,
  onEdit,
  standalone = false,
}: {
  app: AppInstance;
  screenId?: string;
  onScreenChange: (id: string) => void;
  onEdit?: () => void;
  standalone?: boolean;
}) {
  const screens = app.definition.screens;
  const [screenControls, setScreenControls] = useState<HTMLDivElement | null>(null);
  const screen = screens.find((s) => s.id === screenId) || screens[0];
  const theme = app.definition.theme;
  return (
    <MantineProvider
      cssVariablesResolver={workspaceVariables}
      theme={{
        ...workspaceTheme,
        primaryColor: theme?.primaryColor || workspaceTheme.primaryColor,
        defaultRadius: theme?.radius || workspaceTheme.defaultRadius,
        ...(theme?.density === 'compact'
          ? { spacing: { xs: '0.4rem', sm: '0.6rem', md: '0.8rem', lg: '1rem', xl: '1.4rem' } }
          : {}),
      }}
      forceColorScheme={theme?.mode === 'light' || theme?.mode === 'dark' ? theme.mode : undefined}
    >
      <div className={`runtime-page${screen?.type === 'custom' ? ' runtime-custom' : ''}`}>
        <ActionToolbar app={app} />
        {(screens.length > 1 || (!standalone && screen?.type === 'custom')) && (
          <div className="runtime-navigation">
            {screens.length > 1 && (
              <Tabs
                className="runtime-tabs"
                value={screen?.id}
                onChange={(v) => v && onScreenChange(v)}
              >
                <Tabs.List aria-label="Экраны приложения">
                  {screens.map((s) => (
                    <Tabs.Tab key={s.id} value={s.id}>
                      {s.name}
                    </Tabs.Tab>
                  ))}
                </Tabs.List>
              </Tabs>
            )}
            {!standalone && screen?.type === 'custom' && (
              <div className="runtime-screen-controls" ref={setScreenControls} />
            )}
          </div>
        )}
        {!screen ? (
          <div className="empty-state">
            <Text fw={500}>Приложение готово к наполнению</Text>
            <Text size="sm" c="dimmed" maw={400} my="sm">
              {standalone
                ? 'Добавьте экраны в рабочем пространстве, чтобы начать работу.'
                : 'Опишите помощнику нужные экраны и действия или добавьте их самостоятельно.'}
            </Text>
            {!standalone && (
              <Button variant="light" onClick={onEdit}>
                Добавить экран
              </Button>
            )}
          </div>
        ) : screen.type === 'text' || screen.type === 'image' ? (
          <Documents
            key={app.id + screen.id}
            appId={app.id}
            kind={screen.type === 'image' ? 'image' : 'text'}
          />
        ) : screen.type === 'converter' ? (
          <Converter appId={app.id} config={screen.config} />
        ) : screen.type === 'custom' && app.status !== 'running' ? (
          <Stack gap="sm" align="flex-start" p="md">
            <Text c="dimmed">Приложение остановлено</Text>
            <Button
              variant="default"
              onClick={() => api('apps.start', { appId: app.id }).catch(report)}
            >
              Открыть снова
            </Button>
          </Stack>
        ) : screen.type === 'custom' ? (
          <CustomExtension
            key={`${app.id}:${screen.id}:${app.version}`}
            appId={app.id}
            extensionId={String(screen.config?.extensionId || '')}
            controlsHost={standalone ? null : screenControls}
          />
        ) : screen.type === 'dashboard' ? (
          <div className="dashboard-grid">
            {app.definition.entities.map((e) => (
              <EntitySummary key={e.id} appId={app.id} entity={e} />
            ))}
          </div>
        ) : (
          <EntityView key={app.id + screen.id} app={app} screen={screen} />
        )}
      </div>
    </MantineProvider>
  );
}
function EntitySummary({ appId, entity }: { appId: string; entity: EntityDefinition }) {
  const [total, setTotal] = useState(0);
  useEffect(() => {
    api('records.list', { appId, entityId: entity.id, limit: 1 })
      .then((r: any) => setTotal(r.total))
      .catch(report);
  }, [appId, entity.id]);
  return (
    <Paper p="xl" withBorder>
      <Text c="dimmed" size="sm">
        {entity.name}
      </Text>
      <Title order={1} mt="sm">
        {total}
      </Title>
      <Text size="xs" c="dimmed">
        записей
      </Text>
    </Paper>
  );
}
function ActionToolbar({ app }: { app: AppInstance }) {
  const [job, setJob] = useState<any>();
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (!job || !['queued', 'running'].includes(job.status)) return;
    const id = setInterval(
      () =>
        api('jobs.list', { appId: app.id })
          .then((jobs: any[]) => {
            const current = jobs.find((j) => j.id === job.id);
            if (current) setJob(current);
          })
          .catch(report),
      600,
    );
    return () => clearInterval(id);
  }, [job?.id, job?.status]);
  if (!app.definition.actions.length) return null;
  return (
    <>
      <Group mb="sm" gap="xs">
        {app.definition.actions.map((action) => (
          <Button
            key={action.id}
            size="sm"
            variant="light"
            onClick={async () => {
              const result = await perform(async () => {
                if (app.status !== 'running')
                  await api('apps.updateMeta', { appId: app.id, status: 'running' });
                return api('jobs.enqueue', { appId: app.id, actionId: action.id });
              });
              if (result) {
                setJob(result);
                setOpen(true);
              }
            }}
          >
            {action.name}
          </Button>
        ))}
      </Group>
      <Modal opened={open} onClose={() => setOpen(false)} title="Результат действия">
        <Stack>
          {['queued', 'running'].includes(job?.status) ? (
            <>
              <Text>
                Действие выполняется… Окно можно закрыть: результат останется во входящих.
              </Text>
              <Button
                variant="default"
                onClick={() => perform(() => api('jobs.cancel', { jobId: job.id })).then(setJob)}
              >
                Отменить
              </Button>
            </>
          ) : job?.error ? (
            <Alert color="red">{job.error}</Alert>
          ) : (
            <Text style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
              {typeof job?.result === 'string'
                ? job.result
                : JSON.stringify(job?.result, null, 2) || 'Готово'}
            </Text>
          )}
        </Stack>
      </Modal>
    </>
  );
}
