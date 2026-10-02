import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import {
  Alert,
  Button,
  Card as MantineCard,
  Group,
  Loader,
  NumberInput,
  Progress,
  Select,
  Stack,
  Table,
  Text,
  TextInput,
  Checkbox,
} from '@mantine/core';
import type { EntityDefinition, DataRecord } from '../shared/types';
export interface ExtensionSDK {
  call<T = any>(method: string, params?: unknown): Promise<T>;
}
export const SDKContext = createContext<ExtensionSDK | null>(null);
export function useSDK() {
  const sdk = useContext(SDKContext);
  if (!sdk) throw Error('Компонент должен работать внутри экрана Everything App');
  return sdk;
}
export const Card = MantineCard;
export function ErrorView({ error }: { error: unknown }) {
  return error ? (
    <Alert color="red" title="Не удалось выполнить действие" role="alert">
      {error instanceof Error ? error.message : String(error)}
    </Alert>
  ) : null;
}
export function EntityForm({
  entity,
  record,
  onSaved,
}: {
  entity: EntityDefinition;
  record?: DataRecord;
  onSaved?: (record: DataRecord) => void;
}) {
  const sdk = useSDK();
  const [values, setValues] = useState<Record<string, any>>(
    () =>
      record?.values ||
      Object.fromEntries(
        entity.fields.map((f) => [f.id, f.default ?? (f.type === 'boolean' ? false : '')]),
      ),
  );
  const [busy, setBusy] = useState(false),
    [error, setError] = useState<unknown>();
  useEffect(() => {
    setValues(
      record?.values ||
        Object.fromEntries(
          entity.fields.map((f) => [f.id, f.default ?? (f.type === 'boolean' ? false : '')]),
        ),
    );
    setError(null);
  }, [entity.id, record?.id]);
  const field = (id: string, value: unknown) => setValues((old) => ({ ...old, [id]: value }));
  return (
    <form
      onSubmit={async (e) => {
        e.preventDefault();
        setBusy(true);
        setError(null);
        try {
          const result = await sdk.call('records.upsert', {
            entityId: entity.id,
            id: record?.id,
            values,
          });
          onSaved?.(result);
        } catch (e) {
          setError(e);
        } finally {
          setBusy(false);
        }
      }}
    >
      <Stack gap="sm">
        {entity.fields.map((f) =>
          f.type === 'boolean' ? (
            <Checkbox
              key={f.id}
              label={f.name}
              checked={!!values[f.id]}
              onChange={(e) => field(f.id, e.currentTarget.checked)}
            />
          ) : f.type === 'number' ? (
            <NumberInput
              key={f.id}
              label={f.name}
              required={f.required}
              value={values[f.id]}
              onChange={(v) => field(f.id, v)}
            />
          ) : f.type === 'select' ? (
            <Select
              key={f.id}
              label={f.name}
              required={f.required}
              data={f.options || []}
              value={values[f.id] || null}
              onChange={(v) => field(f.id, v)}
            />
          ) : f.type === 'relation' ? (
            <RelatedRecordSelect
              key={f.id}
              label={f.name}
              entityId={f.targetEntity!}
              value={values[f.id] || null}
              onChange={(v) => field(f.id, v)}
            />
          ) : (
            <TextInput
              key={f.id}
              label={f.name}
              required={f.required}
              type={f.type === 'date' ? 'date' : 'text'}
              value={
                typeof values[f.id] === 'object'
                  ? JSON.stringify(values[f.id])
                  : String(values[f.id] ?? '')
              }
              onChange={(e) =>
                field(
                  f.id,
                  f.type === 'json'
                    ? (() => {
                        try {
                          return JSON.parse(e.currentTarget.value);
                        } catch {
                          return e.currentTarget.value;
                        }
                      })()
                    : e.currentTarget.value,
                )
              }
            />
          ),
        )}
        <ErrorView error={error} />
        <Button type="submit" loading={busy}>
          Сохранить
        </Button>
      </Stack>
    </form>
  );
}
function useRecords(entityId: string, refresh = 0) {
  const sdk = useSDK(),
    [records, setRecords] = useState<DataRecord[]>([]),
    [error, setError] = useState<unknown>(),
    [loading, setLoading] = useState(true);
  useEffect(() => {
    let active = true;
    setLoading(true);
    sdk
      .call('records.list', { entityId, limit: 500 })
      .then((result) => {
        if (active) {
          setRecords(Array.isArray(result) ? result : result.items || result.records || []);
          setError(null);
        }
      })
      .catch((e) => active && setError(e))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [sdk, entityId, refresh]);
  return { records, error, loading };
}
export function RecordTable({
  entity,
  onSelect,
  refresh = 0,
}: {
  entity: EntityDefinition;
  onSelect?: (record: DataRecord) => void;
  refresh?: number;
}) {
  const { records, error, loading } = useRecords(entity.id, refresh),
    [query, setQuery] = useState('');
  return (
    <Stack gap="sm">
      <TextInput
        label={`Поиск · ${entity.name}`}
        value={query}
        onChange={(e) => setQuery(e.currentTarget.value)}
      />
      <ErrorView error={error} />
      {loading ? (
        <Loader size="sm" />
      ) : (
        <Table.ScrollContainer minWidth={400}>
          <Table>
            <Table.Thead>
              <Table.Tr>
                {entity.fields.map((f) => (
                  <Table.Th key={f.id}>{f.name}</Table.Th>
                ))}
                {onSelect && <Table.Th>Выбор</Table.Th>}
              </Table.Tr>
            </Table.Thead>
            <Table.Tbody>
              {records
                .filter((r) => JSON.stringify(r.values).toLowerCase().includes(query.toLowerCase()))
                .map((r) => (
                  <Table.Tr key={r.id}>
                    {entity.fields.map((f) => (
                      <Table.Td key={f.id}>
                        {typeof r.values[f.id] === 'object'
                          ? JSON.stringify(r.values[f.id])
                          : String(r.values[f.id] ?? '')}
                      </Table.Td>
                    ))}
                    {onSelect && (
                      <Table.Td>
                        <Button size="xs" variant="subtle" onClick={() => onSelect(r)}>
                          Выбрать
                        </Button>
                      </Table.Td>
                    )}
                  </Table.Tr>
                ))}
            </Table.Tbody>
          </Table>
        </Table.ScrollContainer>
      )}
      {!loading && !records.length && <Text c="dimmed">Записей пока нет</Text>}
      <Text size="xs" c="dimmed">
        Показано до 500 записей
      </Text>
    </Stack>
  );
}
export function RelatedRecordSelect({
  entityId,
  label,
  value,
  onChange,
}: {
  entityId: string;
  label: string;
  value: string | null;
  onChange: (value: string | null) => void;
}) {
  const { records, error, loading } = useRecords(entityId);
  return (
    <Select
      label={label}
      searchable
      clearable
      disabled={loading}
      error={error ? String(error) : undefined}
      value={value}
      onChange={onChange}
      data={records.map((r) => ({
        value: r.id,
        label: String(Object.values(r.values)[0] ?? r.id),
      }))}
    />
  );
}
export function ActionButton({
  actionId,
  input,
  children,
  onComplete,
}: {
  actionId: string;
  input?: unknown;
  children: ReactNode;
  onComplete?: (job: any) => void;
}) {
  const sdk = useSDK(),
    [busy, setBusy] = useState(false),
    [error, setError] = useState<unknown>();
  return (
    <Stack gap="xs">
      <Button
        loading={busy}
        onClick={async () => {
          setBusy(true);
          setError(null);
          try {
            onComplete?.(await sdk.call('actions.run', { actionId, input }));
          } catch (e) {
            setError(e);
          } finally {
            setBusy(false);
          }
        }}
      >
        {children}
      </Button>
      <ErrorView error={error} />
    </Stack>
  );
}
export function JobProgress({ jobId }: { jobId: string }) {
  const sdk = useSDK(),
    [job, setJob] = useState<any>(),
    [error, setError] = useState<unknown>();
  useEffect(() => {
    let active = true;
    const poll = async () => {
      try {
        const jobs = await sdk.call<any[]>('jobs.list');
        if (active) setJob(jobs.find((j) => j.id === jobId));
      } catch (e) {
        if (active) setError(e);
      }
    };
    void poll();
    const timer = setInterval(poll, 1500);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, [sdk, jobId]);
  return (
    <Stack gap="xs">
      <ErrorView error={error} />
      <Text size="sm">{job?.status || 'Ожидание задания'}</Text>
      <Progress aria-label="Ход задания" value={Math.round((job?.progress || 0) * 100)} />
      {job && ['pending', 'queued', 'running'].includes(job.status) && (
        <Button variant="subtle" onClick={() => sdk.call('jobs.cancel', { jobId }).catch(setError)}>
          Отменить задание
        </Button>
      )}
    </Stack>
  );
}
export function HistoryList({
  items,
}: {
  items: { id: string; title: string; detail?: string; time?: string }[];
}) {
  return (
    <Stack gap="xs">
      {items.length ? (
        items.map((item) => (
          <MantineCard key={item.id} withBorder>
            <Group justify="space-between">
              <Text>{item.title}</Text>
              <Text size="xs" c="dimmed">
                {item.time}
              </Text>
            </Group>
            {item.detail && (
              <Text size="sm" c="dimmed">
                {item.detail}
              </Text>
            )}
          </MantineCard>
        ))
      ) : (
        <Text c="dimmed">История пока пуста</Text>
      )}
    </Stack>
  );
}

/** Lightweight views take the same records as RecordTable; filtering remains explicit. */
export function Board({
  records,
  groupField,
  titleField,
  columns,
}: {
  records: DataRecord[];
  groupField: string;
  titleField: string;
  columns: string[];
}) {
  return (
    <Group align="start" wrap="nowrap" style={{ overflowX: 'auto' }}>
      {columns.map((column) => (
        <Stack key={column} style={{ minWidth: 200, flex: 1 }}>
          <Text fw={600}>{column}</Text>
          {records
            .filter((record) => String(record.values[groupField] ?? '') === column)
            .map((record) => (
              <MantineCard withBorder key={record.id}>
                {String(record.values[titleField] ?? record.id)}
              </MantineCard>
            ))}
        </Stack>
      ))}
    </Group>
  );
}
export function CalendarView({
  records,
  dateField,
  titleField,
}: {
  records: DataRecord[];
  dateField: string;
  titleField: string;
}) {
  const dates = [
    ...new Set(
      records.map((record) => String(record.values[dateField] || '').slice(0, 10)).filter(Boolean),
    ),
  ].sort();
  return (
    <Stack>
      {dates.length ? (
        dates.map((date) => (
          <section key={date}>
            <Text component="h3" fw={600}>
              {date}
            </Text>
            {records
              .filter((record) => String(record.values[dateField] || '').startsWith(date))
              .map((record) => (
                <MantineCard withBorder key={record.id} mt="xs">
                  {String(record.values[titleField] ?? record.id)}
                </MantineCard>
              ))}
          </section>
        ))
      ) : (
        <Text c="dimmed">Нет записей с датой</Text>
      )}
    </Stack>
  );
}
