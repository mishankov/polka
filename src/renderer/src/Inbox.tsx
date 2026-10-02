import { useEffect, useState } from 'react';
import {
  Accordion,
  Alert,
  Badge,
  Button,
  Group,
  Modal,
  NumberInput,
  Paper,
  Progress,
  Select,
  Stack,
  Switch,
  Tabs,
  Text,
  TextInput,
  Title,
} from '@mantine/core';
import { IconClock, IconRepeat } from '@tabler/icons-react';
import type { AppInstance } from '../../shared/types';
import { api, perform, report, AnyRecord } from './api';
const statuses: AnyRecord = {
  queued: 'В очереди',
  running: 'Выполняется',
  completed: 'Завершено',
  failed: 'Ошибка',
  cancelled: 'Отменено',
  interrupted: 'Прервано',
};
export default function Inbox({ apps }: { apps: AppInstance[] }) {
  const [jobs, setJobs] = useState<any[]>([]);
  const [automations, setAutomations] = useState<any[]>([]);
  const [media, setMedia] = useState<any>();
  const [opened, setOpened] = useState(false);
  const [appId, setAppId] = useState<string | null>(null);
  const [actionId, setActionId] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [trigger, setTrigger] = useState('interval');
  const [interval, setIntervalValue] = useState<number | string>(60);
  const [hour, setHour] = useState<number | string>(9);
  const [minute, setMinute] = useState<number | string>(0);
  const [missed, setMissed] = useState('skip');
  const [editingId, setEditingId] = useState<string>();
  const [ruleEnabled, setRuleEnabled] = useState(true);
  const [conditions, setConditions] = useState<{ path: string; operator: string; value: string }[]>(
    [],
  );
  const app = apps.find((a) => a.id === appId);
  function beginRule(a?: any) {
    setEditingId(a?.id);
    setRuleEnabled(a?.enabled ?? true);
    setName(a?.name || '');
    setAppId(a?.appId || null);
    setActionId(a?.actionId || null);
    setTrigger(a?.trigger || 'interval');
    setIntervalValue((a?.intervalMs || 60000) / 1000);
    setHour(a?.config?.hour ?? 9);
    setMinute(a?.config?.minute ?? 0);
    setMissed(a?.config?.missed || 'skip');
    setConditions(
      (a?.config?.conditions || []).map((c: any) => ({
        ...c,
        value: typeof c.value === 'string' ? c.value : JSON.stringify(c.value),
      })),
    );
    setOpened(true);
  }
  const refresh = () => {
    api('jobs.list').then(setJobs).catch(report);
    api('automations.list').then(setAutomations).catch(report);
  };
  useEffect(() => {
    refresh();
    api('system.media')
      .then(setMedia)
      .catch(() => {});
    const id = setInterval(refresh, 4000);
    return () => clearInterval(id);
  }, []);
  return (
    <div className="page inbox-page">
      <header className="page-heading">
        <Title order={1}>Входящие</Title>
        <Text c="dimmed" size="sm">
          Результаты и дела, которые продолжаются в фоне.
        </Text>
      </header>
      <Tabs defaultValue="jobs" className="workspace-tabs">
        <Tabs.List mb="xl">
          <Tabs.Tab value="jobs">Задания</Tabs.Tab>
          <Tabs.Tab value="automations">Автоматизации</Tabs.Tab>
          <Tabs.Tab value="system">Состояние системы</Tabs.Tab>
        </Tabs.List>
        <Tabs.Panel value="jobs">
          <Stack gap={0} className="activity-list">
            {!jobs.length && (
              <div className="inbox-empty">
                <IconClock size={25} stroke={1.3} aria-hidden="true" />
                <Text fw={500} mt="md">
                  Сейчас всё спокойно
                </Text>
                <Text c="dimmed" size="sm" mt={6}>
                  Когда приложение начнёт работу в фоне, её ход и результат появятся здесь.
                </Text>
              </div>
            )}
            {jobs.map((j) => (
              <section key={j.id} className="activity-row">
                <Group justify="space-between">
                  <div>
                    <Text fw={500}>
                      {apps.find((a) => a.id === j.appId)?.name || 'Приложение'} · {j.actionId}
                    </Text>
                    <Text size="xs" c="dimmed">
                      {new Date(j.createdAt).toLocaleString('ru')}
                    </Text>
                  </div>
                  <Badge
                    variant="light"
                    size="sm"
                    color={
                      j.status === 'failed' ? 'red' : j.status === 'completed' ? 'sage' : 'orange'
                    }
                  >
                    {statuses[j.status] || j.status}
                  </Badge>
                </Group>
                {j.status === 'running' && (
                  <Progress value={(j.progress || 0) * 100} mt="md" animated />
                )}
                {j.error && (
                  <Alert color="red" mt="sm">
                    {j.error}
                  </Alert>
                )}
                {j.result && (
                  <Text
                    className="activity-result"
                    size="sm"
                    mt="sm"
                    style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}
                  >
                    {typeof j.result === 'string' ? j.result : JSON.stringify(j.result, null, 2)}
                  </Text>
                )}
                {['queued', 'running'].includes(j.status) && (
                  <Button
                    size="xs"
                    variant="subtle"
                    mt="sm"
                    onClick={() => perform(() => api('jobs.cancel', { jobId: j.id })).then(refresh)}
                  >
                    Отменить задание
                  </Button>
                )}
              </section>
            ))}
          </Stack>
        </Tabs.Panel>
        <Tabs.Panel value="automations">
          <Stack>
            <Group justify="space-between">
              <Text size="sm" c="dimmed">
                Работают, пока Mac включён и платформа запущена.
              </Text>
              <Button size="sm" variant="light" onClick={() => beginRule()}>
                Добавить правило
              </Button>
            </Group>
            {!automations.length && (
              <div className="inbox-empty">
                <IconRepeat size={25} stroke={1.3} aria-hidden="true" />
                <Text fw={500} mt="md">
                  Автоматизаций пока нет
                </Text>
                <Text size="sm" c="dimmed" mt={6}>
                  Выберите действие и время — приложение позаботится об остальном.
                </Text>
              </div>
            )}
            {automations.map((a) => (
              <section key={a.id} className="activity-row">
                <Group justify="space-between">
                  <div>
                    <Text fw={500}>{a.name}</Text>
                    <Text c="dimmed" size="sm">
                      {apps.find((p) => p.id === a.appId)?.name} ·{' '}
                      {a.trigger === 'interval'
                        ? `Каждые ${a.intervalMs / 1000} с`
                        : a.trigger === 'schedule'
                          ? `${a.config?.hour}:${String(a.config?.minute || 0).padStart(2, '0')} · ${a.config?.timezone}`
                          : a.trigger === 'clipboard'
                            ? 'При изменении буфера'
                            : 'По событию'}
                    </Text>
                  </div>
                  <Switch
                    aria-label={`Включить ${a.name}`}
                    checked={a.enabled}
                    onChange={(e) =>
                      perform(() =>
                        api('automations.setEnabled', {
                          id: a.id,
                          enabled: e.currentTarget.checked,
                        }),
                      ).then(refresh)
                    }
                  />
                </Group>
                {a.lastError && (
                  <Text c="red" size="sm">
                    {a.lastError}
                  </Text>
                )}
                <Group mt="md">
                  <Button size="compact-xs" variant="subtle" onClick={() => beginRule(a)}>
                    Изменить правило
                  </Button>
                  <Button
                    variant="subtle"
                    color="red"
                    size="compact-xs"
                    onClick={() =>
                      perform(() => api('automations.delete', { id: a.id })).then(refresh)
                    }
                  >
                    Удалить правило
                  </Button>
                </Group>
                <Accordion className="activity-history" variant="default" mt="sm">
                  <Accordion.Item value="history">
                    <Accordion.Control>
                      История запусков · {a.history?.length || 0}
                    </Accordion.Control>
                    <Accordion.Panel>
                      {a.history?.length ? (
                        a.history.slice(0, 10).map((h: any, i: number) => (
                          <Text size="xs" c={h.error ? 'red' : 'dimmed'} key={i}>
                            {new Date(h.at).toLocaleString('ru')} · {h.error || 'Задание создано'}
                          </Text>
                        ))
                      ) : (
                        <Text size="xs" c="dimmed">
                          Запусков пока нет
                        </Text>
                      )}
                    </Accordion.Panel>
                  </Accordion.Item>
                </Accordion>
              </section>
            ))}
          </Stack>
        </Tabs.Panel>
        <Tabs.Panel value="system">
          <Stack>
            <div className="device-note">
              <Title order={3}>Активность устройств</Title>
              <Text size="sm" c="dimmed" mt={6}>
                Сигналы показывают состояние устройств, но не подтверждают передачу данных, звонок
                или трансляцию.
              </Text>
            </div>
            {media ? (
              <div className="device-list">
                <Stack gap={0}>
                  {Object.entries(media).map(([k, v]) => (
                    <Group key={k} className="device-row" justify="space-between">
                      <Text>
                        {(
                          {
                            camera: 'Камера',
                            microphone: 'Микрофон',
                            screen: 'Захват экрана',
                            screenCapture: 'Захват экрана',
                          } as AnyRecord
                        )[k] || k}
                      </Text>
                      <Text size="sm" c="dimmed">
                        {typeof v === 'object' ? JSON.stringify(v) : String(v)}
                      </Text>
                    </Group>
                  ))}
                </Stack>
              </div>
            ) : (
              <Text c="dimmed">Состояние устройств недоступно.</Text>
            )}
            <Title order={3} mt="lg">
              Работающие приложения
            </Title>
            {!apps.some((a) => a.status === 'running') && (
              <Text size="sm" c="dimmed">
                Сейчас ни одно приложение не работает в фоне.
              </Text>
            )}
            {apps
              .filter((a) => a.status === 'running')
              .map((a) => (
                <div key={a.id} className="activity-row">
                  <Group justify="space-between">
                    <Text>
                      {a.icon} {a.name}
                    </Text>
                    <Button
                      size="xs"
                      variant="default"
                      onClick={() =>
                        perform(() =>
                          api('apps.updateMeta', { appId: a.id, status: 'stopped' }),
                        ).then(refresh)
                      }
                    >
                      Остановить
                    </Button>
                  </Group>
                </div>
              ))}
          </Stack>
        </Tabs.Panel>
      </Tabs>
      <Modal
        opened={opened}
        onClose={() => setOpened(false)}
        size="lg"
        className="automation-modal"
        title={editingId ? 'Изменить автоматизацию' : 'Новая автоматизация'}
      >
        <Stack>
          <TextInput
            label="Название правила"
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
          <Select
            label="Приложение"
            value={appId}
            data={apps.map((a) => ({ value: a.id, label: a.name }))}
            onChange={(v) => {
              setAppId(v);
              setActionId(null);
            }}
          />
          <Select
            label="Действие"
            value={actionId}
            data={app?.definition.actions.map((a) => ({ value: a.id, label: a.name })) || []}
            onChange={setActionId}
          />
          <Select
            label="Когда выполнять"
            value={trigger}
            data={[
              { value: 'interval', label: 'Через интервал' },
              { value: 'schedule', label: 'Ежедневно по времени' },
              { value: 'clipboard', label: 'При изменении буфера обмена' },
            ]}
            onChange={(v) => setTrigger(v || 'interval')}
          />
          {trigger === 'interval' && (
            <NumberInput
              label="Интервал, секунды"
              value={interval}
              onChange={setIntervalValue}
              min={5}
            />
          )}{' '}
          {trigger === 'schedule' && (
            <>
              <Group grow>
                <NumberInput label="Часы" value={hour} onChange={setHour} min={0} max={23} />
                <NumberInput label="Минуты" value={minute} onChange={setMinute} min={0} max={59} />
              </Group>
              <Select
                label="Если Mac был выключен"
                value={missed}
                data={[
                  { value: 'skip', label: 'Пропустить' },
                  { value: 'once', label: 'Выполнить один раз после запуска' },
                  { value: 'catchup', label: 'Выполнить до трёх пропущенных запусков' },
                ]}
                onChange={(v) => setMissed(v || 'skip')}
              />
            </>
          )}
          <Paper className="automation-conditions" p="md">
            <div className="automation-flow">
              <div>
                <Badge variant="light">1 · Триггер</Badge>
                <Text size="sm" mt={5}>
                  {trigger === 'clipboard'
                    ? 'Изменение буфера'
                    : trigger === 'schedule'
                      ? 'Наступило время'
                      : 'Прошёл интервал'}
                </Text>
              </div>
              <Text c="dimmed">→</Text>
              <div>
                <Badge variant="light">2 · Условия</Badge>
                <Text size="sm" mt={5}>
                  {conditions.length ? `Все ${conditions.length} совпадают` : 'Всегда'}
                </Text>
              </div>
              <Text c="dimmed">→</Text>
              <div>
                <Badge variant="light">3 · Действие</Badge>
                <Text size="sm" mt={5}>
                  {app?.definition.actions.find((a) => a.id === actionId)?.name ||
                    'Выберите действие'}
                </Text>
              </div>
            </div>
            <Stack mt="md" gap="sm">
              {conditions.map((c, index) => (
                <Group key={index} align="end" wrap="nowrap">
                  <TextInput
                    label="Поле события"
                    placeholder="text"
                    value={c.path}
                    onChange={(e) =>
                      setConditions(
                        conditions.map((x, i) =>
                          i === index ? { ...x, path: e.target.value } : x,
                        ),
                      )
                    }
                  />
                  <Select
                    label="Условие"
                    w={140}
                    value={c.operator}
                    data={[
                      { value: 'eq', label: 'Равно' },
                      { value: 'neq', label: 'Не равно' },
                      { value: 'contains', label: 'Содержит' },
                      { value: 'gt', label: 'Больше' },
                      { value: 'lt', label: 'Меньше' },
                    ]}
                    onChange={(v) =>
                      setConditions(
                        conditions.map((x, i) => (i === index ? { ...x, operator: v || 'eq' } : x)),
                      )
                    }
                  />
                  <TextInput
                    label="Значение"
                    value={c.value}
                    onChange={(e) =>
                      setConditions(
                        conditions.map((x, i) =>
                          i === index ? { ...x, value: e.target.value } : x,
                        ),
                      )
                    }
                  />
                  <Button
                    size="compact-xs"
                    variant="subtle"
                    color="red"
                    aria-label="Удалить условие"
                    onClick={() => setConditions(conditions.filter((_, i) => i !== index))}
                  >
                    ×
                  </Button>
                </Group>
              ))}
              <Button
                size="xs"
                variant="subtle"
                disabled={conditions.length >= 20}
                onClick={() =>
                  setConditions([
                    ...conditions,
                    {
                      path: trigger === 'clipboard' ? 'text' : 'scheduledAt',
                      operator: 'contains',
                      value: '',
                    },
                  ])
                }
              >
                Добавить условие
              </Button>
            </Stack>
          </Paper>
          <Text size="xs" c="dimmed">
            Нужен доступ к фоновой работе. Выдайте его в свойствах приложения. Для буфера нужен
            отдельный доступ.
          </Text>
          <Switch
            label="Включить после сохранения"
            checked={ruleEnabled}
            onChange={(e) => setRuleEnabled(e.currentTarget.checked)}
          />
          <Button
            disabled={!name || !appId || !actionId}
            onClick={async () => {
              const r = await perform(() =>
                api('automations.save', {
                  id: editingId,
                  appId,
                  actionId,
                  name,
                  trigger,
                  enabled: ruleEnabled,
                  intervalMs: Number(interval) * 1000,
                  config: {
                    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
                    hour: Number(hour),
                    minute: Number(minute),
                    missed,
                    catchupLimit: 3,
                    conditions: conditions.map((c) => ({
                      ...c,
                      value: (() => {
                        try {
                          return JSON.parse(c.value);
                        } catch {
                          return c.value;
                        }
                      })(),
                    })),
                  },
                }),
              );
              if (r) {
                setOpened(false);
                refresh();
              }
            }}
          >
            {editingId ? 'Сохранить правило' : 'Создать автоматизацию'}
          </Button>
        </Stack>
      </Modal>
    </div>
  );
}
